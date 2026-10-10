#!/usr/bin/env bash
# Quote verification for council grounding (sail-cruisey #2997).
#
# A seat that cites a real `path:line` used to be valid-grounded even when the
# code it quoted beside that citation existed nowhere in the file. The runner
# now checks each specific quote (backtick span or fenced block near a resolving
# citation) against the cited files; when none verify, the seat is blind.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../helpers/test-framework.sh"
source "$PROJECT_ROOT/scripts/lib/council.sh"

test_suite "Council quote grounding verification"

ROOT="$(mktemp -d "${TEST_TMP_DIR:-/tmp}/quote-root.XXXXXX")"
mkdir -p "$ROOT/src"
{
    printf 'export function priceFor(cabin, sailing) {\n'
    printf '  const base = cabin.basePrice ?? sailing.defaultPrice;\n'
    printf '  if (!base) return null;\n'
    printf '  return applyTaxes(base, sailing.portFees);\n'
    printf '}\n'
    for i in $(seq 1 80); do printf '// filler line %s\n' "$i"; done
    printf 'export const DISCOUNT_RULES = Object.freeze({ loyaltyTier: 0.05, earlyBird: 0.1 });\n'
} > "$ROOT/src/pricing.ts"
REAL_NEAR='const base = cabin.basePrice ?? sailing.defaultPrice;'
REAL_FAR='export const DISCOUNT_RULES = Object.freeze({ loyaltyTier: 0.05, earlyBird: 0.1 });'
FAKE='const base = await fetchCabinPrice(cabin.id, { cache: true });'

_resp() { local f; f="$(mktemp "$TEST_TMP_DIR/resp.XXXXXX")"; printf '%s\n' "$1" > "$f"; printf '%s\n' "$f"; }
_report() { council_response_quote_verification_json "$1" "$ROOT"; }
_field() { jq -r ".$2" <<< "$(_report "$1")"; }

