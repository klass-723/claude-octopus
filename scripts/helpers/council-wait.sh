#!/usr/bin/env bash
# council-wait.sh — block efficiently until a backgrounded council round finishes,
# then print the path to its summary.json. Replaces a lead's coarse hand-rolled
# poll loop (e.g. `sleep 15 x 38` passes, discovering completion up to ~10 minutes
# late) with a short-interval poll of the authoritative completion beacon.
#
# The runner writes run-status.json's `state:"finished"` as the LAST step of
# council_write_summary_json, i.e. only after a valid summary.json is in place, so
# `state == "finished"` reliably means the summary is present. This waiter polls
# that flag and returns the instant it flips — the completion tail drops from
# minutes to one poll interval.
#
# Usage:
#   council-wait.sh --pool <dir> [--interval S] [--timeout N] [--since EPOCH] \
#                   [--supersede-key KEY]
#   council-wait.sh --run-dir <dir> [--interval S] [--timeout N]
#
#   --pool         councils pool dir; the newest run in it is awaited (a council
#                  invocation creates a timestamped run dir the caller can't name
#                  ahead of time, so the pool is the stable handle).
#   --run-dir      await a specific run dir instead of resolving one from a pool.
#   --supersede-key with --pool, prefer the run the pool's latest-<slug> pointer
#                  names (the current gate's round), ignoring older interleaved gates.
#   --since EPOCH  with --pool, only consider runs created at/after EPOCH
#                  (local seconds), so a stale prior round is never selected.
#                  Creation time comes from the run ID's timestamp, not dir mtime.
#   --interval S   poll interval seconds (default 2; floored at 1).
#   --timeout N    max seconds to wait (default 570, kept < the 600s synchronous
#                  tool-call cap; call again to keep waiting a longer council).
#
# Output: on completion, prints the summary.json path to stdout and exits 0.
#         On timeout, prints the awaited run dir (or "pending") to stderr, exits 2.
#         Usage/argument errors exit 64.
set -euo pipefail

POOL="" RUN_DIR="" INTERVAL=2 TIMEOUT=570 SINCE="" KEY=""

die_usage() { printf '%s\n' "$1" >&2; printf 'See: council-wait.sh --help\n' >&2; exit 64; }

