#!/usr/bin/env bash
# Preflight checks the council roster a session pins with
# OCTOPUS_COUNCIL_DEFAULT_PROVIDERS, and says when it ran inside a sandbox
# (sail-cruisey #2901: octocodex pins claude,agy because Codex is the lead).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../helpers/test-framework.sh"
test_suite "Preflight council roster"

log() { :; }
export HOME="$TEST_TMP_DIR/home"
WORKSPACE_DIR="$TEST_TMP_DIR/workspace"
mkdir -p "$HOME" "$WORKSPACE_DIR"
RED="" GREEN="" YELLOW="" CYAN="" DIM="" NC=""
PREFLIGHT_CACHE_FILE="$WORKSPACE_DIR/.preflight-cache"
PREFLIGHT_CACHE_TTL=3600
source "$PROJECT_ROOT/scripts/lib/preflight.sh"
source "$PROJECT_ROOT/scripts/lib/config-display.sh"
unset OCTOPUS_COUNCIL_DEFAULT_PROVIDERS CODEX_SANDBOX SANDBOX_RUNTIME

test_case "no roster pinned: nothing to check"
if [[ -z "$(octo_preflight_roster)" ]] && [[ -z "$(OCTOPUS_COUNCIL_DEFAULT_PROVIDERS=auto octo_preflight_roster)" ]]; then test_pass
else test_fail "unexpected roster"; fi

test_case "a pinned roster yields its canonical seats once each"
got="$(OCTOPUS_COUNCIL_DEFAULT_PROVIDERS='claude,agy,claude:claude-opus-5-5' octo_preflight_roster | tr '\n' ' ')"
if [[ "$got" == "claude agy " ]]; then test_pass; else test_fail "got '$got'"; fi

test_case "an invalid roster is rejected"
if ! OCTOPUS_COUNCIL_DEFAULT_PROVIDERS='claude,nope' octo_preflight_roster >/dev/null 2>&1; then test_pass
else test_fail "invalid roster accepted"; fi

# preflight_check with every probe stubbed: readiness from a table, no smoke.
READY_CALLS="$TEST_TMP_DIR/ready-calls"
# Providers named in STUB_UNREADY report degraded; the rest are available.
STUB_UNREADY=""
octo_provider_readiness_result() {
    printf '%s\n' "$1" >> "$READY_CALLS"
    local status=available reason=ready
    [[ " $STUB_UNREADY " == *" $1 "* ]] && status=degraded reason=auth-required
    printf '{"provider":"%s","status":"%s","reason_code":"%s","remediation":"Log in to %s."}\n' "$1" "$status" "$reason" "$1"
}
check_codex_auth_freshness() { return 0; }
detect_enterprise_backend() { :; }
provider_smoke_test() { return 0; }
run_preflight() { rm -f "$READY_CALLS" "$PREFLIGHT_CACHE_FILE"; preflight_check true 2>&1; }

test_case "with claude,agy pinned, preflight checks exactly those seats and names the list"
STUB_UNREADY=""
out="$(OCTOPUS_COUNCIL_DEFAULT_PROVIDERS=claude,agy run_preflight)" && rc=0 || rc=$?
calls="$(tr '\n' ' ' < "$READY_CALLS")"
if [[ "$rc" -eq 0 && "$calls" == "claude agy " && "$out" == *"council roster from OCTOPUS_COUNCIL_DEFAULT_PROVIDERS: claude agy"* && "$out" != *codex* ]]; then test_pass
else test_fail "rc=$rc calls='$calls' out=$out"; fi

test_case "a roster seat that is not ready fails preflight and is named"
STUB_UNREADY="agy"
out="$(OCTOPUS_COUNCIL_DEFAULT_PROVIDERS=claude,agy run_preflight)" && rc=0 || rc=$?
if [[ "$rc" -ne 0 && "$out" == *"seat(s) not ready: agy"* && "$out" == *"✗ agy"* ]]; then test_pass
else test_fail "rc=$rc out=$out"; fi

test_case "without a roster, preflight still checks the non-Claude providers"
STUB_UNREADY=""
out="$(run_preflight)" && rc=0 || rc=$?
calls=" $(tr '\n' ' ' < "$READY_CALLS")"
expected=" $(_preflight_provider_candidates | tr '\n' ' ')"
if [[ "$rc" -eq 0 && "$calls" == "$expected" && "$calls" != *" claude "* && "$out" != *"council roster"* ]]; then test_pass
else test_fail "rc=$rc calls='$calls' expected='$expected'"; fi

test_case "a cached pass is reused only for the same roster"
STUB_UNREADY=""
rm -f "$PREFLIGHT_CACHE_FILE"
OCTOPUS_COUNCIL_DEFAULT_PROVIDERS=claude,agy preflight_check true >/dev/null 2>&1
if OCTOPUS_COUNCIL_DEFAULT_PROVIDERS=claude,agy preflight_cache_valid && [[ "$(preflight_cache_read)" == 0 ]] &&
   ! preflight_cache_valid && ! OCTOPUS_COUNCIL_DEFAULT_PROVIDERS=codex,agy preflight_cache_valid; then test_pass
else test_fail "cache: $(cat "$PREFLIGHT_CACHE_FILE" | tr '\n' '|')"; fi

test_case "inside a sandbox, an unready seat comes with the run-outside remedy"
STUB_UNREADY="claude"
out="$(CODEX_SANDBOX=seatbelt OCTOPUS_COUNCIL_DEFAULT_PROVIDERS=claude,agy run_preflight)" || true
plain="$(OCTOPUS_COUNCIL_DEFAULT_PROVIDERS=claude,agy run_preflight)" || true
if [[ "$out" == *"inside the Codex sandbox (CODEX_SANDBOX=seatbelt)"* && "$out" == *"outside the sandbox"* && "$plain" != *"sandbox"* ]]; then test_pass
else test_fail "out=$out"; fi

test_case "the readiness loop does not redirect through /dev/fd (denied in macOS sandboxes)"
if ! grep -nE '^[^#]*[0-9]?> >\(' "$PROJECT_ROOT/scripts/lib/preflight.sh" >/dev/null; then test_pass
else test_fail "process-substitution redirect found"; fi

test_case "the /octo:preflight dashboard reports only the pinned roster"
unset -f octo_provider_readiness_result
source "$PROJECT_ROOT/scripts/lib/preflight.sh"
json="$(OCTOPUS_COUNCIL_DEFAULT_PROVIDERS=claude,agy bash "$PROJECT_ROOT/scripts/helpers/preflight.sh" --json 2>/dev/null)"
all="$(bash "$PROJECT_ROOT/scripts/helpers/preflight.sh" --json 2>/dev/null)"
if jq -e '.roster == ["claude","agy"] and ([.results[].provider] == ["claude","agy"])' <<< "$json" >/dev/null &&
   jq -e --argjson n "$(wc -w <<< "$(octo_provider_ids detect)")" '.roster == null and (.results | length) == $n' <<< "$all" >/dev/null; then test_pass
else test_fail "json=$(jq -c '{roster,p:[.results[].provider]}' <<< "$json")"; fi

test_case "the smoke test skips providers outside the roster"
source "$PROJECT_ROOT/scripts/lib/smoke.sh"
if OCTOPUS_COUNCIL_DEFAULT_PROVIDERS=claude,agy _smoke_in_roster agy &&
   ! OCTOPUS_COUNCIL_DEFAULT_PROVIDERS=claude,agy _smoke_in_roster codex && _smoke_in_roster codex; then test_pass
else test_fail "smoke roster gate wrong"; fi

test_summary
