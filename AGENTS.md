# 1 Repository guide

Read [README.md](README.md) first. Read [docs/spec.md](docs/spec.md) before changing
collection, accounting, queries or snapshots; it links behavior to source and tests.
For benchmark changes, read [scripts/run-benchmark.mjs](scripts/run-benchmark.mjs).

## 1a Verify changes

- Run the formatting, test and Clippy commands in the README before reporting completion.
- A behavior change needs a test that fails without it. Report skipped platform checks.
- Tests may mutate only their own temporary fixtures. Keep real inventories, snapshots,
  raw results and build artifacts outside Git. Broad scans need an explicit scope.
- Treat Trash and permanent deletion as explicit, confirmed core operations. During
  development, mutate only owned fixtures. Read metadata without following symlinks,
  reading source-file contents, or elevating permissions.

## 1b Keep documentation beside its evidence

- Describe code as it is now. Update documentation with the code it describes.
  Remove obsolete text; Git retains history. Keep plans and worklogs out of tracked docs.
- Put reasons in a regression test, an error message, or a comment beside the relevant
  setting. Use a document only for behavior that spans files.
- A specification names the test for each tested invariant, with its path and quoted
  test name. Mark untested limits explicitly.
- Keep references repository-local and each Markdown document below 1,500 words.
- Keep this guide for navigation and shared rules, not product explanations.

## 1c Git checkpoints

- Commit focused changes when requested work reaches a verified, stable checkpoint.
- Do not push without an explicit user request.
