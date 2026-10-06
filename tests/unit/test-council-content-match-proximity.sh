#!/usr/bin/env bash
# Opt-in named-file proximity for content-match grounding (sail-cruisey #2970 C2).
#
# Default (env unset) is quote-sufficiency, the shipped contract: a verbatim
# quote that resolves in source grounds, named file or not. Setting
# OCTOPUS_COUNCIL_CONTENT_MATCH_PROXIMITY_CHARS=N requires a quoted fragment to
# sit within N chars of a RESOLVING named-file mention (a basename the scan
# actually reached). This pins both the unchanged default and the opt-in.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../helpers/test-framework.sh"
source "$PROJECT_ROOT/scripts/lib/council.sh"

test_suite "Council content-match proximity (opt-in)"

ROOT="$(mktemp -d "${TEST_TMP_DIR:-/tmp}/prox.XXXXXX")"
mkdir -p "$ROOT/functions-v2"
cat > "$ROOT/functions-v2/sailing-compare.ts" <<'TS'
export async function compareSailings(r, shipId, sailDate) {
  const shipCode = r.rc_ship_code ?? r.class_code;
  return shipCode;
}
TS
QUOTE='const shipCode = r.rc_ship_code ?? r.class_code;'

_score() { council_response_content_match_count "$1" "$ROOT"; }

test_case "DEFAULT (off): a bare quote with no named file still grounds (contract unchanged)"
bare="$(mktemp "$TEST_TMP_DIR/bare.XXXXXX")"
printf 'Generally the derivation `%s` is a standard fallback. VERDICT: APPROVE\n' "$QUOTE" > "$bare"
if [[ "$(_score "$bare")" -gt 0 ]]; then test_pass; else test_fail "default changed — bare quote stopped grounding"; fi

test_case "ON: a bare quote with no named file is blind"
if [[ "$(OCTOPUS_COUNCIL_CONTENT_MATCH_PROXIMITY_CHARS=1500 _score "$bare")" == "0" ]]; then test_pass; else test_fail "proximity did not blind the unnamed quote"; fi

test_case "ON: a quote with a resolving named file nearby grounds"
named="$(mktemp "$TEST_TMP_DIR/named.XXXXXX")"
printf 'In functions-v2/sailing-compare.ts the derivation `%s` is correct. VERDICT: APPROVE\n' "$QUOTE" > "$named"
if [[ "$(OCTOPUS_COUNCIL_CONTENT_MATCH_PROXIMITY_CHARS=1500 _score "$named")" -gt 0 ]]; then test_pass; else test_fail "resolving named file nearby did not ground"; fi

test_case "ON: a named file that does NOT resolve under root does not ground"
ghost="$(mktemp "$TEST_TMP_DIR/ghost.XXXXXX")"
printf 'In totally-made-up-nowhere.ts the derivation `%s` is correct. VERDICT: APPROVE\n' "$QUOTE" > "$ghost"
if [[ "$(OCTOPUS_COUNCIL_CONTENT_MATCH_PROXIMITY_CHARS=1500 _score "$ghost")" == "0" ]]; then test_pass; else test_fail "a non-resolving filename anchored the quote"; fi

test_case "ON: a resolving named file beyond the window does not ground (distance enforced)"
far="$(mktemp "$TEST_TMP_DIR/far.XXXXXX")"
pad="$(head -c 200 /dev/zero | tr '\0' 'x')"
printf 'functions-v2/sailing-compare.ts %s the derivation `%s` is correct. VERDICT: APPROVE\n' "$pad" "$QUOTE" > "$far"
# window 40 chars < the 200-char pad between the filename and the quote
if [[ "$(OCTOPUS_COUNCIL_CONTENT_MATCH_PROXIMITY_CHARS=40 _score "$far")" == "0" ]]; then test_pass; else test_fail "quote grounded despite the named file being out of window"; fi

test_case "ON: same file within a generous window grounds (distance is the only difference)"
if [[ "$(OCTOPUS_COUNCIL_CONTENT_MATCH_PROXIMITY_CHARS=1500 _score "$far")" -gt 0 ]]; then test_pass; else test_fail "widening the window did not admit the same response"; fi

# Fenced block: the filename is on the first line, the matching quote many lines
# below. Per-line offsets must measure the real distance — with a block-start
# offset the two would collapse together and wrongly ground under a small window.
test_case "ON: fenced-block lines carry real offsets (filename far above the quote → blind)"
fenced="$(mktemp "$TEST_TMP_DIR/fenced.XXXXXX")"
{ printf 'Reviewed:\n```ts\n// functions-v2/sailing-compare.ts\n'
  for _ in $(seq 1 6); do printf '// padding line to push the quote well past a small window\n'; done
  printf '%s\n```\nVERDICT: APPROVE\n' "$QUOTE"; } > "$fenced"
if [[ "$(OCTOPUS_COUNCIL_CONTENT_MATCH_PROXIMITY_CHARS=40 _score "$fenced")" == "0" ]]; then test_pass; else test_fail "fenced quote grounded despite the filename being far above it (offsets collapsed)"; fi

test_case "ON: that same fenced block grounds under a window spanning the gap"
if [[ "$(OCTOPUS_COUNCIL_CONTENT_MATCH_PROXIMITY_CHARS=1500 _score "$fenced")" -gt 0 ]]; then test_pass; else test_fail "fenced quote did not ground even within a generous window"; fi

test_summary
