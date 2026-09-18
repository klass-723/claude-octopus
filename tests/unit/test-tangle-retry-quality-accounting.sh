#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TESTING="$PROJECT_ROOT/scripts/lib/testing.sh"

# shellcheck source=/dev/null
source "$SCRIPT_DIR/../helpers/test-framework.sh"
# shellcheck source=/dev/null
source "$TESTING"

test_suite "tangle retry quality accounting"

RED=""
GREEN=""
YELLOW=""
NC=""
DIM=""
_BOX_TOP=""
_BOX_BOT=""
LOOP_UNTIL_APPROVED=false
CI_MODE=true
OCTOPUS_ANTISYCOPHANCY=false
OCTOPUS_FILE_VALIDATION=false
MAX_QUALITY_RETRIES=0
FAILED_SUBTASKS=""

log() { :; }
record_task_metric() { :; }
STRUCTURED_DECISION_CONTEXT=""
write_structured_decision() {
    STRUCTURED_DECISION_CONTEXT="$6"
}
retry_failed_subtasks() { :; }
get_gate_threshold() { echo 75; }
evaluate_quality_branch() {
    if [[ "$1" -ge 75 ]]; then echo proceed; else echo abort; fi
}

RESULTS_DIR="$TEST_TMP_DIR/tangle-retry-quality-accounting"
mkdir -p "$RESULTS_DIR"

write_result() {
    local file="$1"
    local task_id="$2"
    local role="$3"
    local status="$4"
    cat > "$file" <<EOF_RESULT
# Agent: commandcode
# Task ID: $task_id
# Role: $role
# Phase: tangle
# Prompt: retry accounting fixture

## Output
fixture output for $task_id

## Status: $status
EOF_RESULT
}

# Three tasks succeed initially; two coding tasks fail.
write_result "$RESULTS_DIR/commandcode-tangle-accounting-1.md" "tangle-accounting-1" implementer FAILED
write_result "$RESULTS_DIR/commandcode-tangle-accounting-2.md" "tangle-accounting-2" implementer FAILED
write_result "$RESULTS_DIR/commandcode-tangle-accounting-3.md" "tangle-accounting-3" researcher SUCCESS
write_result "$RESULTS_DIR/commandcode-tangle-accounting-4.md" "tangle-accounting-4" researcher SUCCESS
write_result "$RESULTS_DIR/commandcode-tangle-accounting-5.md" "tangle-accounting-5" researcher SUCCESS

# Retry 1 supersedes tasks 1 and 2: task 1 recovers, task 2 is still failing.
write_result "$RESULTS_DIR/commandcode-tangle-accounting-retry1-1.md" "tangle-accounting-retry1-1" implementer SUCCESS
write_result "$RESULTS_DIR/commandcode-tangle-accounting-retry1-2.md" "tangle-accounting-retry1-2" implementer FAILED

test_case "latest retry supersedes historical result in quality percentage"
if validate_tangle_results "accounting" "Assess retry quality accounting" >/dev/null 2>&1; then
    report=$(cat "$RESULTS_DIR/tangle-validation-accounting.md")
    if [[ "$report" == *"Success Rate: 80%"* ]] && \
       [[ "$report" == *"Successful: 4/5 result files"* ]] && \
       [[ "$report" == *"Failed: 1/5 result files"* ]]; then
        test_pass
    else
        test_fail "quality report did not use only the latest result per logical task"
    fi
else
    test_fail "quality gate failed because superseded historical failures were still counted"
fi

test_case "effective result set excludes superseded originals"
effective=$(tangle_effective_result_files "accounting")
if [[ "$effective" == *"retry1-1.md"* ]] && \
   [[ "$effective" == *"retry1-2.md"* ]] && \
   [[ "$effective" != *"accounting-1.md"* ]] && \
   [[ "$effective" != *"accounting-2.md"* ]]; then
    test_pass
else
    test_fail "effective result set retained superseded original task results"
fi


