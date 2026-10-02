#!/usr/bin/env bash
# council-wait.sh: efficient wait on the council completion beacon.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../helpers/test-framework.sh"

WAIT="$PROJECT_ROOT/scripts/helpers/council-wait.sh"

test_suite "council-wait"

# Guarded runner: captures stdout in $out and exit code in $rc without tripping
# set -e on the helper's intentional non-zero exits (timeout=2, usage=64).
out=""; rc=0
_runwait() { rc=0; out="$(bash "$WAIT" "$@" 2>/dev/null)" || rc=$?; }

_mkrun() { # _mkrun <pool> <run_id> <state> [valid_summary] [created_order]
    local pool="$1" rid="$2" state="$3" valid="${4:-yes}" order="${5:-0}" rd="$1/$2"
    mkdir -p "$rd"
    printf '{"state":"%s","run_id":"%s","created_order":%s}\n' "$state" "$rid" "$order" > "$rd/run-status.json"
    if [[ "$state" == "finished" ]]; then
        if [[ "$valid" == "yes" ]]; then printf '{"status":"completed","quorum":{"met":true}}\n' > "$rd/summary.json"
        else printf '{bad json' > "$rd/summary.json"; fi
    fi
    printf '%s' "$rd"
}

test_case "finished run prints its summary.json path and exits 0"
pool="$(mktemp -d "$TEST_TMP_DIR/p1.XXXXXX")"
rd="$(_mkrun "$pool" 20260101-000000-00aaaa finished)"
_runwait --pool "$pool" --interval 1 --timeout 5
if [[ $rc -eq 0 && "$out" == "$rd/summary.json" ]]; then test_pass; else test_fail "rc=$rc out=$out want=$rd/summary.json"; fi

test_case "a running run times out with exit 2 (no false completion)"
pool="$(mktemp -d "$TEST_TMP_DIR/p2.XXXXXX")"
_mkrun "$pool" 20260101-000000-00bbbb running >/dev/null
_runwait --pool "$pool" --interval 1 --timeout 2
if [[ $rc -eq 2 ]]; then test_pass; else test_fail "rc=$rc want 2"; fi

test_case "awaits the NEWEST run in the pool, not a stale earlier one"
pool="$(mktemp -d "$TEST_TMP_DIR/p3.XXXXXX")"
_mkrun "$pool" 20260101-000000-00aaaa finished >/dev/null      # stale older, finished
_mkrun "$pool" 20260101-010000-00cccc running >/dev/null       # newest, still running
_runwait --pool "$pool" --interval 1 --timeout 2
if [[ $rc -eq 2 ]]; then test_pass; else test_fail "picked the stale finished run (rc=$rc, expected timeout on newest-running)"; fi

test_case "a finished beacon with torn/invalid summary.json is not reported complete"
pool="$(mktemp -d "$TEST_TMP_DIR/p4.XXXXXX")"
_mkrun "$pool" 20260101-000000-00dddd finished no >/dev/null   # finished state but bad summary
_runwait --pool "$pool" --interval 1 --timeout 2
if [[ $rc -eq 2 ]]; then test_pass; else test_fail "reported complete on invalid summary (rc=$rc)"; fi

test_case "returns promptly when the run flips to finished mid-wait"
pool="$(mktemp -d "$TEST_TMP_DIR/p5.XXXXXX")"
rd="$(_mkrun "$pool" 20260101-020000-00eeee running)"
( sleep 2; printf '{"status":"completed"}\n' > "$rd/summary.json"
  printf '{"state":"finished","run_id":"20260101-020000-00eeee"}\n' > "$rd/run-status.json" ) &
flip_pid=$!
start=$(date +%s)
_runwait --pool "$pool" --interval 1 --timeout 20
elapsed=$(( $(date +%s) - start ))
wait "$flip_pid" 2>/dev/null || true
if [[ $rc -eq 0 && "$out" == "$rd/summary.json" && $elapsed -lt 15 ]]; then test_pass; else test_fail "rc=$rc elapsed=${elapsed}s out=$out"; fi