test_case "fabricated quote beside a real path:line is checked, unverified, and fabricated"
fab="$(_resp "In src/pricing.ts:2 the base price is \`$FAKE\` which caches correctly.
VERDICT: APPROVE")"
r="$(_report "$fab")"
if jq -e '.citations == 1 and .quotes_checked == 1 and .quotes_verified == 0 and .quotes_unverified == 1 and .fabricated == true' <<< "$r" >/dev/null &&
   jq -e '.unverified_samples[0] | contains("fetchCabinPrice")' <<< "$r" >/dev/null; then test_pass; else test_fail "report: $r"; fi

test_case "a seat whose only citation quotes are fabricated is blind and not substantive"
if council_response_is_blind "$fab" "$ROOT" && ! council_response_is_substantive "$fab" "$ROOT"; then test_pass; else test_fail "fabricated-quote seat still counted"; fi

test_case "contribution record marks the seat invalid-ungrounded with per-seat grounding counts"
record="$(council_contribution_record_json "$fab" "$ROOT" sha256:test)"
if jq -e '.validation_result == "invalid-ungrounded" and .access_state == "evidence-rejected" and .evidence_paths == []
          and .grounding.quotes_checked == 1 and .grounding.quotes_verified == 0 and .grounding.fabricated == true' <<< "$record" >/dev/null; then
    test_pass
else
    test_fail "record: $record"
fi

test_case "a real quote near the cited line verifies (near_line) and stays valid-grounded"
real="$(_resp "In src/pricing.ts:2 the fallback \`$REAL_NEAR\` is correct.
VERDICT: APPROVE")"
r="$(_report "$real")"
record="$(council_contribution_record_json "$real" "$ROOT" sha256:test)"
if jq -e '.quotes_checked == 1 and .quotes_verified == 1 and .quotes_near_line == 1 and .fabricated == false' <<< "$r" >/dev/null &&
   jq -e '.validation_result == "valid-grounded" and .grounding.quotes_verified == 1' <<< "$record" >/dev/null &&
   ! council_response_is_blind "$real" "$ROOT"; then test_pass; else test_fail "report: $r record: $record"; fi

test_case "a real quote far from the cited line still verifies (anywhere in file), not near_line"
farq="$(_resp "src/pricing.ts:2 references \`$REAL_FAR\` for discounts.
VERDICT: APPROVE")"
r="$(_report "$farq")"
if jq -e '.quotes_verified == 1 and .quotes_near_line == 0 and .fabricated == false' <<< "$r" >/dev/null; then test_pass; else test_fail "report: $r"; fi

test_case "one verified quote among fabricated ones keeps the seat grounded"
mixed="$(_resp "src/pricing.ts:2 has \`$REAL_NEAR\` and also \`$FAKE\`.
VERDICT: APPROVE")"
r="$(_report "$mixed")"
if jq -e '.quotes_checked == 2 and .quotes_verified == 1 and .quotes_unverified == 1 and .fabricated == false' <<< "$r" >/dev/null &&
   ! council_response_quotes_fabricated "$mixed" "$ROOT"; then test_pass; else test_fail "report: $r"; fi

test_case "short fragments below the token/char floor are not checked"
short="$(_resp "src/pricing.ts:3 does \`return nothing\` and \`x = y\` here.
VERDICT: APPROVE")"
if [[ "$(_field "$short" quotes_checked)" == 0 && "$(_field "$short" fabricated)" == false ]]; then test_pass; else test_fail "report: $(_report "$short")"; fi

test_case "a citation with no quote is unaffected (valid-grounded, nothing checked)"
noquote="$(_resp "The null guard at src/pricing.ts:3 handles a missing base price.
VERDICT: APPROVE")"
record="$(council_contribution_record_json "$noquote" "$ROOT" sha256:test)"
if jq -e '.validation_result == "valid-grounded" and .grounding.quotes_checked == 0 and .grounding.citations == 1' <<< "$record" >/dev/null; then test_pass; else test_fail "record: $record"; fi

test_case "fenced quotes are whitespace-normalized; line-number gutters and diff markers are stripped"
fenced="$(_resp "Reviewed src/pricing.ts:2:
\`\`\`ts
  2 |    const base   = cabin.basePrice
  2 |        ?? sailing.defaultPrice;
\`\`\`
and the change:
\`\`\`diff
@@ -1,4 +1,4 @@
-  const base = cabin.oldPrice || sailing.legacyPrice;
+  if (!base) return null;
\`\`\`
VERDICT: APPROVE")"
r="$(_report "$fenced")"
if jq -e '.quotes_checked == 2 and .quotes_verified == 2 and .fabricated == false' <<< "$r" >/dev/null; then test_pass; else test_fail "report: $r"; fi

test_case "an elided quote verifies when each specific piece is in the file"
elided="$(_resp "src/pricing.ts:1 \`export function priceFor(cabin, sailing) { ... return applyTaxes(base, sailing.portFees);\`
VERDICT: APPROVE")"
if [[ "$(_field "$elided" quotes_verified)" == 1 ]]; then test_pass; else test_fail "report: $(_report "$elided")"; fi

test_case "a quote far beyond the proximity window of every citation is not checked"
pad="$(head -c 1700 /dev/zero | tr '\0' 'x')"
distant="$(_resp "src/pricing.ts:2 is fine. $pad \`$FAKE\`
VERDICT: APPROVE")"
if [[ "$(_field "$distant" quotes_checked)" == 0 ]]; then test_pass; else test_fail "report: $(_report "$distant")"; fi

test_case "a quoted citation is not treated as a code quote"
quotedcite="$(_resp "See \`src/pricing.ts:2 handles the missing price case\` for details.
VERDICT: APPROVE")"
if [[ "$(_field "$quotedcite" quotes_checked)" == 0 ]]; then test_pass; else test_fail "report: $(_report "$quotedcite")"; fi

test_case "a cited file too large to read is unverifiable, never fabricated"
python3 -c 'import sys; open(sys.argv[1], "w").write("// big\n" * 260000)' "$ROOT/src/huge.ts"
huge="$(_resp "src/huge.ts:2 contains \`$FAKE\` today.
VERDICT: APPROVE")"
r="$(_report "$huge")"
if jq -e '.quotes_checked == 1 and .quotes_unverifiable == 1 and .quotes_unverified == 0 and .fabricated == false' <<< "$r" >/dev/null; then test_pass; else test_fail "report: $r"; fi

test_case "an unreadable cited file is unverifiable and does not crash"
printf 'const secret = 1;\n' > "$ROOT/src/locked.ts"
chmod 000 "$ROOT/src/locked.ts"
locked="$(_resp "src/locked.ts:1 contains \`$FAKE\` today.
VERDICT: APPROVE")"
if [[ -r "$ROOT/src/locked.ts" ]]; then
    chmod 644 "$ROOT/src/locked.ts"
    test_skip "running with privileges that bypass file modes"
else
    r="$(_report "$locked")"
    chmod 644 "$ROOT/src/locked.ts"
    if jq -e '.quotes_unverifiable == 1 and .fabricated == false' <<< "$r" >/dev/null; then test_pass; else test_fail "report: $r"; fi
fi

test_case "OCTOPUS_COUNCIL_QUOTE_VERIFY=0 disables the check"
if ! OCTOPUS_COUNCIL_QUOTE_VERIFY=0 council_response_quotes_fabricated "$fab" "$ROOT"; then test_pass; else test_fail "opt-out ignored"; fi

test_case "missing evidence root reports nothing and never fabricates"
if [[ "$(council_response_quote_verification_json "$fab" "$ROOT/does-not-exist" | jq -r '.fabricated')" == false ]] &&
   ! council_response_quotes_fabricated "$fab" ""; then test_pass; else test_fail "no-root path fabricated"; fi

# The #2997 shape: a full-length, confident APPROVE with several real path:line
# refs whose quoted "source" is invented. The old validator counted it.
test_case "#2997 replay: long APPROVE with real refs and invented quotes is not counted"
replay="$(_resp "## Review

The pricing path is correct and fully tested.

1. src/pricing.ts:2 — the price is resolved through \`const base = await fetchCabinPrice(cabin.id, { cache: true });\` which memoizes the lookup and prevents duplicate requests.
2. src/pricing.ts:4 — taxes are applied via \`return applyTaxes(base, sailing.portFees, { region: sailing.region });\` so regional fees propagate.
3. src/pricing.ts:86 — discounts come from \`DISCOUNT_RULES.loyaltyTier.multiplier * base\` and the contract is honored.

All tests pass, the behavior matches the plan, and the endpoint contract is unchanged. No regressions found in the component or schema.

VERDICT: APPROVE")"
r="$(_report "$replay")"
if jq -e '.citations == 3 and .quotes_checked == 3 and .quotes_verified == 0 and .fabricated == true' <<< "$r" >/dev/null &&
   ! council_response_is_substantive "$replay" "$ROOT" &&
   [[ "$(council_contribution_record_json "$replay" "$ROOT" sha256:t | jq -r '.validation_result')" == invalid-ungrounded ]]; then
    test_pass
else
    test_fail "report: $r"
fi

# ── Removed-code quotes (reviewers quote deleted lines: "this guard was removed").
# That code exists in no working-tree file, so it is checked against the removed
# (and added) side of the reviewed diff before being called fabricated.
GROOT="$(mktemp -d "${TEST_TMP_DIR:-/tmp}/quote-git.XXXXXX")"
mkdir -p "$GROOT/src"
GUARD='if (!sailing.isBookable) throw new BookingClosedError(sailing.id);'
printf 'export function book(sailing, cabin) {\n  %s\n  return reserve(sailing, cabin);\n}\n' "$GUARD" > "$GROOT/src/book.ts"
git -C "$GROOT" init -q
git -C "$GROOT" add src/book.ts
git -C "$GROOT" -c user.email=t@example.invalid -c user.name=t commit -q -m base
printf 'export function book(sailing, cabin) {\n  return reserve(sailing, cabin);\n}\n' > "$GROOT/src/book.ts"
_greport() { council_response_quote_verification_json "$1" "$GROOT"; }

test_case "removed-line quote (git diff HEAD) verifies via the diff's removed side and is not blind"
removed_only="$(_resp "At src/book.ts:2 the guard \`$GUARD\` was removed, so closed sailings can be booked.
VERDICT: REVISE")"
r="$(_greport "$removed_only")"
if jq -e '.quotes_checked == 1 and .quotes_verified == 1 and .quotes_verified_in_diff_removed == 1 and .fabricated == false
          and (.diff_sources | index("git-diff:HEAD"))' <<< "$r" >/dev/null &&
   ! council_response_is_blind "$removed_only" "$GROOT"; then test_pass; else test_fail "report: $r"; fi

test_case "fabricated quote in the same diff-bearing repo is still blind"
git_fab="$(_resp "At src/book.ts:2 the code \`if (sailing.status === 'closed') return refundAll(cabin);\` handles closures.
VERDICT: APPROVE")"
r="$(_greport "$git_fab")"
if jq -e '.quotes_checked == 1 and .quotes_verified == 0 and .quotes_unverified == 1 and .fabricated == true' <<< "$r" >/dev/null &&
   council_response_is_blind "$git_fab" "$GROOT"; then test_pass; else test_fail "report: $r"; fi

test_case "mixed: a removed-line quote plus a fabricated quote keeps the seat grounded"
git_mixed="$(_resp "src/book.ts:2 dropped \`$GUARD\` and now calls \`if (sailing.status === 'closed') return refundAll(cabin);\`.
VERDICT: REVISE")"
r="$(_greport "$git_mixed")"
if jq -e '.quotes_checked == 2 and .quotes_verified_in_diff_removed == 1 and .quotes_unverified == 1 and .fabricated == false' <<< "$r" >/dev/null &&
   ! council_response_is_blind "$git_mixed" "$GROOT"; then test_pass; else test_fail "report: $r"; fi

test_case "OCTOPUS_COUNCIL_DIFF_BASE selects a committed base (removal already committed)"
git -C "$GROOT" -c user.email=t@example.invalid -c user.name=t commit -q -am remove-guard
r_head="$(_greport "$removed_only")"
r_base="$(OCTOPUS_COUNCIL_DIFF_BASE=HEAD~1 _greport "$removed_only")"
if jq -e '.quotes_verified == 0' <<< "$r_head" >/dev/null &&
   jq -e '.quotes_verified_in_diff_removed == 1 and .fabricated == false and (.diff_sources | index("git-diff:HEAD~1"))' <<< "$r_base" >/dev/null; then
    test_pass
else
    test_fail "head: $r_head base: $r_base"
fi

test_case "a --context-file diff supplies the removed side (non-git root, fenced '-' lines)"
ctx_diff="$TEST_TMP_DIR/reviewed.diff"
printf 'diff --git a/src/pricing.ts b/src/pricing.ts\n--- a/src/pricing.ts\n+++ b/src/pricing.ts\n@@ -2,2 +2,1 @@\n-  if (cabin.soldOut) return { price: null, reason: "sold-out" };\n+  const base = cabin.basePrice ?? sailing.defaultPrice;\n' > "$ctx_diff"
ctx_resp="$(_resp "src/pricing.ts:2 lost its sold-out guard:
\`\`\`diff
-  if (cabin.soldOut) return { price: null, reason: \"sold-out\" };
\`\`\`
VERDICT: REVISE")"
r="$(COUNCIL_CONTEXT_FILES=("$ctx_diff"); _report "$ctx_resp")"
if jq -e '.quotes_checked == 1 and .quotes_verified_in_diff_removed == 1 and .fabricated == false and (.diff_sources | index("context-file"))' <<< "$r" >/dev/null; then
    test_pass
else
    test_fail "report: $r"
fi

test_case "a quote found only on the diff's added side verifies (working tree vs cited file timing)"
printf 'diff --git a/src/pricing.ts b/src/pricing.ts\n@@ -4,1 +4,1 @@\n-  return applyTaxes(base, sailing.portFees);\n+  return applyTaxes(base, sailing.portFees, sailing.region);\n' > "$ctx_diff"
added_resp="$(_resp "src/pricing.ts:4 now does \`return applyTaxes(base, sailing.portFees, sailing.region);\` correctly.
VERDICT: APPROVE")"
r="$(COUNCIL_CONTEXT_FILES=("$ctx_diff"); _report "$added_resp")"
if jq -e '.quotes_verified == 1 and .quotes_verified_in_diff_added == 1 and .fabricated == false' <<< "$r" >/dev/null; then test_pass; else test_fail "report: $r"; fi

test_case "a non-diff context file's '- ' bullets are not treated as removed code"
ctx_plan="$TEST_TMP_DIR/plan.md"
printf '# Plan\n\n- const base = await fetchCabinPrice(cabin.id, { cache: true });\n' > "$ctx_plan"
r="$(COUNCIL_CONTEXT_FILES=("$ctx_plan"); _report "$fab")"
if jq -e '.fabricated == true and .diff_sources == []' <<< "$r" >/dev/null; then test_pass; else test_fail "report: $r"; fi

test_case "no diff available: a quote the seat says was removed is unverifiable, not fabricated"
claimed="$(_resp "At src/pricing.ts:2 the check \`if (cabin.soldOut) return { price: null };\` was deleted in this change.
VERDICT: REVISE")"
r="$(_report "$claimed")"
if jq -e '.quotes_unverifiable == 1 and .quotes_unverifiable_claimed_removed == 1 and .quotes_unverified == 0 and .fabricated == false' <<< "$r" >/dev/null &&
   ! council_response_is_blind "$claimed" "$ROOT"; then test_pass; else test_fail "report: $r"; fi

test_case "summary grounding carries the new diff counters"
record="$(council_contribution_record_json "$removed_only" "$GROOT" sha256:t)"
if jq -e '.grounding | has("quotes_verified_in_diff_removed") and has("quotes_verified_in_diff_added") and has("quotes_unverifiable_claimed_removed") and has("diff_sources")' <<< "$record" >/dev/null &&
   jq -e 'has("quotes_verified_in_diff_removed")' <<< "$COUNCIL_EMPTY_GROUNDING_JSON" >/dev/null; then test_pass; else test_fail "record: $record"; fi

test_summary
