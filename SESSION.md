# SESSION

## Open Problems

### Parent/child structure is not part of conflict detection

Finding:
- Parent conflict detection is still heading-local.
- Child structure is excluded from both local-hash and remote-hash
  computation.

Current hash domains:
- Local hash: `(title, deadline, due string, description, state)`
- Remote hash: `(content, description, due, checked)`

Implications:
- Adding, removing, or reparenting children does not mark the parent as
  changed for conflict purposes.
- A remote-added child under an otherwise unchanged parent does not produce a
  parent-level conflict today.

### Remote-added child under local `DONE` parent

Scenario:
- Org has a parent marked `DONE`.
- All local Org children are `DONE`.
- Todoist adds a new active child under that parent.

Current behavior:
- `emacs-todoist-sync-single-heading` ignores that new child.
- `emacs-todoist-sync-subtree`, `emacs-todoist-sync-buffer`, and frontend sync
  can insert that child without raising a conflict.
- The parent does not become conflicted merely because its child set changed.

Why this is a problem:
- If parent completion is intended to depend on child completion, the model is
  incomplete.
- The local outline can end up with a `DONE` parent and a newly inserted active
  child without any explicit conflict step.

Open policy choices:
- Treat remote-added active child under local `DONE` parent as a sync conflict.
- Auto-reopen the parent when such a child is inserted.
- Expand conflict detection to include structural subtree changes
  (`parent_id`, child set, child count), not just heading-local fields.
