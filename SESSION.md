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
- Syncing heading moves marker (can be avoided with `save-excursion`)
- Add option to diff (ediff) headings when both remote and local changed.
- Have sync-dwim function that syncs the region if one is active otherwise it syncs the subtree. (If we are in front of the topmost heading it syncs the buffer.)
- `emacs-todoist--handle-deletion` in bulk sync calls `read-char-choice` which blocks in batch mode. Could benefit from a non-interactive mode or callback-based approach for testing.
- Bulk sync `--sync-entries-push` reuses the fetch sync token for the push call. If the push itself returns a newer token, child headings that were pulled (not pushed) don't get the push response's token — only the fetch token. This is fine for correctness but means a subsequent incremental sync may re-fetch some items.
