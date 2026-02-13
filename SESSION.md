# Session notes

## Discovered issues

- `org-entry-put` with nil value silently sets an empty property
  (no error) in Emacs 30.2 / Org 9.7.11. Code must validate
  values before passing to `org-entry-put`.
- Stale `.elc` files can shadow source changes — the `.elc` was
  gitignored but present locally, causing confusing test failures.
  Consider adding `make clean` target or `*.elc` cleanup to test
  targets.
- Running specific tests via `MATCH=` does not seem to work for
  live tests. `make test-live MATCH=remote-complete` still ran all 9
  tests instead of filtering to the one matching test. The `make test`
  target uses `MATCH` via `run-tests.el`, but `test-live` loads
  `test-live.el` directly and calls `ert-run-tests-batch-and-exit`
  with no selector — the `MATCH` variable is likely never consulted.
  Need to wire up the `MATCH` filtering in the `test-live` Makefile
  target (or share the filtering logic from `run-tests.el`).

## Other TODOs
- Error message should appear to the user (not just logged to the log file.)
