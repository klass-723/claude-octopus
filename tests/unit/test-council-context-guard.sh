#!/usr/bin/env bash
# Plan-mode context-file preflight guard.
#
# Plan-mode council seats have no file tools, so a task that NAMES a path to read
# cannot be honored without --context-file (which inlines the bytes). The guard
# surfaces that at dispatch: warn by default, fail closed under
# OCTOPUS_COUNCIL_REQUIRE_CONTEXT=1 — but ONLY when the task references a real
# path and no --context-file was given. Bare prose (or a context-file already
# supplied) must pass silently.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../helpers/test-framework.sh"
source "$PROJECT_ROOT/scripts/lib/council.sh"

test_suite "Council plan-mode context guard"

# Guarded runner: set inputs, call the guard, capture stderr + exit code without
# set -e aborting on the intentional non-zero (strict-mode) exit.
_run_guard() { # _run_guard <task> ; reads COUNCIL_CONTEXT_FILES + OCTOPUS_COUNCIL_REQUIRE_CONTEXT from env
    COUNCIL_TASK="$1"
    gerr=""; grc=0
    gerr="$(council_preflight_context_guard 2>&1 >/dev/null)" || grc=$?
}

test_case "warns (exit 0) when the task names an absolute path and no --context-file"
COUNCIL_CONTEXT_FILES=(); unset OCTOPUS_COUNCIL_REQUIRE_CONTEXT
_run_guard "Review the plan at /.todo/claude-octopus/123/phase-3-plan.md and vote."
if [[ $grc -eq 0 && "$gerr" == *WARNING* && "$gerr" == *context-file* ]]; then test_pass; else test_fail "rc=$grc err=$gerr"; fi

test_case "warns on a real ~/-rooted CP2 diff path"
COUNCIL_CONTEXT_FILES=(); unset OCTOPUS_COUNCIL_REQUIRE_CONTEXT
_run_guard "Review ~/.claude-octopus/issues/123/review-diff.txt; do not guess."
if [[ $grc -eq 0 && "$gerr" == *WARNING* ]]; then test_pass; else test_fail "rc=$grc err=$gerr"; fi

test_case "fails closed (exit 2) under OCTOPUS_COUNCIL_REQUIRE_CONTEXT=1"
COUNCIL_CONTEXT_FILES=(); OCTOPUS_COUNCIL_REQUIRE_CONTEXT=1
_run_guard "Review the plan at /.todo/claude-octopus/123/phase-3-plan.md and vote."
unset OCTOPUS_COUNCIL_REQUIRE_CONTEXT
if [[ $grc -eq 2 && "$gerr" == *context-file* ]]; then test_pass; else test_fail "rc=$grc err=$gerr"; fi

test_case "silent when --context-file is already supplied (even with a path in the task)"
COUNCIL_CONTEXT_FILES=("/some/plan.md"); unset OCTOPUS_COUNCIL_REQUIRE_CONTEXT
_run_guard "Review the plan at /.todo/claude-octopus/123/phase-3-plan.md and vote."
if [[ $grc -eq 0 && -z "$gerr" ]]; then test_pass; else test_fail "rc=$grc err=$gerr"; fi

test_case "silent on a pure-prose task with no path"
COUNCIL_CONTEXT_FILES=(); unset OCTOPUS_COUNCIL_REQUIRE_CONTEXT
_run_guard "Decide whether we should use Redis or Memcached for session storage."
if [[ $grc -eq 0 && -z "$gerr" ]]; then test_pass; else test_fail "rc=$grc err=$gerr"; fi

test_case "silent on a bare filename mentioned in prose (no leading path)"
COUNCIL_CONTEXT_FILES=(); unset OCTOPUS_COUNCIL_REQUIRE_CONTEXT
_run_guard "The diff moves a dep in package.json from deps to devDeps; is that safe?"
if [[ $grc -eq 0 && -z "$gerr" ]]; then test_pass; else test_fail "rc=$grc err=$gerr"; fi

test_case "fail-closed still passes a no-path prose task"
COUNCIL_CONTEXT_FILES=(); OCTOPUS_COUNCIL_REQUIRE_CONTEXT=1
_run_guard "Decide whether to adopt feature flags for the rollout."
unset OCTOPUS_COUNCIL_REQUIRE_CONTEXT
if [[ $grc -eq 0 && -z "$gerr" ]]; then test_pass; else test_fail "rc=$grc err=$gerr"; fi

test_case "strict mode rejects double-quoted, single-quoted, and backtick paths"
COUNCIL_CONTEXT_FILES=(); OCTOPUS_COUNCIL_REQUIRE_CONTEXT=1
quote_failures=""
for task in 'Review "/tmp/plan.md"' "Review '/tmp/plan.md'" 'Review `/tmp/plan.md`'; do
    _run_guard "$task"
    if [[ $grc -ne 2 || "$gerr" != *context-file* ]]; then
        quote_failures+=" [$task: rc=$grc]"
    fi
done
unset OCTOPUS_COUNCIL_REQUIRE_CONTEXT
if [[ -z "$quote_failures" ]]; then test_pass; else test_fail "$quote_failures"; fi

test_case "strict dispatch exits 2 before the advice phase"
advice_marker="$TEST_TMP_DIR/context-guard-advice"
dispatch_rc=0
dispatch_err="$(
    # Exercise the real parser and run implementation; stub only setup I/O and
    # provider work so a missing guard cannot make a live provider call.
    council_create_run_dir() { COUNCIL_RUN_DIR="$TEST_TMP_DIR"; }
    council_build_roster() { :; }
    council_write_config_json() { :; }
    council_write_research_artifact() { :; }
    council_check_cost_cap() { return 0; }
    council_run_advice_phase() { : > "$advice_marker"; COUNCIL_QUORUM_MET=false; }
    council_append_corpus_artifacts() { :; }
    council_write_summary_json() { :; }
    council_print_run_warnings() { :; }
    DRY_RUN=false
    OCTOPUS_COUNCIL_REQUIRE_CONTEXT=1
    _council_run_impl --goal plan --benchmark off 'Review /tmp/plan.md' 2>&1 >/dev/null
)" || dispatch_rc=$?
if [[ $dispatch_rc -eq 2 && ! -e "$advice_marker" && "$dispatch_err" == *context-file* ]]; then
    test_pass
else
    test_fail "rc=$dispatch_rc advice=$([[ -e "$advice_marker" ]] && printf called || printf skipped) err=$dispatch_err"
fi

test_summary
