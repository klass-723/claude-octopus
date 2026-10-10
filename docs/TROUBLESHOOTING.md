# Troubleshooting

The most common failure is a provider that will not authenticate or is silently skipped. Start with the two built-in diagnostics, then use the per-provider table.

```bash
octopus doctor                  # local install, auth signals, versions, and configuration
octopus doctor providers --live # bounded live AGY catalog/model/dispatch check
octopus <cmd> --verbose         # per-dispatch detail: which provider, which model, why skipped
```

Inside Claude Code, invoke the same diagnostics with `/octo:skill-doctor`.
That namespaced skill preserves Claude Code's native `/doctor` command.

For model-selection questions specifically, `OCTOPUS_TRACE_MODELS=1` prints the resolution tier (env pin, session override, phase route, capability map, default) for every dispatch.

## Provider auth failures

A provider is used only when its CLI is installed AND its auth check passes. If a provider you expect is missing from banners and agent tables, it failed one of these checks.

| Provider | Availability check | Fix |
|----------|-------------------|-----|
| 🔴 Codex | `codex` on PATH, auth configured | `codex login` (ChatGPT subscription) or set `OPENAI_API_KEY` |
| 🧭 Antigravity | `agy` on PATH; opt-in live check verifies catalog, model, and dispatch | Launch plain `agy` and finish its browser sign-in, then run `octopus doctor providers --live`. There is no separate login shell subcommand. On macOS keyring errors, open Keychain Access, find the Antigravity CLI item, and allow `agy` under Access Control. See the official [install/auth](https://antigravity.google/docs/cli/install) and [troubleshooting](https://antigravity.google/docs/cli/troubleshooting) guides. |
| 🟢 Copilot | `copilot` on PATH plus one of: `COPILOT_GITHUB_TOKEN`, `GH_TOKEN`, `GITHUB_TOKEN`, `~/.copilot/config.json`, or `gh auth status` passing | `gh auth login` is the simplest path |
| 🟤 Qwen | `qwen` on PATH plus `~/.qwen/oauth_creds.json` or `QWEN_API_KEY` | Free OAuth ended 2026-04-15; set `QWEN_API_KEY` or Coding-Plan auth (`OPENAI_API_KEY` + `OPENAI_BASE_URL`) |
| ⚫ Ollama | `ollama` on PATH AND server responding at `http://localhost:11434` | `ollama serve`; a missing model is NOT auto-pulled (see below) |
| 🟣 Perplexity | `PERPLEXITY_API_KEY` set | Export the key; no CLI needed |
| 🌐 OpenRouter | Enabled in config AND `OPENROUTER_API_KEY` set | Export the key |
| 🟤 OpenCode | `opencode` on PATH, `opencode auth list` succeeds | `opencode auth login` |
| 🟪 Cursor CLI | `agent` on PATH reporting a CalVer version, plus `CURSOR_API_KEY` or an authenticated session (`agent status` says authenticated; older builds also persist `authInfo` in `~/.cursor/cli-config.json`) | `agent login` or export `CURSOR_API_KEY`; pin models with flat IDs from `agent models` (bracket overrides are rejected) |
| ⚡ Grok | `grok` on PATH plus `XAI_API_KEY` or `~/.grok/auth.json` | `grok login` or export `XAI_API_KEY` |
| 🔵 claude-sdk seat | `CLAUDE_SDK_API_KEY` set | Export an Anthropic API key; the shim exits with code 78 and "CLAUDE_SDK_API_KEY is not set" without it |

## Common non-auth failures

**"Circuit open for <provider> — skipping"** — the provider failed repeatedly this session and its circuit breaker tripped. It recovers automatically after the cooldown; to force it back immediately, start a new session or clear session state.

**Provider quota-dead** — a provider that hit quota or auth-death earlier in the session is skipped for the rest of it. Check the provider's own dashboard, then restart the session.

**"TIMEOUT EXCEEDED" on every provider in a phase**: each provider call has a per-call budget. Raise it for the whole run with `--timeout SECS` or `OCTOPUS_AGENT_TIMEOUT=SECS`; the environment variable wins when both are set. Calls a workflow runs deliberately unbounded stay unbounded. Council seats use `--seat-timeout` or `OCTOPUS_COUNCIL_TIMEOUT_<PROVIDER>` instead. If a provider keeps exploring the repository for a narrow question, a shorter prompt that asks for decisions rather than investigation is usually faster than a larger budget.

**"Context budget: summarizer unavailable and the council prompt … Refusing to truncate"**: a council prompt exceeded the seat's context budget and no summarizer could condense it. Council seats fail with exit 78 instead of reviewing a silently truncated artifact, because a truncated diff still produces confident APPROVE verdicts. Split the diff per file (`git diff -- <paths>` chunks that each fit the budget) and dispatch one council per chunk. To accept truncation anyway, set `OCTOPUS_COUNCIL_ALLOW_TRUNCATION=1`.

**Antigravity reports "Individual quota reached"**: the quota belongs to the account `agy` is signed into for headless runs, and a working interactive session does not rule it out. Run plain `agy`, check the signed-in account and plan in the startup banner and `/usage`, and use `/logout` then `/login` to switch accounts or choose an enterprise sign-in with a Cloud project. Octopus marks `agy` quota-dead until the reported reset, and grasp then uses Claude for success criteria and consensus.

**Ollama model missing, nothing downloads** — intentional. Auto-pull is fail-closed to prevent unbounded multi-GB downloads. Pull explicitly (`ollama pull <model>`) or allow it with `OCTOPUS_OLLAMA_ALLOW_PULL=true` (capped by `OCTOPUS_OLLAMA_MAX_PULL_GB`, default 20).

**A provider is installed but you want it out of the roster** — `/octo:model-config disable <provider> --session` removes it from detection and fanout for the current session; `clear-allowlist --session` restores defaults.

**Config changes not taking effect** — settings are re-read when the ConfigChange hook fires; if in doubt, check for the reload log line ("ConfigChange detected") or restart the session.

**Fable dispatch refused or empty** — possible for security-audit phrasing on `claude-fable-5-1` or preserved `claude-fable-5` pins; the plugin reroutes security passes and retries refused claude-sdk dispatches once on Opus 5 by default. Set `OCTOPUS_FABLE5_FALLBACK_MODEL` to replace that fallback target. Details: `skills/blocks/fable5-prompting.md`. Disable the guards with `OCTOPUS_FABLE5_MODE=off`.

**Empty results from a dispatch that "succeeded"** — check `~/.claude-octopus/results/` for the raw artifact and `~/.claude-octopus/logs/` for the dispatch log. `--verbose` on the next run shows the constructed command.

**Waiting on `orchestrate.sh spawn` fires too early** — the result file echoes the prompt before the provider answers, so polling it for `VERDICT` (or any word the prompt contains) matches the prompt itself. A background spawn prints `TASK_ID=`, `RESULT_FILE=`, `DONE_FILE=` and `RESULT_END_SENTINEL=` lines before its final PID line (the PID stays the last line). Wait for the `.done` marker to exist (it holds the worker's exit code), or for the result file's final line to be exactly `=== OCTOPUS-RESULT-END <task-id> rc=<n> ===`. Only then read the verdict. `agy` spawns run synchronously and print the answer on stdout, so they write no result file.

**A council seat with `path:line` citations is marked `blind` / `invalid-ungrounded`** — when a seat quotes code (a backtick span or fenced block of at least 3 tokens and 20 characters) within about 1500 characters of a citation that resolves, the quote must appear, whitespace-normalized, in a cited file. If none of those quotes appear in a cited file, the seat is not counted. `summary.json` records per-seat counts under `seats[].grounding` (`quotes_checked`, `quotes_verified`, `quotes_near_line`, `quotes_unverified`, `quotes_unverifiable`, and `unverified_samples`). Quotes in files the runner cannot read count as unverifiable, never as fabricated. A quote of deleted code is checked against the removed side, and then the added side, of the reviewed diff. That diff comes from any `--context-file` that is a unified diff, plus `git diff <base>` in the evidence root, where the base is `OCTOPUS_COUNCIL_DIFF_BASE` (default `HEAD`, the uncommitted change). These matches are counted in `quotes_verified_in_diff_removed` and `quotes_verified_in_diff_added`. With no diff available, a quote the seat describes as removed, deleted or dropped is unverifiable (`quotes_unverifiable_claimed_removed`), not fabricated. Set `OCTOPUS_COUNCIL_QUOTE_VERIFY=0` to turn the check off.

## Uninstall the plugin and keep local data

Run this from a terminal:

```bash
claude plugin uninstall octo
```

If Claude reports a scope mismatch, rerun it with `--scope project`. Reload or
restart Claude Code afterward so the removed commands and hooks are no longer
active.

Plugin uninstall does not delete your data. Results and logs remain in
`~/.claude-octopus/results/` and `~/.claude-octopus/logs/`. Configuration,
preferences, and other local state remain under `~/.claude-octopus/`. Each
project's run state remains in its `.octo/` directory. You can reinstall later
and keep using this data.

## Review retained data before manual removal

Inventory retained paths before deciding what to keep:

```bash
du -sh "${HOME}/.claude-octopus" 2>/dev/null
find "${HOME}/.claude-octopus" -mindepth 1 -maxdepth 2 -print 2>/dev/null
find . -maxdepth 3 -type d -name '.octo' -prune -print
```

These commands only list paths and disk use. They do not delete anything.
Archive results, logs, or configuration that you may need. Then review the
exact paths and require an explicit confirmation before deleting them with your
shell or file manager. Avoid wildcards and broad parent directories.

Claude Octopus does not provide an automatic purge command. A purge workflow
would need its own dry run, archive option, exact-path validation, and
confirmation gate before it could safely remove retained data.

## Escalation

If `octopus doctor` is green and a workflow still fails, capture `--verbose` output plus the session log and open an issue: https://github.com/nyldn/claude-octopus/issues
