# SESSION

## 2026-03-09: Remote state application and structure-conflict findings

### Final design: accepted remote TODO state is applied textually

Status:
- Implemented.

Policy:
- Once emacs-todoist accepts Todoist as the source of truth for a heading's
  state, the local heading state is updated textually, without calling
  `org-todo`.

Conclusion:
- Remote-applied TODO-state changes are replicated directly, not negotiated
  through Org TODO blockers or Org's state-change hook machinery.

Implementation:
- `emacs-todoist-set-todo-state` now owns emacs-todoist-controlled TODO-state
  application.
- Its docstring explicitly states that it does not call `org-todo` on purpose.
- `emacs-todoist-org-apply-remote` uses that helper for accepted remote state.

Consequences:
- Remote state application no longer depends on Org TODO dependency blockers.
- Parent/child pulls no longer need special ordering to satisfy Org blockers.
- Programmatic remote state application no longer fires
  `org-after-todo-state-change-hook`.
- Package-local hook-suppression state for remote application is no longer
  needed.

Verification:
- `tests/test-org.el` covers the new helper behavior.
- `tests/test-integration.el` contains
  `emacs-todoist-integration/remote-apply-done-bypasses-org-blockers`.
- `tests/test-integration.el` contains
  `emacs-todoist-integration/remote-apply-does-not-trigger-auto-sync`.

### Parent/child structure is not part of conflict detection

Finding:
- Child structure is currently excluded from both local-hash and remote-hash
  computation.

Current hash domains:
- Local hash: `(title, deadline, due string, description, state)`
- Remote hash: `(content, description, due, checked)`

Implications:
- Adding/removing/reparenting children does not mark the parent as locally or
  remotely changed for conflict purposes.
- A remote-added child under an otherwise unchanged parent does not produce a
  parent-level conflict today.

### Behavior of remote-added children today

Single-heading sync:
- `emacs-todoist-sync-single-heading` only reconciles the heading at point.
- Missing remote children are not inserted in that path.
- Existing child headings are also left untouched in that path.

Bulk/subtree/frontend sync:
- The shared bulk pipeline inserts unseen remote items after classification.
- A remote-added child can therefore appear locally without any parent-level
  conflict being raised.

### Open design question

Scenario:
- Org has a parent marked `DONE`, and all local Org children are `DONE`.
- Todoist adds a new active child under that parent.

Current behavior:
- This is not modeled as a conflict by the current hash scheme.
- Depending on the sync entry point, the new child may be ignored
  (`sync-single-heading`) or inserted without conflict (`sync-subtree`,
  `sync-buffer`, frontend sync).

Assessment:
- This is a real model gap.
- If Org parent completion is intended to depend on child completion, this
  should likely become a structure-aware conflict or an explicit reopen-parent
  rule.

Plausible future policies:
- Treat remote-added active child under local `DONE` parent as a sync conflict.
- Auto-reopen the parent when such a child is inserted.
- Expand the conflict model to include structural subtree changes
  (child set / parent_id changes), not just heading-local field changes.

### Auto-sync hook behavior on `DONE`

Finding:
- With `emacs-todoist-mode` enabled, a user-initiated local TODO-state change
  to `DONE` does trigger the auto-sync hook.

Current behavior:
- `emacs-todoist-mode` installs
  `emacs-todoist--auto-sync-todo-state-change` on
  `org-after-todo-state-change-hook`.
- That hook calls `emacs-todoist-sync-subtree` when auto-sync is enabled.

Important distinction:
- Local/manual TODO-state changes fire the hook.
- Package-internal remote-applied TODO-state changes do not fire the hook,
  because they are written textually rather than via `org-todo`.

Why this matters:
- Any design that pushes on local `DONE` must account for the fact that
  user-driven completion already enters the sync pipeline automatically when
  `emacs-todoist-mode` is active.