test_case "--supersede-key resolves the pool's latest-<slug> pointer"
pool="$(mktemp -d "$TEST_TMP_DIR/p6.XXXXXX")"
# Derive the slug from the PRODUCER so this asserts parity with the runner, not a
# copy of the waiter's own algorithm (CodeRabbit #1156). Fail setup if absent.
source "$PROJECT_ROOT/scripts/lib/council.sh" 2>/dev/null || true
# Guard the parity assertions so a missing producer fails THIS case without
# aborting later cases or test_summary (CodeRabbit #1156).
if ! declare -f council_supersede_key_slug >/dev/null 2>&1; then
    test_fail "council_supersede_key_slug unavailable — cannot verify slug parity"
else
    key="2947:CP2"
    slug="$(council_supersede_key_slug "$key")"
    cp2rd="$(_mkrun "$pool" 20260101-030000-00f111 finished)"      # the keyed round, finished
    _mkrun "$pool" 20260101-040000-00f222 running >/dev/null       # a NEWER unrelated round, running
    printf '%s\n' 20260101-030000-00f111 > "$pool/latest-$slug"
    _runwait --pool "$pool" --supersede-key "$key" --interval 1 --timeout 5
    if [[ $rc -eq 0 && "$out" == "$cp2rd/summary.json" ]]; then test_pass; else test_fail "key pointer not honored: rc=$rc out=$out want=$cp2rd/summary.json"; fi
fi

test_case "--supersede-key waits (does not grab another gate's run) when its pointer is absent"
pool="$(mktemp -d "$TEST_TMP_DIR/p6b.XXXXXX")"
_mkrun "$pool" 20260101-030000-00f1aa finished >/dev/null      # a DIFFERENT gate's finished run, no pointer to it
_runwait --pool "$pool" --supersede-key "missing:KEY" --interval 1 --timeout 2
if [[ $rc -eq 2 ]]; then test_pass; else test_fail "keyed wait fell back to an unrelated run (rc=$rc out=$out)"; fi

test_case "--supersede-key re-resolves mid-poll: pointer flips to a finished round"
pool="$(mktemp -d "$TEST_TMP_DIR/p6c.XXXXXX")"
source "$PROJECT_ROOT/scripts/lib/council.sh" 2>/dev/null || true
if ! declare -f council_supersede_key_slug >/dev/null 2>&1; then
    test_fail "council_supersede_key_slug unavailable — cannot build the keyed pointer"
else
    key="2947:CP3"; slug="$(council_supersede_key_slug "$key")"
    runrd="$(_mkrun "$pool" 20260101-050000-00f501 running)"       # keyed round, initially running
    finrd="$(_mkrun "$pool" 20260101-040000-00f500 finished)"      # an EARLIER round that will finish the gate
    printf '%s\n' 20260101-050000-00f501 > "$pool/latest-$slug"     # pointer first names the running round
    ( sleep 2; printf '%s\n' 20260101-040000-00f500 > "$pool/latest-$slug" ) &   # flip pointer mid-poll
    flip=$!
    _runwait --pool "$pool" --supersede-key "$key" --interval 1 --timeout 15
    wait "$flip" 2>/dev/null || true
    if [[ $rc -eq 0 && "$out" == "$finrd/summary.json" ]]; then test_pass; else test_fail "mid-poll pointer flip not honored: rc=$rc out=$out want=$finrd/summary.json"; fi
fi

test_case "--since: a pool of only a stale timestamped finished run times out (exit 2)"
pool="$(mktemp -d "$TEST_TMP_DIR/p8c.XXXXXX")"
_mkrun "$pool" 20200101-000000-00aaaa finished >/dev/null          # well before the cutoff, nothing newer
since="$(date -j -f %Y%m%d%H%M%S 20250101000000 +%s 2>/dev/null || date -d '2025-01-01 00:00:00' +%s)"
_runwait --pool "$pool" --since "$since" --interval 1 --timeout 2
if [[ $rc -eq 2 ]]; then test_pass; else test_fail "stale-only pool should time out under --since: rc=$rc out=$out"; fi