_posint() {
    # Echo a user integer normalized to decimal, or fail. Rejects leading-zero
    # octal traps (`08` would blow up in `$(( ))`) and oversized values that would
    # overflow, so both produce the documented usage error rather than a late
    # arithmetic fault (CodeRabbit #1156).
    local v="$1"
    [[ "$v" =~ ^0*[0-9]{1,10}$ ]] || return 1
    v=$((10#$v))
    (( v <= 2147483647 )) || return 1
    printf '%s' "$v"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --pool)          [[ $# -ge 2 ]] || die_usage "--pool requires a value"; POOL="$2"; shift 2 ;;
        --run-dir)       [[ $# -ge 2 ]] || die_usage "--run-dir requires a value"; RUN_DIR="$2"; shift 2 ;;
        --supersede-key) [[ $# -ge 2 ]] || die_usage "--supersede-key requires a value"; KEY="$2"; shift 2 ;;
        --since)         [[ $# -ge 2 ]] || die_usage "--since requires a value"; SINCE="$2"; shift 2 ;;
        --interval)      [[ $# -ge 2 ]] || die_usage "--interval requires a value"; INTERVAL="$2"; shift 2 ;;
        --timeout)       [[ $# -ge 2 ]] || die_usage "--timeout requires a value"; TIMEOUT="$2"; shift 2 ;;
        --help|-h)       sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)               die_usage "unknown argument: $1" ;;
    esac
done

INTERVAL="$(_posint "$INTERVAL")" || die_usage "--interval must be a decimal integer in range"
TIMEOUT="$(_posint "$TIMEOUT")"   || die_usage "--timeout must be a decimal integer in range"
if [[ -n "$SINCE" ]]; then SINCE="$(_posint "$SINCE")" || die_usage "--since must be a decimal epoch integer in range"; fi
(( INTERVAL < 1 )) && INTERVAL=1
command -v jq >/dev/null 2>&1 || die_usage "jq is required"

if [[ -n "$RUN_DIR" && -n "$POOL" ]]; then die_usage "pass only one of --run-dir / --pool"; fi
if [[ -z "$RUN_DIR" && -z "$POOL" ]]; then die_usage "one of --run-dir / --pool is required"; fi

_slug() {
    # Mirror council_supersede_key_slug so --supersede-key resolves the same pointer.
    local key="$1" safe hash
    safe="$(printf '%s' "$key" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-64)"
    hash="$(printf '%s' "$key" | cksum | cut -d' ' -f1)"
    printf '%s-%s' "$safe" "$hash"
}

_runid_epoch() {
    # A run's creation time, derived from the YYYYMMDD-HHMMSS its run ID embeds —
    # NOT the directory mtime. Writing summary.json advances an older run's dir
    # mtime, which would let a stale round slip past --since; the run ID is fixed
    # at dispatch. Also sidesteps the GNU-vs-BSD `stat` format mismatch entirely
    # (CodeRabbit #1156). Echoes epoch seconds (local tz, matching the runner's
    # stamp), or nothing when the name does not carry a timestamp.
    local base="${1##*/}"
    [[ "$base" =~ ^([0-9]{8})-([0-9]{6}) ]] || return 1
    local d="${BASH_REMATCH[1]}" t="${BASH_REMATCH[2]}"
    date -j -f "%Y%m%d%H%M%S" "${d}${t}" +%s 2>/dev/null \
        || date -d "${d:0:4}-${d:4:2}-${d:6:2} ${t:0:2}:${t:2:2}:${t:4:2}" +%s 2>/dev/null
}

_since_ok() {
    # True unless --since is set and the run's creation time precedes it. When
    # --since is set and the name carries no parseable timestamp, the run is
    # INELIGIBLE: its creation time cannot be shown to satisfy the cutoff, so it
    # must not slip past the filter (CodeRabbit #1156).
    [[ -z "$SINCE" ]] && return 0
    local e; e="$(_runid_epoch "$1" 2>/dev/null || true)"
    [[ -z "$e" ]] && return 1
    (( e >= SINCE ))
}

_created_order() {
    # The run's monotonic creation counter, assigned by council-run-state.py and
    # stored in run-status.json. The runner selects the newest run by this order
    # (tie-broken by run ID), because same-second runs carry PID-hex suffixes that
    # do NOT sort by creation order — so this waiter must rank the same way rather
    # than by directory name alone (CodeRabbit #1156). Absent/legacy beacons yield
    # 0 and fall back to the run-ID tie-break.
    local st="$1/run-status.json" o
    [[ -f "$st" ]] || { printf 0; return 0; }
    o="$(jq -r '.created_order // 0' "$st" 2>/dev/null || printf 0)"
    [[ "$o" =~ ^[0-9]+$ ]] && printf '%s' "$o" || printf 0
}

_resolve_run_dir() {
    # Echo the run dir to await, or nothing if none is visible yet.
    if [[ -n "$RUN_DIR" ]]; then
        [[ -d "$RUN_DIR" ]] && printf '%s' "$RUN_DIR"
        return 0
    fi
    [[ -d "$POOL" ]] || return 0
    # A keyed wait tracks ONLY the gate's latest-<slug> pointer. If it is not yet
    # present/valid (or names a pre---since round), wait for it — never fall back
    # to a pool-wide scan that could return another gate's finished run
    # (CodeRabbit #1156). The pointer is re-read on every poll by the caller, so a
    # newer round that supersedes this one is picked up rather than the stale run.
    if [[ -n "$KEY" ]]; then
        local ptr="$POOL/latest-$(_slug "$KEY")" rid rd
        if [[ -f "$ptr" ]]; then
            rid="$(tr -d '[:space:]' < "$ptr" 2>/dev/null || true)"
            if [[ -n "$rid" && -d "$POOL/$rid" ]]; then
                rd="$POOL/$rid"
                _since_ok "$rd" && printf '%s' "$rd"
            fi
        fi
        return 0
    fi
    # Otherwise the newest run (optionally created at/after --since), ranked by
    # creation order then run ID — the same key council-run-state.py uses — so a
    # same-second newer run is never passed over for an older one.
    local d best="" best_order=-1 ord
    for d in "$POOL"/2*/; do
        [[ -d "$d" ]] || continue
        d="${d%/}"
        _since_ok "$d" || continue
        ord="$(_created_order "$d")"
        if (( ord > best_order )) || { (( ord == best_order )) && [[ "$d" > "$best" ]]; }; then
            best="$d"; best_order="$ord"
        fi
    done
    [[ -n "$best" ]] && printf '%s' "$best"
}

_is_finished() {
    local rd="$1" st="$1/run-status.json"
    [[ -f "$st" ]] || return 1
    [[ "$(jq -r '.state // empty' "$st" 2>/dev/null || true)" == "finished" ]] || return 1
    # Defensive: the beacon flips to finished only after a valid summary.json, but
    # re-check so a torn/partial file is never reported as complete.
    local summary="$rd/summary.json"
    [[ -s "$summary" ]] && jq -e . "$summary" >/dev/null 2>&1
}

now() { date +%s 2>/dev/null || echo 0; }

deadline=$(( $(now) + TIMEOUT ))
run_dir=""
while :; do
    # With a supersede key, re-resolve every poll: a newer round can update the
    # latest-<slug> pointer and supersede the one we were tracking, so a cached
    # run_dir could otherwise return a superseded summary (CodeRabbit #1156).
    if [[ -n "$KEY" || -z "$run_dir" ]]; then run_dir="$(_resolve_run_dir || true)"; fi
    if [[ -n "$run_dir" ]] && _is_finished "$run_dir"; then
        printf '%s/summary.json\n' "$run_dir"
        exit 0
    fi
    # Cap the sleep at the time left, so an --interval larger than the remaining
    # budget cannot overshoot --timeout (and thus the caller's 600s tool-call cap)
    # or let a run that finishes during an overlong sleep return success past the
    # deadline (CodeRabbit #1156).
    remaining=$(( deadline - $(now) ))
    (( remaining <= 0 )) && break
    (( remaining < INTERVAL )) && sleep "$remaining" || sleep "$INTERVAL"
done

printf 'council-wait: timed out after %ss (run: %s)\n' "$TIMEOUT" "${run_dir:-pending}" >&2
exit 2
