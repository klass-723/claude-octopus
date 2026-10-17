#!/usr/bin/env bash
# Tests for prompt-size preflight behavior.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../helpers/test-framework.sh"
test_suite "Dispatch oversize preflight"

log() { :; }
octo_notice_warn() { printf '%s\n' "$*" > "$TEST_TMP_DIR/oversize-notice"; }
record_oversize_event() { printf '%s\n' "$*" > "$TEST_TMP_DIR/oversize-event.args"; }
write_agent_status() { :; }
validate_agent_type() { return 0; }

source "$PROJECT_ROOT/scripts/lib/dispatch.sh"

# These cases isolate compression mechanics from the separately tested output
# and system/tool context reserves.
OCTOPUS_CONTEXT_OUTPUT_RESERVE_TOKENS=0
OCTOPUS_CONTEXT_OVERHEAD_TOKENS=0

long_prompt="abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"

test_case "truncate strategy includes its marker inside the exact resolved boundary"
OCTOPUS_CONTEXT_BUDGET=40
OCTOPUS_OVERSIZE_STRATEGY=truncate
output="$(enforce_context_budget "$long_prompt" "reviewer" "codex" "review")"
event_args="$(cat "$TEST_TMP_DIR/oversize-event.args")"
notice="$(cat "$TEST_TMP_DIR/oversize-notice")"
if [[ "${#output}" -eq 64 ]] &&
   [[ "$output" == *"truncated to fit context budget"* ]] &&
   [[ "$event_args" == "codex ${#long_prompt} 64 truncated reviewer review 16" ]] &&
   [[ "$notice" == "Context budget: truncated codex role=reviewer phase=review from ${#long_prompt} to 64 chars (budget=16 tokens/64 chars)" ]]; then
    test_pass
else
    test_fail "boundary/accounting mismatch: output_chars=${#output} event='$event_args'"
fi

test_case "fail strategy returns context-budget status"
set +e
OCTOPUS_CONTEXT_BUDGET=40
OCTOPUS_OVERSIZE_STRATEGY=fail
enforce_context_budget "$long_prompt" "reviewer" "codex" "review" >"$TEST_TMP_DIR/oversize-fail.out"
rc=$?
set -e
event_args="$(cat "$TEST_TMP_DIR/oversize-event.args")"
if [[ $rc -eq 78 ]] &&
   [[ "$event_args" == "codex ${#long_prompt} ${#long_prompt} failed reviewer review 16" ]]; then
    test_pass
else
    test_fail "expected attributed exit 78, got rc=$rc event='$event_args'"
fi

test_case "summarize strategy dispatches through configured summarizer"
SUMMARIZER_CFG="$TEST_TMP_DIR/providers-summarizer.json"
printf '%s\n' '{"routing":{"features":{"summarizer":["commandcode"]}}}' > "$SUMMARIZER_CFG"
export OCTOPUS_PROVIDERS_CONFIG="$SUMMARIZER_CFG"
octo_fallback_canonical_agent_spec() { printf '%s\n' "$1"; }
octo_fallback_admit_automatic_spec() { return 0; }
run_agent_sync() {
    echo "condensed prompt"
}
OCTOPUS_CONTEXT_BUDGET=40
OCTOPUS_OVERSIZE_STRATEGY=summarize
output="$(enforce_context_budget "$long_prompt" "reviewer" "codex" "review")"
event_args="$(cat "$TEST_TMP_DIR/oversize-event.args")"
notice="$(cat "$TEST_TMP_DIR/oversize-notice")"
if [[ "$output" == "condensed prompt" ]] &&
   [[ "$event_args" == "codex ${#long_prompt} 16 summarized reviewer review 16" ]] &&
   [[ "$notice" == "Context budget: summarized codex role=reviewer phase=review from ${#long_prompt} to 16 chars (budget=16 tokens/64 chars)" ]]; then
    test_pass
else
    test_fail "expected attributed summarized prompt, got output='$output' event='$event_args'"
fi
unset OCTOPUS_PROVIDERS_CONFIG