test_case "successful correction overlay drives quality decision with effective rate"
CORRECTION_GROUP="correction-overlay"
write_result "$RESULTS_DIR/commandcode-tangle-${CORRECTION_GROUP}-1.md" "tangle-${CORRECTION_GROUP}-1" implementer SUCCESS
write_result "$RESULTS_DIR/commandcode-tangle-${CORRECTION_GROUP}-2.md" "tangle-${CORRECTION_GROUP}-2" implementer SUCCESS
write_result "$RESULTS_DIR/commandcode-tangle-${CORRECTION_GROUP}-3.md" "tangle-${CORRECTION_GROUP}-3" implementer FAILED
CORRECTION_FILE="$RESULTS_DIR/correction-${CORRECTION_GROUP}.md"
cat > "$CORRECTION_FILE" <<'EOF_CORRECTION'
# Agent: commandcode
# Role: implementer
# Phase: tangle-correction

## Output
Correction round repaired the validated worktree.

## Status: SUCCESS
EOF_CORRECTION

if OCTOPUS_TANGLE_VALIDATION_CORRECTION_FILE="$CORRECTION_FILE" \
   OCTOPUS_TANGLE_VALIDATION_CORRECTION_STATUS="success" \
   OCTOPUS_TANGLE_VALIDATION_CORRECTION_CHANGED=1 \
   validate_tangle_results "$CORRECTION_GROUP" "Assess correction overlay quality accounting" >/dev/null 2>&1; then
    report=$(cat "$RESULTS_DIR/tangle-validation-${CORRECTION_GROUP}.md")
    if [[ "$report" == *"Static Subtask Rate Before Correction Overlay: 66%"* ]] && \
       [[ "$report" == *"Effective Rate After Correction Overlay: 100%"* ]] && \
       [[ "$report" == *"Decision Branch: proceed"* ]] && \
       [[ "$STRUCTURED_DECISION_CONTEXT" == "Success: 3/3, failures: 0, threshold: 75%" ]]; then
        test_pass
    else
        test_fail "quality decision did not use effective post-correction rate and counts"
    fi
else
    test_fail "quality gate still rejected a successful correction overlay because it used the static 66% rate"
fi


test_case "failed final correction status cannot apply a stale success overlay"
STALE_SUCCESS_GROUP="correction-stale-success"
write_result "$RESULTS_DIR/commandcode-tangle-${STALE_SUCCESS_GROUP}-1.md" "tangle-${STALE_SUCCESS_GROUP}-1" implementer SUCCESS
write_result "$RESULTS_DIR/commandcode-tangle-${STALE_SUCCESS_GROUP}-2.md" "tangle-${STALE_SUCCESS_GROUP}-2" implementer SUCCESS
write_result "$RESULTS_DIR/commandcode-tangle-${STALE_SUCCESS_GROUP}-3.md" "tangle-${STALE_SUCCESS_GROUP}-3" implementer FAILED
STALE_SUCCESS_CORRECTION_FILE="$RESULTS_DIR/correction-${STALE_SUCCESS_GROUP}.md"
cat > "$STALE_SUCCESS_CORRECTION_FILE" <<'EOF_STALE_SUCCESS_CORRECTION'
# Agent: commandcode
# Role: implementer
# Phase: tangle-correction

## Output
Correction round returned a failed final status without blocker output.

## Status: SUCCESS

## Status: FAILED
EOF_STALE_SUCCESS_CORRECTION

if OCTOPUS_TANGLE_VALIDATION_CORRECTION_FILE="$STALE_SUCCESS_CORRECTION_FILE" \
   OCTOPUS_TANGLE_VALIDATION_CORRECTION_STATUS="failed" \
   OCTOPUS_TANGLE_VALIDATION_CORRECTION_CHANGED=1 \
   validate_tangle_results "$STALE_SUCCESS_GROUP" "Assess failed correction overlay" >/dev/null 2>&1; then
    test_fail "failed final correction status was treated as an effective success"
else
    report=$(cat "$RESULTS_DIR/tangle-validation-${STALE_SUCCESS_GROUP}.md")
    if [[ "$report" == *"Success Rate: 66%"* ]] && \
       [[ "$report" != *"Effective Rate After Correction Overlay: 100%"* ]] && \
       [[ "$report" == *"Decision Branch: abort"* ]]; then
        test_pass
    else
        test_fail "stale correction success bypassed the quality gate"
    fi
fi


