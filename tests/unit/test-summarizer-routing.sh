#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../helpers/test-framework.sh"
source "$PROJECT_ROOT/scripts/lib/dispatch.sh"

test_suite "summarizer routing feature"

CFG="$TEST_TMP_DIR/providers.json"
export OCTOPUS_PROVIDERS_CONFIG="$CFG"

# Keep these tests focused on feature routing rather than the provider registry.
validate_model_name_for_provider() { return 0; }
octo_fallback_canonical_agent_spec() { printf '%s\n' "$1"; }
octo_fallback_admit_automatic_spec() { return 0; }

write_config() {
    cat > "$CFG" <<'JSON'
{
  "routing": {
    "features": {
      "summarizer": [
        "commandcode:vendor/compact-contributor",
        "codex:gpt-mini",
        "commandcode:vendor/free-model:free"
      ]
    }
  }
}
JSON
}
write_config

test_case "routing.features.summarizer preserves configured order and exact model specs"
actual="$(octo_summarizer_candidates)"
expected=$'commandcode:vendor/compact-contributor\ncodex:gpt-mini\ncommandcode:vendor/free-model:free'
if [[ "$actual" == "$expected" ]]; then
    test_pass
else
    test_fail "unexpected summarizer candidates: [$actual]"
fi

test_case "explicit override is first and configured duplicate is de-duplicated"
OCTOPUS_OVERSIZE_SUMMARIZER='codex:gpt-mini'
actual="$(octo_summarizer_candidates)"
unset OCTOPUS_OVERSIZE_SUMMARIZER
expected=$'codex:gpt-mini\ncommandcode:vendor/compact-contributor\ncommandcode:vendor/free-model:free'
if [[ "$actual" == "$expected" ]]; then
    test_pass
else
    test_fail "override order/dedup mismatch: [$actual]"
fi

test_case "invalid explicit override does not suppress configured candidates"
OCTOPUS_OVERSIZE_SUMMARIZER='unknown-provider'
octo_fallback_canonical_agent_spec() {
    [[ "$1" != 'unknown-provider' ]] && printf '%s\n' "$1"
}
actual="$(octo_summarizer_candidates)"
unset OCTOPUS_OVERSIZE_SUMMARIZER
octo_fallback_canonical_agent_spec() { printf '%s\n' "$1"; }
expected=$'commandcode:vendor/compact-contributor\ncodex:gpt-mini\ncommandcode:vendor/free-model:free'
if [[ "$actual" == "$expected" ]]; then
    test_pass
else
    test_fail "invalid override suppressed configured candidates: [$actual]"
fi

test_case "canonical target aliases are not selected for summarization"
printf '%s\n' '{"routing":{"features":{"summarizer":["agy"]}}}' > "$CFG"
unset -f octo_fallback_canonical_agent_spec octo_fallback_admit_automatic_spec
CALLS="$TEST_TMP_DIR/alias-target-calls"
: > "$CALLS"
run_agent_sync() {
    printf '%s\n' "$1" >> "$CALLS"
    printf '%s\n' 'unexpected summary'
}
if summary="$(summarize_then_dispatch 'very long prompt body' researcher antigravity 80)"; then
    test_fail "canonical target alias was dispatched: summary=[$summary] calls=[$(cat "$CALLS")]"
elif [[ ! -s "$CALLS" ]]; then
    test_pass
else
    test_fail "canonical target alias made unexpected calls: [$(cat "$CALLS")]"
fi
octo_fallback_canonical_agent_spec() { printf '%s\n' "$1"; }
octo_fallback_admit_automatic_spec() { return 0; }

test_case "empty summarizer feature has no hidden provider fallback"
printf '%s\n' '{"routing":{"features":{"summarizer":[]}}}' > "$CFG"
actual="$(octo_summarizer_candidates)"
if [[ -z "$actual" ]]; then
    test_pass
else
    test_fail "unexpected hidden fallback candidates: [$actual]"
fi

test_case "missing summarizer feature has no hidden provider fallback"
printf '%s\n' '{"routing":{"features":{}}}' > "$CFG"
actual="$(octo_summarizer_candidates)"
if [[ -z "$actual" ]]; then
    test_pass
else
    test_fail "unexpected candidates without configured feature: [$actual]"
fi

test_case "automatic policy may reject configured seats without reintroducing defaults"
write_config
octo_fallback_admit_automatic_spec() {
    [[ "$1" != 'codex:gpt-mini' ]]
}
actual="$(octo_summarizer_candidates)"
expected=$'commandcode:vendor/compact-contributor\ncommandcode:vendor/free-model:free'
if [[ "$actual" == "$expected" ]]; then
    test_pass
else
    test_fail "policy filtering mismatch: [$actual]"
fi

test_case "summarize_then_dispatch tries configured candidates in order"
write_config
octo_fallback_admit_automatic_spec() { return 0; }
CALLS="$TEST_TMP_DIR/calls"
: > "$CALLS"
run_agent_sync() {
    printf '%s\n' "$1" >> "$CALLS"
    case "$1" in
        commandcode:vendor/compact-contributor) return 1 ;;
        codex:gpt-mini) printf '%s\n' 'condensed summary'; return 0 ;;
        *) return 1 ;;
    esac
}
summary="$(summarize_then_dispatch 'very long prompt body' researcher commandcode 80)"
actual_calls="$(cat "$CALLS")"
expected_calls=$'commandcode:vendor/compact-contributor\ncodex:gpt-mini'
if [[ "$summary" == 'condensed summary' && "$actual_calls" == "$expected_calls" ]]; then
    test_pass
else
    test_fail "dispatch order/result mismatch: summary=[$summary] calls=[$actual_calls]"
fi

test_case "summarizer implementation contains no legacy hard-coded provider cascade"
function_text="$(sed -n '/^summarize_then_dispatch() {/,/^}/p' "$PROJECT_ROOT/scripts/lib/dispatch.sh")"
if ! grep -Eq 'candidates\+=\("agy"|codex-mini.*claude-sonnet|"codex"\)' <<< "$function_text"; then
    test_pass
else
    test_fail "legacy provider cascade is still hard-coded"
fi

test_summary