test_case "leading-zero context budget is normalized as decimal before arithmetic"
decimal_prompt="$(printf '%04000d' 0)"
OCTOPUS_CONTEXT_BUDGET=0900
OCTOPUS_OVERSIZE_STRATEGY=truncate
set +e
output="$(enforce_context_budget "$decimal_prompt" "reviewer" "codex" "review" \
    2>"$TEST_TMP_DIR/decimal-budget.err")"
decimal_rc=$?
set -e
event_args="$(cat "$TEST_TMP_DIR/oversize-event.args")"
if [[ "$decimal_rc" -eq 0 ]] && [[ "${#output}" -eq 1440 ]] &&
   [[ "$event_args" == "codex 4000 1440 truncated reviewer review 360" ]]; then
    test_pass
else
    test_fail "0900 was not normalized safely: rc=$decimal_rc output_chars=${#output} event='$event_args' error='$(cat "$TEST_TMP_DIR/decimal-budget.err")'"
fi

test_case "invalid and overflowing context budgets fail before compression"
invalid_budget_ok=true
invalid_budget_failures=""
for invalid_budget in 0 -1 18446744073709551616 9223372036854775807; do
    rm -f "$TEST_TMP_DIR/oversize-event.args" "$TEST_TMP_DIR/oversize-notice"
    set +e
    OCTOPUS_CONTEXT_BUDGET="$invalid_budget" OCTOPUS_OVERSIZE_STRATEGY=truncate \
        enforce_context_budget "$long_prompt" "reviewer" "codex" "review" \
        >"$TEST_TMP_DIR/invalid-budget.out" 2>"$TEST_TMP_DIR/invalid-budget.err"
    rc=$?
    set -e
    invalid_output="$(cat "$TEST_TMP_DIR/invalid-budget.out")"
    if [[ "$rc" -ne 2 ]] || [[ -s "$TEST_TMP_DIR/invalid-budget.out" ]] ||
       [[ -e "$TEST_TMP_DIR/oversize-event.args" ]] || [[ -e "$TEST_TMP_DIR/oversize-notice" ]]; then
        invalid_budget_ok=false
        invalid_budget_failures="${invalid_budget_failures}${invalid_budget}:rc=${rc}:chars=${#invalid_output};"
    fi
done
if [[ "$invalid_budget_ok" == true ]]; then
    test_pass
else
    test_fail "invalid budgets reached prompt processing: $invalid_budget_failures"
fi

# Summarizer-unavailable fallback for council seats. A truncated diff still
# yields confident verdicts, so council dispatch must fail closed unless the
# caller sets OCTOPUS_COUNCIL_ALLOW_TRUNCATION=1.
export OCTOPUS_PROVIDERS_CONFIG="$SUMMARIZER_CFG"
run_agent_sync() { return 1; }
log() { [[ "$1" == "ERROR" ]] && printf '%s\n' "$*" >> "$TEST_TMP_DIR/oversize-error.log"; return 0; }
OCTOPUS_CONTEXT_BUDGET=40
OCTOPUS_OVERSIZE_STRATEGY=summarize

test_case "council summarizer-unavailable fallback refuses to truncate"
rm -f "$TEST_TMP_DIR/oversize-event.args" "$TEST_TMP_DIR/oversize-notice" "$TEST_TMP_DIR/oversize-error.log"
unset OCTOPUS_COUNCIL_ALLOW_TRUNCATION
set +e
enforce_context_budget "$long_prompt" "reviewer" "codex" "council" >"$TEST_TMP_DIR/council-refuse.out"
rc=$?
set -e
event_args="$(cat "$TEST_TMP_DIR/oversize-event.args" 2>/dev/null || true)"
error_log="$(cat "$TEST_TMP_DIR/oversize-error.log" 2>/dev/null || true)"
if [[ $rc -eq 78 ]] && [[ ! -s "$TEST_TMP_DIR/council-refuse.out" ]] &&
   [[ ! -e "$TEST_TMP_DIR/oversize-notice" ]] &&
   [[ "$event_args" == "codex ${#long_prompt} ${#long_prompt} failed reviewer council 16" ]] &&
   [[ "$error_log" == *"Refusing to truncate"* ]] &&
   [[ "$error_log" == *"git diff -- <paths>"* ]] &&
   [[ "$error_log" == *"OCTOPUS_COUNCIL_ALLOW_TRUNCATION=1"* ]]; then
    test_pass
