# Session notes

## Discovered issues

- The sub-agent that wrote `emacs-todoist-sync-heading` produced
  a paren imbalance (14 closing parens instead of 13) on the final
  line of the deeply nested cond. Fixed manually. Deeply nested
  Emacs Lisp callbacks are error-prone — consider refactoring to
  flatten the nesting if it grows further.
