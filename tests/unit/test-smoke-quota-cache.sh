#!/usr/bin/env bash
# A smoke-test failure that is not a definitive quota or auth rejection must not
# outlive the run that saw it. An unknown error, a timeout or a sandbox denial
# once wrote the provider to the quota-dead cache, and the next preflight then
# reported it as "degraded (quota)" without calling it (sail-cruisey #2905).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=/dev/null
source "$SCRIPT_DIR/../helpers/test-framework.sh"

test_suite "smoke failures and the quota-dead cache"

log() { :; }
unset CODEX_SANDBOX SANDBOX_RUNTIME OCTOPUS_QUOTA_DEAD_TTL || true

WORKSPACE_DIR="$TEST_TMP_DIR/workspace"
HOME="$TEST_TMP_DIR/home"
mkdir -p "$WORKSPACE_DIR" "$HOME"

# shellcheck source=/dev/null
source "$PROJECT_ROOT/scripts/lib/quota-watcher.sh"
# shellcheck source=/dev/null
source "$PROJECT_ROOT/scripts/lib/smoke.sh"

pass_count=0
fail_count=0
skip_count=0

reset_cache() {
    rm -f "$(octo_quota_dead_file)" "$(octo_quota_dead_meta_file)"
    _OCTO_QUOTA_RUN_DEAD=" "
}

# A fresh shell that sources the libraries again: what the next preflight sees.
next_run_is_dead() {
    WORKSPACE_DIR="$WORKSPACE_DIR" bash -c '
        log() { :; }
        source "$1/scripts/lib/quota-watcher.sh"
        octo_quota_is_dead "$2"' _ "$PROJECT_ROOT" "$1"
}

for result in "UNKNOWN:model" "TIMEOUT:model" "SANDBOX_DENIED:model" "MODEL_NOT_FOUND:model" "POLICY_BLOCKED:model"; do
    test_case "a ${result%%:*} smoke result is not written to the quota-dead cache"
    reset_cache
    _smoke_tally_result "claude" "$result"
    if [[ ! -s "$(octo_quota_dead_file)" ]] && ! next_run_is_dead claude; then
        test_pass
    else
        test_fail "${result%%:*} was cached: $(cat "$(octo_quota_dead_file)" 2>/dev/null)"
    fi
done

test_case "an unknown smoke failure still excludes the provider for the rest of this run"
reset_cache
_smoke_tally_result "claude" "UNKNOWN:model"
if octo_quota_is_dead claude; then
    test_pass
else
    test_fail "a provider that just failed its smoke test is selectable again in the same run"
fi

test_case "a passing smoke result clears the run-local exclusion"
_smoke_tally_result "claude" "PASS"
if ! octo_quota_is_dead claude; then
    test_pass
else
    test_fail "claude passed but stayed excluded"
fi

for result in "AUTH_FAILURE:model" "RATE_LIMITED:model"; do
    test_case "a ${result%%:*} smoke result is cached with its own timestamp"
    reset_cache
    _smoke_tally_result "agy" "$result"
    if grep -qxF agy "$(octo_quota_dead_file)" 2>/dev/null &&
       grep -qE '^agy	[0-9]+	[0-9]+$' "$(octo_quota_dead_meta_file)" 2>/dev/null &&
       next_run_is_dead agy; then
        test_pass
    else
        test_fail "${result%%:*} was not cached per provider: file=$(cat "$(octo_quota_dead_file)" 2>/dev/null) meta=$(cat "$(octo_quota_dead_meta_file)" 2>/dev/null)"
    fi
done

test_case "nothing is cached while running inside a Codex sandbox"
reset_cache
CODEX_SANDBOX=seatbelt _smoke_tally_result "agy" "AUTH_FAILURE:model"
if [[ ! -s "$(octo_quota_dead_file)" ]] && ! next_run_is_dead agy && octo_quota_is_dead agy; then
    test_pass
else
    test_fail "a sandboxed auth failure was cached: $(cat "$(octo_quota_dead_file)" 2>/dev/null)"
fi

test_case "nothing is cached while running inside a sandbox runtime"
reset_cache
SANDBOX_RUNTIME=1 _smoke_tally_result "agy" "RATE_LIMITED:model"
if [[ ! -s "$(octo_quota_dead_file)" ]]; then
    test_pass
else
    test_fail "a sandboxed rate-limit failure was cached"
fi

test_case "Operation not permitted is classified as a sandbox denial"
if [[ "$(_classify_smoke_error 'bash: /dev/fd/62: Operation not permitted')" == SANDBOX_DENIED ]] &&
   [[ "$(_classify_smoke_error 'connect EPERM 127.0.0.1:443 (forbidden by sandbox)')" == SANDBOX_DENIED ]] &&
   [[ "$(_classify_smoke_error 'Error: 401 Unauthorized')" == AUTH_FAILURE ]]; then
    test_pass
else
    test_fail "sandbox stderr was not classified as SANDBOX_DENIED"
fi

test_case "the sandbox denial message names the sandbox, not the provider"
out="$(RED="" YELLOW="" NC="" DIM="" _display_smoke_test_error claude SANDBOX_DENIED model)"
if [[ "$out" == *sandbox* && "$out" != *"unknown error"* ]]; then
    test_pass
else
    test_fail "unexpected message: $out"
fi

test_case "preflight labels a cached quota entry as cached, with when it was written"
reset_cache
octo_quota_mark_dead codex 3600
marked="$(cut -f2 "$(octo_quota_dead_meta_file)")"
expected_time="$(date -r "$marked" +%H:%M 2>/dev/null || date -d "@$marked" +%H:%M)"
readiness="$(
    log() { :; }
    source "$PROJECT_ROOT/scripts/lib/preflight.sh" 2>/dev/null
    codex() { :; }
    export "OPENAI_API_KEY=sk-test-not-a-real-key"
    octo_provider_readiness_result codex static 2>/dev/null
)"
if jq -e --arg t "$expected_time" '.reason_code == "quota" and (.remediation | test("cached " + $t)) and (.remediation | test("not re-checked"))' <<< "$readiness" >/dev/null 2>&1; then
    test_pass
else
    test_fail "readiness did not label the cached entry: $readiness"
fi

test_summary