test_case "blocker output cannot apply a successful correction overlay"
BLOCKER_GROUP="correction-blocker"
write_result "$RESULTS_DIR/commandcode-tangle-${BLOCKER_GROUP}-1.md" "tangle-${BLOCKER_GROUP}-1" implementer SUCCESS
write_result "$RESULTS_DIR/commandcode-tangle-${BLOCKER_GROUP}-2.md" "tangle-${BLOCKER_GROUP}-2" implementer SUCCESS
write_result "$RESULTS_DIR/commandcode-tangle-${BLOCKER_GROUP}-3.md" "tangle-${BLOCKER_GROUP}-3" implementer FAILED
BLOCKER_CORRECTION_FILE="$RESULTS_DIR/correction-${BLOCKER_GROUP}.md"
cat > "$BLOCKER_CORRECTION_FILE" <<'EOF_BLOCKER_CORRECTION'
# Agent: commandcode
# Role: implementer
# Phase: tangle-correction

## Output
Correction round could not complete because the sandbox is blocking file writes.
This is a blocker report, not a successful correction.

## Status: SUCCESS
EOF_BLOCKER_CORRECTION

if OCTOPUS_TANGLE_VALIDATION_CORRECTION_FILE="$BLOCKER_CORRECTION_FILE" \
   OCTOPUS_TANGLE_VALIDATION_CORRECTION_STATUS="success" \
   OCTOPUS_TANGLE_VALIDATION_CORRECTION_CHANGED=1 \
   validate_tangle_results "$BLOCKER_GROUP" "Assess blocked correction overlay" >/dev/null 2>&1; then
    test_fail "blocker output was treated as an effective success"
else
    report=$(cat "$RESULTS_DIR/tangle-validation-${BLOCKER_GROUP}.md")
    if [[ "$report" == *"Success Rate: 66%"* ]] && \
       [[ "$report" != *"Effective Rate After Correction Overlay: 100%"* ]] && \
       [[ "$report" == *"Decision Branch: abort"* ]]; then
        test_pass
    else
        test_fail "blocker output bypassed the correction overlay quality gate"
    fi
fi


test_case "correction overlay does not bypass explicit file coverage hard gate"
HARD_GATE_GROUP="correction-hard-gate"
write_result "$RESULTS_DIR/commandcode-tangle-${HARD_GATE_GROUP}-1.md" "tangle-${HARD_GATE_GROUP}-1" implementer SUCCESS
write_result "$RESULTS_DIR/commandcode-tangle-${HARD_GATE_GROUP}-2.md" "tangle-${HARD_GATE_GROUP}-2" implementer SUCCESS
write_result "$RESULTS_DIR/commandcode-tangle-${HARD_GATE_GROUP}-3.md" "tangle-${HARD_GATE_GROUP}-3" implementer FAILED
HARD_GATE_CORRECTION_FILE="$RESULTS_DIR/correction-${HARD_GATE_GROUP}.md"
cat > "$HARD_GATE_CORRECTION_FILE" <<'EOF_HARD_GATE_CORRECTION'
# Agent: commandcode
# Role: implementer
# Phase: tangle-correction

## Output
Correction round repaired unrelated implementation details.

## Status: SUCCESS
EOF_HARD_GATE_CORRECTION

if OCTOPUS_TANGLE_VALIDATION_CORRECTION_FILE="$HARD_GATE_CORRECTION_FILE" \
   OCTOPUS_TANGLE_VALIDATION_CORRECTION_STATUS="success" \
   OCTOPUS_TANGLE_VALIDATION_CORRECTION_CHANGED=1 \
   validate_tangle_results "$HARD_GATE_GROUP" "Implement required file src/required-output.js" >/dev/null 2>&1; then
    test_fail "correction overlay bypassed missing explicit file coverage"
else
    report=$(cat "$RESULTS_DIR/tangle-validation-${HARD_GATE_GROUP}.md")
    if [[ "$report" == *"Effective Rate After Correction Overlay: 100%"* ]] && \
       [[ "$report" == *"Missing Explicit File Coverage"* ]] && \
       [[ "$report" == *"Decision Branch: abort"* ]]; then
        test_pass
    else
        test_fail "hard gate did not remain fail-closed after correction overlay"
    fi
fi

test_summary
