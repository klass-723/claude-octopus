#!/usr/bin/env bash
# Content-match excludes agent-instruction / governing-law boilerplate.
#
# These files (CLAUDE.md, AGENTS.md, their -OCTO.md twins, etc.) are injected
# into every seat's prompt context, so a seat can echo their verbatim prose
# without reading any source. The hidden-name prune already drops `.claude/…`;
# this pins that the VISIBLE repo-root twins (e.g. AGENTS-OCTO.md) are excluded
# too, so an echo cannot forge a content-match grounding signal (sail-cruisey
# #2970). Real source quotes must still ground.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../helpers/test-framework.sh"
source "$PROJECT_ROOT/scripts/lib/council.sh"

test_suite "Council content-match boilerplate exclusion"

ROOT="$(mktemp -d "${TEST_TMP_DIR:-/tmp}/boiler.XXXXXX")"
mkdir -p "$ROOT/functions-v2"
# Real source: the only legitimate grounding target.
cat > "$ROOT/functions-v2/sailing-compare.ts" <<'TS'
export async function compareSailings(r, shipId, sailDate) {
  const shipCode = r.rc_ship_code ?? r.class_code;
  return shipCode;
}
TS
# Governing-law prose, duplicated across the visible instruction twins a repo
# using this tooling typically carries at its root.
LAW='Robots vote twice (autonomous, no human stop). **You approve once** - after testing the feature actually works.'
for f in AGENTS-OCTO.md AGENTS.md CLAUDE.md CLAUDE-OCTO.md GEMINI.md; do
    printf '%s\n' "$LAW" > "$ROOT/$f"
done

_score() { council_response_content_match_count "$1" "$ROOT"; }

test_case "a response that only echoes governing-law prose grounds nothing"
echo_only="$(mktemp "$TEST_TMP_DIR/echo.XXXXXX")"
printf 'Per the governing doc: `%s` VERDICT: APPROVE\n' "$LAW" > "$echo_only"
if [[ "$(_score "$echo_only")" == "0" ]]; then test_pass; else test_fail "echo of injected boilerplate forged a content match"; fi

test_case "a real source quote still grounds (exclusion did not over-prune)"
real="$(mktemp "$TEST_TMP_DIR/real.XXXXXX")"
printf 'In functions-v2/sailing-compare.ts: `const shipCode = r.rc_ship_code ?? r.class_code;` VERDICT: APPROVE\n' > "$real"
if [[ "$(_score "$real")" -gt 0 ]]; then test_pass; else test_fail "a verbatim source quote stopped grounding"; fi

test_case "a quote that resolves BOTH in source and in boilerplate still grounds via source"
# The LAW prose is not code; use a code line present in source — confirms the
# scan still reaches real source after skipping the boilerplate twins.
both="$(mktemp "$TEST_TMP_DIR/both.XXXXXX")"
printf 'Reviewed sailing-compare.ts — `export async function compareSailings(r, shipId, sailDate) {` is the entry. VERDICT: APPROVE\n' > "$both"
if [[ "$(_score "$both")" -gt 0 ]]; then test_pass; else test_fail "source quote lost after boilerplate skip"; fi

test_case "each excluded basename is individually inert (incl. nested path + mixed case)"
fails=""
# Cursorrules.md keeps mixed case to prove the match is case-insensitive; each
# twin lives one directory deep to prove the exclusion is not root-only.
for f in AGENTS-OCTO.md AGENTS.md CLAUDE.md CLAUDE-OCTO.md GEMINI.md cursor.md copilot-instructions.md Cursorrules.md; do
    solo="$(mktemp -d "$TEST_TMP_DIR/solo.XXXXXX")"
    mkdir -p "$solo/docs"
    printf '%s\n' "$LAW" > "$solo/docs/$f"
    r="$(mktemp "$TEST_TMP_DIR/soloresp.XXXXXX")"
    printf 'Quote: `%s` VERDICT: APPROVE\n' "$LAW" > "$r"
    [[ "$(council_response_content_match_count "$r" "$solo")" == "0" ]] || fails="$fails $f"
done
if [[ -z "$fails" ]]; then test_pass; else test_fail "grounded via:$fails"; fi

test_summary
