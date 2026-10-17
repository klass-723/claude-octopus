#!/usr/bin/env bash
# Council seat failure capture (sail-cruisey #3032).
#
# Council seats run detached, so when a Claude seat exited non-zero the only
# trace was "Agent claude failed with exit code 1" in the caller's log and
# "no-response" in summary.json. run_agent_sync now appends each failed attempt
# (exit code, provider stderr, or the stdout tail when stderr is empty) to the
# file named by _OCTOPUS_SEAT_STDERR_FILE, and the advice phase records it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../helpers/test-framework.sh"
test_suite "Council seat stderr capture"

# shellcheck source=/dev/null
source "$PROJECT_ROOT/scripts/lib/agent-sync.sh"
# shellcheck source=/dev/null
source "$PROJECT_ROOT/scripts/lib/secure.sh"

# Drive the real run_agent_sync failure path with a fake provider. Mirrors the
# harness in test-agent-sync-signal-retry.sh.
run_failing_seat() (
    local scenario="$1" mode="$2" capture="$3"
    local fixture_root="$TEST_TMP_DIR/$scenario"
    local fake_provider="$fixture_root/provider.sh"
    mkdir -p "$fixture_root/results"
    export RESULTS_DIR="$fixture_root/results"
    cat > "$fake_provider" <<EOF
#!/usr/bin/env bash
case "$mode" in
    stderr) printf 'Error: claude session limit reached (key sk-abcdefghijklmnopqrstuvwxyz0123)\n' >&2 ;;
    stdout) printf '{"type":"result","is_error":true,"result":"Invalid model: claude-fable-5-1"}\n' ;;
    silent) : ;;
esac
exit 1
EOF
    chmod 755 "$fake_provider"

    log() { :; }
    classify_task() { printf 'standard\n'; }
    get_role_for_context() { printf 'reviewer\n'; }
    apply_persona() { printf '%s\n' "$2"; }
    load_earned_skills() { :; }
    build_provider_context() { :; }
    enforce_context_budget() { printf '%s\n' "$1"; }
    get_agent_model() { printf 'fixture-model\n'; }
    estimate_agent_call_cost() { printf '0.000000\n'; }
    check_provider_health() { return 0; }
    record_agent_call() { :; }
    get_agent_command() { printf '%s\n' "$fake_provider"; }
    build_provider_env() { PROVIDER_ENV_ARRAY=(); }
    run_with_timeout() { shift; "$@"; }
    stop_quota_watcher() { :; }
    update_agent_status() { :; }
    octo_estimate_tokens_for_file() { printf '0\n'; }
    write_agent_status() { :; }

    set +e
    _OCTOPUS_SEAT_STDERR_FILE="$capture" OCTOPUS_PERSISTENCE_AVAILABLE=true \
        run_agent_sync claude 'review this change' 30 reviewer council >/dev/null 2>&1
)

CAP_DIR="$(mktemp -d "${TEST_TMP_DIR:-/tmp}/seat-stderr.XXXXXX")"

test_case "a Claude seat that exits non-zero leaves its provider stderr in the capture file"
cap="$CAP_DIR/stderr/02-code-reviewer.log"
run_failing_seat stderr-case stderr "$cap" && rc=0 || rc=$?
if [[ "$rc" == 1 && -s "$cap" ]] &&
   grep -q '^== .* claude exited 1: ' "$cap" &&
   grep -q '^-- stderr --$' "$cap" &&
   grep -q 'claude session limit reached' "$cap"; then
    test_pass
else
    test_fail "rc=$rc capture=$(tr '\n' '|' < "$cap" 2>/dev/null)"
fi

test_case "captured stderr is private and secrets in it are scrubbed"
mode="$(stat -f '%Lp' "$cap" 2>/dev/null || stat -c '%a' "$cap" 2>/dev/null)"
if [[ "$mode" == 600 ]] && ! grep -q 'sk-abcdefghijklmnopqrstuvwxyz0123' "$cap" && grep -q 'REDACTED-API-KEY' "$cap"; then
    test_pass
else
    test_fail "mode=$mode capture=$(tr '\n' '|' < "$cap")"
fi

test_case "when stderr is empty the stdout tail is captured instead (CLIs that print errors there)"
cap="$CAP_DIR/stderr/stdout-case.log"
run_failing_seat stdout-case stdout "$cap" || true
if grep -q '^-- stdout tail (stderr was empty) --$' "$cap" && grep -q 'Invalid model: claude-fable-5-1' "$cap"; then
    test_pass
else
    test_fail "capture=$(tr '\n' '|' < "$cap" 2>/dev/null)"
fi

test_case "a silent failure still records the exit code"
cap="$CAP_DIR/stderr/silent-case.log"
run_failing_seat silent-case silent "$cap" || true
if grep -q '^== .* claude exited 1: ' "$cap" && grep -q '^-- no stderr or stdout --$' "$cap"; then
    test_pass
