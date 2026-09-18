# Tangle read context

`OCTOPUS_TANGLE_READ_SCOPE_MODE` separates read declarations from write scopes.

- `strict` (upstream default): safe repository-relative `Reads:` paths only.
- `contextual`: repository reads plus explicitly supplied external context.
  `OCTOPUS_TANGLE_CONTEXTUAL_READ_ROOTS` is a newline-separated list of absolute
  directory or file paths. Directories authorize descendants; files authorize
  only themselves, never siblings or their parent directories.

The parent launcher owns this list. Never derive it from model output, `Reads:`
declarations, or paths merely mentioned in task prose. Grant project documentation,
the run-specific handoff directory and explicitly approved files, not the whole
filesystem or user home.

Validation resolves symlinks before containment checks, rejects traversal and
common secret/auth paths even under authorized roots, and never reads contents.
Unknown modes fail closed. Python 3 is required for validation; missing Python
fails closed. Declared paths currently cannot contain whitespace.

The active policy is included in decomposition, repair, reconsideration, adequacy
review and worker prompts. External context never becomes writable, including
when adaptive write scope is enabled.

**Boundary:** declaration validation and prompts are not an OS sandbox or a
complete secret detector. With full-access execution an agent can technically
bypass prompts using other tools. Use actual sandboxing and isolated credentials
when enforcement against arbitrary reads is required.