test_case "--since excludes a stale earlier run and selects a newer one"
pool="$(mktemp -d "$TEST_TMP_DIR/p8.XXXXXX")"
_mkrun "$pool" 20200101-000000-00aaaa finished >/dev/null      # year 2020 — well before the cutoff
newrd="$(_mkrun "$pool" 20260601-120000-00bbbb finished)"      # year 2026 — after the cutoff
since="$(date -j -f %Y%m%d%H%M%S 20250101000000 +%s 2>/dev/null || date -d '2025-01-01 00:00:00' +%s)"
_runwait --pool "$pool" --since "$since" --interval 1 --timeout 5
if [[ $rc -eq 0 && "$out" == "$newrd/summary.json" ]]; then test_pass; else test_fail "since filter wrong: rc=$rc out=$out want=$newrd/summary.json"; fi

test_case "--since excludes a glob-matching run whose name has no parseable timestamp"
pool="$(mktemp -d "$TEST_TMP_DIR/p8b.XXXXXX")"
# Name matches the "$POOL"/2*/ scan glob but FAILS the YYYYMMDD-HHMMSS regex, so
# it reaches _since_ok rather than being filtered out by the glob — only then can
# this case catch a regression in the filter itself (CodeRabbit #1156).
rd="$pool/2-nonce-run"; mkdir -p "$rd"; printf '{"state":"finished","run_id":"2-nonce-run","created_order":9}\n' > "$rd/run-status.json"; printf '{"ok":1}\n' > "$rd/summary.json"
# Without --since the run IS selected and completes (proves the glob matches it).
_runwait --pool "$pool" --interval 1 --timeout 3
r_nofilter=$([[ $rc -eq 0 && "$out" == "$rd/summary.json" ]] && echo ok || echo "bad(rc=$rc,out=$out)")
# With --since set, an unparseable creation time makes it ineligible → times out.
_runwait --pool "$pool" --since 1 --interval 1 --timeout 2
if [[ "$r_nofilter" == ok && $rc -eq 2 ]]; then test_pass; else test_fail "untimestamped+since: nofilter=$r_nofilter sincerc=$rc"; fi

test_case "picks the newer same-second run by created_order, not run-ID suffix"
pool="$(mktemp -d "$TEST_TMP_DIR/p9.XXXXXX")"
# Same timestamp second; the FINISHED one has a lexically-GREATER suffix but an
# EARLIER created_order. The newer run (smaller suffix, higher order) is running,
# so the waiter must track it and time out rather than return the older finished.
_mkrun "$pool" 20260101-000000-00ffff finished yes 1 >/dev/null   # older by order, bigger suffix
_mkrun "$pool" 20260101-000000-00aaaa running  yes 2 >/dev/null   # newer by order, smaller suffix
_runwait --pool "$pool" --interval 1 --timeout 2
if [[ $rc -eq 2 ]]; then test_pass; else test_fail "selected older finished run by suffix instead of newest by created_order (rc=$rc out=$out)"; fi

test_case "--run-dir waits on a specific run dir"
pool="$(mktemp -d "$TEST_TMP_DIR/p7.XXXXXX")"
rd="$(_mkrun "$pool" 20260101-050000-00f333 finished)"
_runwait --run-dir "$rd" --interval 1 --timeout 5
if [[ $rc -eq 0 && "$out" == "$rd/summary.json" ]]; then test_pass; else test_fail "rc=$rc out=$out"; fi

test_case "argument errors exit 64"
r1=bad r2=bad r3=bad
_runwait --pool /x --run-dir /y; [[ $rc -eq 64 ]] && r1=ok
_runwait;                        [[ $rc -eq 64 ]] && r2=ok
_runwait --pool /x --interval abc; [[ $rc -eq 64 ]] && r3=ok
if [[ "$r1" == ok && "$r2" == ok && "$r3" == ok ]]; then test_pass; else test_fail "usage guards: $r1/$r2/$r3"; fi

test_summary