else
    test_fail "expected fail-closed exit 78, got rc=$rc out_chars=$(wc -c < "$TEST_TMP_DIR/council-refuse.out") event='$event_args' error='$error_log'"
fi

test_case "OCTOPUS_COUNCIL_ALLOW_TRUNCATION=1 restores the council truncation fallback"
rm -f "$TEST_TMP_DIR/oversize-event.args" "$TEST_TMP_DIR/oversize-notice" "$TEST_TMP_DIR/oversize-error.log"
set +e
output="$(OCTOPUS_COUNCIL_ALLOW_TRUNCATION=1 enforce_context_budget "$long_prompt" "reviewer" "codex" "council")"
rc=$?
set -e
event_args="$(cat "$TEST_TMP_DIR/oversize-event.args" 2>/dev/null || true)"
notice="$(cat "$TEST_TMP_DIR/oversize-notice" 2>/dev/null || true)"
if [[ $rc -eq 0 ]] && [[ "${#output}" -eq 64 ]] &&
   [[ "$output" == *"truncated to fit context budget"* ]] &&
   [[ "$event_args" == "codex ${#long_prompt} 64 truncated reviewer council 16" ]] &&
   [[ "$notice" == "Context budget: summarizer unavailable; truncated codex role=reviewer phase=council"* ]]; then
    test_pass
else
    test_fail "opt-in did not truncate: rc=$rc output_chars=${#output} event='$event_args' notice='$notice'"
fi

test_case "non-council summarizer-unavailable fallback still truncates"
rm -f "$TEST_TMP_DIR/oversize-event.args" "$TEST_TMP_DIR/oversize-notice"
set +e
output="$(enforce_context_budget "$long_prompt" "reviewer" "codex" "review")"
rc=$?
set -e
event_args="$(cat "$TEST_TMP_DIR/oversize-event.args" 2>/dev/null || true)"
if [[ $rc -eq 0 ]] && [[ "${#output}" -eq 64 ]] &&
   [[ "$event_args" == "codex ${#long_prompt} 64 truncated reviewer review 16" ]]; then
    test_pass
else
    test_fail "non-council fallback changed: rc=$rc output_chars=${#output} event='$event_args'"
fi

test_case "council prompt is still summarized when the summarizer succeeds"
run_agent_sync() { echo "condensed prompt"; }
rm -f "$TEST_TMP_DIR/oversize-event.args"
output="$(enforce_context_budget "$long_prompt" "reviewer" "codex" "council")"
event_args="$(cat "$TEST_TMP_DIR/oversize-event.args" 2>/dev/null || true)"
if [[ "$output" == "condensed prompt" ]] &&
   [[ "$event_args" == "codex ${#long_prompt} 16 summarized reviewer council 16" ]]; then
    test_pass
else
    test_fail "summarized council path changed: output='$output' event='$event_args'"
fi

test_case "explicit truncate strategy is unaffected for council"
OCTOPUS_OVERSIZE_STRATEGY=truncate
rm -f "$TEST_TMP_DIR/oversize-event.args"
output="$(enforce_context_budget "$long_prompt" "reviewer" "codex" "council")"
event_args="$(cat "$TEST_TMP_DIR/oversize-event.args" 2>/dev/null || true)"
if [[ "${#output}" -eq 64 ]] &&
   [[ "$event_args" == "codex ${#long_prompt} 64 truncated reviewer council 16" ]]; then
    test_pass
else
    test_fail "explicit truncate changed for council: output_chars=${#output} event='$event_args'"
fi
unset OCTOPUS_PROVIDERS_CONFIG OCTOPUS_OVERSIZE_STRATEGY

# The size test is octo_estimate_prompt_tokens against admission_limit (the
# summarize trigger, capped at the provider budget), counting any non-ASCII
# prompt at 3 UTF-8 bytes per token. Errors must report that limit, not the raw
# 4-chars-per-token budget: sail-cruisey #3006/#3011 printed "limit is 41856
# chars" while enforcing 10464 tokens x 3 = 31392 bytes.
utf8_locale=""
for _loc in C.UTF-8 en_US.UTF-8 C.utf8 en_US.utf8; do
    if LC_ALL="$_loc" bash -c 's="—"; [[ ${#s} -eq 1 ]]' 2>/dev/null; then utf8_locale="$_loc"; break; fi
