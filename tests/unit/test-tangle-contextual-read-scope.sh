#!/usr/bin/env bash

# Regression checks for strict and contextual Tangle read-scope validation.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=/dev/null
source "$SCRIPT_DIR/../helpers/test-framework.sh"

test_suite "tangle contextual read scope"

# shellcheck source=/dev/null
source "$PROJECT_ROOT/scripts/lib/workflows.sh"

tmp="$TEST_TMP_DIR/contextual-read-scope"
repo="$tmp/repo"; wiki="$tmp/project-docs"; outside="$tmp/other-project"
mkdir -p "$repo/src" "$wiki/plans" "$wiki/.runtime" "$outside" "$tmp/project-docs-evil"
git -C "$repo" init -q
printf "code\n" > "$repo/src/main.ts"
printf "plan\n" > "$wiki/plans/approved.md"
printf "other\n" > "$wiki/plans/other.md"
printf "other\n" > "$outside/other.md"
printf "secret\n" > "$wiki/.runtime/runtime.json"
printf "secret\n" > "$repo/.env"
printf "secret\n" > "$wiki/.env"
printf "auth\n" > "$wiki/auth.json"
printf "other\n" > "$tmp/project-docs-evil/other.md"
ln -s "$outside" "$wiki/escape"
ln -s "$wiki/.env" "$wiki/disguised.md"
ln -s "$outside" "$repo/src/escape"
ln -s "$wiki/plans/approved.md" "$repo/src/context.md"
ln -s "$repo/.env" "$repo/src/disguised.md"
git -C "$repo" add src/main.ts
export PROJECT_ROOT="$repo"
ok() {
    local name="$1"; shift
    test_case "$name"
    if "$@" >/dev/null 2>&1; then
        test_pass
    else
        test_fail "expected command to succeed"
    fi
}
no() {
    local name="$1"; shift
    test_case "$name"
    if "$@" >/dev/null 2>&1; then
        test_fail "expected command to fail"
    else
        test_pass
    fi
}
has_guidance() { local text; text=$(build_tangle_subtask_prompt "Implement the plan" "$1"); [[ "$text" == *"Read context policy: contextual."* ]]; }
has_reasoning_scope() { local text; text=$(tangle_authorized_read_scopes "$1"); [[ $'\n'"$text"$'\n' == *$'\nsrc/reasoning.md\n'* ]]; }
unset OCTOPUS_TANGLE_READ_SCOPE_MODE OCTOPUS_TANGLE_CONTEXTUAL_READ_ROOTS
ok "strict is default" test "$(tangle_read_scope_mode)" = strict
ok "strict reads tracked code" tangle_read_scope_is_allowed src/main.ts
ok "strict permits future repo context" tangle_read_scope_is_allowed src/generated.ts
no "strict rejects absolute plan" tangle_read_scope_is_allowed "$wiki/plans/approved.md"
no "strict rejects relative secrets" tangle_read_scope_is_allowed .env
no "strict rejects symlink escape" tangle_read_scope_is_allowed src/escape/other.md
no "strict rejects disguised secret" tangle_read_scope_is_allowed src/disguised.md
export OCTOPUS_TANGLE_READ_SCOPE_MODE=contextual
export OCTOPUS_TANGLE_CONTEXTUAL_READ_ROOTS="$wiki"
ok "contextual reads approved external plan" tangle_read_scope_is_allowed "$wiki/plans/approved.md"
ok "contextual reads repo absolute path" tangle_read_scope_is_allowed "$repo/src/main.ts"
ok "contextual reads relative code" tangle_read_scope_is_allowed src/main.ts
ok "contextual preserves future repo reads" tangle_read_scope_is_allowed src/generated.ts
ok "authorized context symlink resolves safely" tangle_read_scope_is_allowed src/context.md
no "unrelated project remains forbidden" tangle_read_scope_is_allowed "$outside/other.md"
no "prefix sibling is not a child root" tangle_read_scope_is_allowed "$tmp/project-docs-evil/other.md"
no "external dot-env forbidden" tangle_read_scope_is_allowed "$wiki/.env"
no "relative dot-env forbidden" tangle_read_scope_is_allowed .env
no "external auth store forbidden" tangle_read_scope_is_allowed "$wiki/auth.json"
no "external disguised secret forbidden" tangle_read_scope_is_allowed "$wiki/disguised.md"
no "external symlink escape forbidden" tangle_read_scope_is_allowed "$wiki/escape/other.md"
no "external self-named hidden config forbidden" tangle_read_scope_is_allowed "$wiki/.runtime/runtime.json"
no "relative symlink escape forbidden" tangle_read_scope_is_allowed src/escape/other.md
no "relative disguised secret forbidden" tangle_read_scope_is_allowed src/disguised.md
no "relative traversal forbidden" tangle_read_scope_is_allowed ../project-docs/plans/approved.md
no "absolute traversal forbidden" tangle_read_scope_is_allowed "$wiki/plans/../plans/approved.md"
no "git metadata forbidden" tangle_read_scope_is_allowed .git/config
no "missing external context forbidden" tangle_read_scope_is_allowed "$wiki/plans/missing.md"
task="1. [CODING] Update — Reads: $wiki/plans/approved.md, src/ — Files: src/main.ts — Task: Implement the approved plan."
reasoning_task="1. [REASONING] Inspect — Reads: src/reasoning.md — Task: Analyze."
reasoning_prefix_task="1. [REASONING] Inspect — Reads: src/reasoning.md.bak — Task: Analyze."
ok "decomposition accepts external approved plan" tangle_validate_parallel_write_scopes "$task"
no "read entry cannot authorize external write" tangle_validate_parallel_write_scopes "1. [CODING] Bad — Reads: $wiki/plans/approved.md — Files: $wiki/plans/approved.md — Task: Edit context."
no "reasoning reads are validated too" tangle_validate_parallel_write_scopes "1. [REASONING] Inspect — Reads: $outside/other.md — Task: Analyze."
ok "scope report includes reasoning reads" has_reasoning_scope "$reasoning_task"
no "scope report does not confuse reasoning read prefixes" has_reasoning_scope "$reasoning_prefix_task"
no "duplicate Reads clauses rejected" tangle_validate_parallel_write_scopes "$task — Reads: $outside/other.md"
ok "worker prompt carries active policy" has_guidance "$task"
export OCTOPUS_TANGLE_CONTEXTUAL_READ_ROOTS="$wiki/plans/approved.md"
ok "single-file grant permits that file" tangle_read_scope_is_allowed "$wiki/plans/approved.md"
no "single-file grant does not grant siblings" tangle_read_scope_is_allowed "$wiki/plans/other.md"
export OCTOPUS_TANGLE_CONTEXTUAL_READ_ROOTS="/"
no "filesystem root is never a grant" tangle_read_scope_is_allowed "$outside/other.md"
unset OCTOPUS_TANGLE_CONTEXTUAL_READ_ROOTS
no "missing allowlist rejects external context" tangle_read_scope_is_allowed "$wiki/plans/approved.md"
export OCTOPUS_TANGLE_READ_SCOPE_MODE=strict
export OCTOPUS_TANGLE_CONTEXTUAL_READ_ROOTS="$wiki"
no "strict still rejects absolute contextual plan" tangle_validate_parallel_write_scopes "$task"
export OCTOPUS_TANGLE_READ_SCOPE_MODE=typo
no "invalid mode fails closed" tangle_read_scope_mode
no "invalid mode fails without Reads" tangle_validate_parallel_write_scopes "1. [CODING] Update — Files: src/main.ts — Task: Implement."

test_summary