else
    test_fail "capture=$(tr '\n' '|' < "$cap" 2>/dev/null)"
fi

test_case "without a capture file nothing is written"
before="$(find "$CAP_DIR" -type f | wc -l | tr -d ' ')"
run_failing_seat no-capture stderr "" || true
after="$(find "$CAP_DIR" -type f | wc -l | tr -d ' ')"
if [[ "$before" == "$after" ]]; then test_pass; else test_fail "files before=$before after=$after"; fi

# ── Advice phase: the seat record and warnings carry the cause.
# shellcheck source=/dev/null
source "$PROJECT_ROOT/scripts/lib/council.sh" 2>/dev/null

_advice_run() {
    local d="$1" roster="$2"
    mkdir -p "$d/responses"
    COUNCIL_RUN_DIR="$d"
    COUNCIL_ROSTER_JSON="$roster"
    COUNCIL_FIXTURE=""
    COUNCIL_TIMEOUT_WARNINGS=""
    COUNCIL_SEAT_RECORDS_JSON='[]'
    council_run_chair_fallback() { :; }
    council_run_advice_phase >/dev/null 2>&1 || true
    unset -f council_run_chair_fallback
}

test_case "advice phase records a failed Claude seat's exit code, cause, and stderr file in summary data"
d="$(mktemp -d "$TEST_TMP_DIR/council-seat-fail.XXXXXX")"
council_dispatch_member_detached() {
    # Stand-in for run_agent_sync appending its failure capture.
    mkdir -p "$(dirname "$_OCTOPUS_SEAT_STDERR_FILE")"
    printf '== 2026-10-17T03:12:42Z claude exited 1: Exit code 1\n-- stdout tail (stderr was empty) --\nError: nested Claude session refused (CLAUDECODE is set)\n' \
        >> "$_OCTOPUS_SEAT_STDERR_FILE"
    return 1
}
_advice_run "$d" '[{"persona":"code-reviewer","seat":"verifier","provider":"claude","provider_org":"anthropic","model":"claude-fable-5-1"}]'
unset -f council_dispatch_member_detached
rec="$(jq -c '.[0]' <<< "$COUNCIL_SEAT_RECORDS_JSON")"
if jq -e --arg f "$d/stderr/00-code-reviewer.log" '.status == "no-response" and .failure.exit_code == 1
        and .failure.detail == "Error: nested Claude session refused (CLAUDECODE is set)"
        and .failure.stderr_file == $f' <<< "$rec" >/dev/null &&
   [[ -s "$d/stderr/00-code-reviewer.log" ]] &&
   [[ "$COUNCIL_TIMEOUT_WARNINGS" == "seat claude (code-reviewer) exited 1: Error: nested Claude session refused (CLAUDECODE is set); full output in $d/stderr/00-code-reviewer.log" ]]; then
    test_pass
else
    test_fail "record=$rec warns=[$COUNCIL_TIMEOUT_WARNINGS]"
fi

test_case "a failure before any provider ran still names a cause and a file"
d="$(mktemp -d "$TEST_TMP_DIR/council-seat-early.XXXXXX")"
council_dispatch_member_detached() { return 1; }
_advice_run "$d" '[{"persona":"code-reviewer","seat":"verifier","provider":"claude","provider_org":"anthropic","model":"m"}]'
unset -f council_dispatch_member_detached
rec="$(jq -c '.[0]' <<< "$COUNCIL_SEAT_RECORDS_JSON")"
if jq -e '.failure.exit_code == 1 and (.failure.detail | contains("before a provider produced output"))' <<< "$rec" >/dev/null &&
   grep -q '^== .* dispatch exited 1$' "$d/stderr/00-code-reviewer.log"; then
    test_pass
else
    test_fail "record=$rec"
fi

test_case "a seat that succeeds keeps no stderr file and no failure field"
d="$(mktemp -d "$TEST_TMP_DIR/council-seat-ok.XXXXXX")"
council_dispatch_member_detached() {
    mkdir -p "$(dirname "$_OCTOPUS_SEAT_STDERR_FILE")"
    printf 'stale attempt\n' >> "$_OCTOPUS_SEAT_STDERR_FILE"
    printf 'Reviewed the plan; the guard is correct.\n\nVERDICT: APPROVE\n' > "$3"
    return 0
}
_advice_run "$d" '[{"persona":"code-reviewer","seat":"verifier","provider":"claude","provider_org":"anthropic","model":"m"}]'
unset -f council_dispatch_member_detached
rec="$(jq -c '.[0]' <<< "$COUNCIL_SEAT_RECORDS_JSON")"
if jq -e 'has("failure") | not' <<< "$rec" >/dev/null && [[ ! -e "$d/stderr/00-code-reviewer.log" ]]; then
    test_pass
else
    test_fail "record=$rec files=$(ls "$d/stderr" 2>/dev/null)"
fi

test_summary