done

test_case "council refusal reports the enforced admission limit for a non-ASCII prompt"
if [[ -z "$utf8_locale" ]]; then
    test_skip "no UTF-8 locale available"
else
    run_agent_sync() { return 1; }
    rm -f "$TEST_TMP_DIR/oversize-error.log"
    # 3300 ASCII chars + 50 em-dashes: 3350 chars (under the old 4000-char
    # message) but 3450 bytes, so ~1150 estimated tokens > 1000 admission.
    utf8_prompt="$(printf 'a%.0s' $(seq 1 3300))$(printf '—%.0s' $(seq 1 50))"
    set +e
    LC_ALL="$utf8_locale" OCTOPUS_CONTEXT_BUDGET=1000 OCTOPUS_OVERSIZE_STRATEGY=summarize \
        enforce_context_budget "$utf8_prompt" "security-auditor" "codex" "council" >/dev/null
    rc=$?
    set -e
    error_log="$(cat "$TEST_TMP_DIR/oversize-error.log" 2>/dev/null || true)"
    if [[ $rc -eq 78 ]] &&
       [[ "$error_log" == *"is 3350 chars / 3450 bytes (~1150 tokens); admission limit is 3000 bytes (~1000 tokens, counted at 3 bytes per token"* ]] &&
       [[ "$error_log" != *"4000 chars"* ]] &&
       [[ "$error_log" == *"Refusing to truncate"* ]]; then
        test_pass
    else
        test_fail "rc=$rc error='$error_log'"
    fi
fi

test_case "fail strategy reports the enforced admission limit for an ASCII prompt"
rm -f "$TEST_TMP_DIR/oversize-error.log"
set +e
OCTOPUS_CONTEXT_BUDGET=40 OCTOPUS_OVERSIZE_STRATEGY=fail \
    enforce_context_budget "$long_prompt" "reviewer" "codex" "review" >/dev/null
rc=$?
set -e
error_log="$(cat "$TEST_TMP_DIR/oversize-error.log" 2>/dev/null || true)"
if [[ $rc -eq 78 ]] &&
   [[ "$error_log" == *"prompt for codex role=reviewer phase=review is ${#long_prompt} chars (~$(( (${#long_prompt} + 3) / 4 )) tokens); admission limit is 64 chars (~16 tokens)"* ]]; then
    test_pass
else
    test_fail "rc=$rc error='$error_log'"
fi

test_case "council phase allowance widens the budget only for phase council"
base="$(OCTOPUS_CONTEXT_BUDGET=1000 get_provider_context_limit codex council security-auditor)"
widened="$(_OCTOPUS_COUNCIL_CONTEXT_ALLOWANCE=500 OCTOPUS_CONTEXT_BUDGET=1000 get_provider_context_limit codex council security-auditor)"
other="$(_OCTOPUS_COUNCIL_CONTEXT_ALLOWANCE=500 OCTOPUS_CONTEXT_BUDGET=1000 get_provider_context_limit codex review reviewer)"
bad="$(_OCTOPUS_COUNCIL_CONTEXT_ALLOWANCE=abc OCTOPUS_CONTEXT_BUDGET=1000 get_provider_context_limit codex council security-auditor)"
if [[ "$base" == 1000 && "$widened" == 1500 && "$other" == 1000 && "$bad" == 1000 ]]; then
    test_pass
else
    test_fail "base=$base widened=$widened other=$other bad=$bad"
fi

test_case "council phase allowance stays under an explicit transport limit"
capped="$(_OCTOPUS_COUNCIL_CONTEXT_ALLOWANCE=500 OCTOPUS_CLAUDE_CONTEXT_BUDGET=1000 OCTOPUS_CLAUDE_EFFECTIVE_CONTEXT_LIMIT=1200 get_provider_context_limit claude council security-auditor)"
if [[ "$capped" == 1200 ]]; then test_pass; else test_fail "capped=$capped want 1200"; fi

test_summary
