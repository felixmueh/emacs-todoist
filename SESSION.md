# Session notes

## Discovered issues

- `org-entry-put` with nil value silently sets an empty property
  (no error) in Emacs 30.2 / Org 9.7.11. Code must validate
  values before passing to `org-entry-put`.
- Stale `.elc` files can shadow source changes — the `.elc` was
  gitignored but present locally, causing confusing test failures.
  Consider adding `make clean` target or `*.elc` cleanup to test
  targets.

## Other TODOs
- Error message should appear to the user (not just logged to the log file.)
