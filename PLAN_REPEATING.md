# Plan: Recurring Task Support

Date: 2026-03-08

## Goal

When a recurring Todoist task is marked `DONE` in Org, sync should complete the current occurrence and reschedule the next one (instead of completing the task forever).

## What is broken today

Current push behavior for existing tasks:

- `emacs-todoist--build-push-commands` always sends `item_update` with `due.date`, then sends `item_complete` for `DONE` (`emacs-todoist.el:694`).
- After push, writeback computes `TODOIST_REMOTE_HASH` from a synthetic local item, not from server-returned item state (`emacs-todoist.el:853`, `emacs-todoist.el:1418`).

This breaks recurrence in two ways:

1. `item_complete` on recurring tasks completes forever (no next occurrence).
2. Sending `item_update` with only `due.date` strips recurrence metadata (`due.string`, `is_recurring`), so even `item_close` can become a permanent completion if preceded by that update.

## Verified findings (live API v1 calls)

All checks were run against `https://api.todoist.com/api/v1/sync` on 2026-03-08 with temporary tasks.

1. Recurring + `item_complete`
- Delta response for the task: `checked=true`, `due.is_recurring=true`, `due.date=2026-03-08`.
- Full sync immediately after: task absent.
- Conclusion: completed forever.

2. Recurring + `item_close`
- Delta/full response: same ID still active, `checked=false`, `due.is_recurring=true`, `due.date` advanced from `2026-03-08` to `2026-03-09`.
- Conclusion: this is the correct recurring-completion behavior.

3. Recurring + `item_update(due.date only)` + `item_close`
- Delta response after batch: `due.string="2026-03-08"`, `is_recurring=false`, `checked=true`.
- Full sync after: task absent.
- Conclusion: `item_update` with `due.date` removed recurrence before close.

4. Recurring + `item_update` (no `due`) + `item_close`
- Delta/full response: content/description updated, recurrence preserved, task remains active with next due date.

5. Non-recurring + `item_close`
- Delta shows `checked=true`; full sync shows task absent.
- Conclusion: `item_close` is safe as a replacement for completion semantics on non-recurring tasks too.

## Recommended implementation

### Phase 1 (fix user-visible recurring completion bug)

1. Add API command builder for `item_close` in `emacs-todoist-api.el`.

2. Change completion command in integration layer:
- For local `DONE`, use `item_close` instead of `item_complete`.

3. Prevent recurrence loss during completion:
- In the `DONE` path, do not send `due.date` alone.
- If recurrence is known locally (`TODOIST_DUE_STRING`), send `due.string` (optionally together with `due.date`).
- Keep content/description updates allowed.

4. Make response-driven reconcile mandatory for `DONE` pushes:
- When push returns updated `items`, find the pushed item by `TODOIST_ID`.
- Apply remote item via existing pull logic (`emacs-todoist--apply-pull`) instead of hashing a synthetic local item.
- This ensures recurring tasks flip back to `TODO` and deadline advances in Org immediately.
- Do this in the same sync response path (no extra fetch in the common case).

5. Keep fallback:
- If response does not include a pushed ID, do one follow-up fetch for that item, apply it, and log warning.
- Only if that fetch also fails, fall back to hash-only writeback.

## Tests to add

Integration (mocked):

1. `DONE` push builds `item_close` (not `item_complete`).
2. `DONE` push due payload rules:
- no `due.date`-only update in the completion path;
- with `TODOIST_DUE_STRING`, send `due.string` (optionally plus `due.date`).
3. Push writeback applies returned item state:
- recurring-like response (`checked=0`, next `due.date`) resets Org heading to `TODO` with advanced deadline.
4. `on-done-action` does not fire for recurring completion responses that end in `TODO`.

Live (`tests/test-live.el`):

1. Recurring task: mark `DONE` locally -> after sync heading is `TODO` and deadline advances.
2. Recurring task with local title/description edits + `DONE` -> edits preserved and recurrence preserved.
3. Non-recurring task `DONE` still behaves as completed/archived.

## Recurrence editing approaches (evaluation)

User requirement: support modifying recurrence rules, not only completing recurring tasks.

### Option A: Native Org repeater in `DEADLINE`

Example UX:
- `DEADLINE: <2026-03-08 Sun +1d>` to represent recurring daily.

How it would work:
- Read repeater from deadline timestamp and map to Todoist `due.string`.
- Write back recurring remote tasks as deadline date + repeater cookie.

Pros:
- Most “Org-native” editing flow.
- Recurrence is visible directly in planning line.

Cons / risks:
- Org has built-in repeater behavior on completion: `org-todo "DONE"` immediately advances deadline and flips state back to `TODO`.
  - Verified in batch probe on 2026-03-08: `DONE -> TODO`, deadline shifted to next date, `LAST_REPEAT` added.
  - With `emacs-todoist-mode`, this produced two auto-sync invocations for one user action.
- Todoist recurrence language is richer than Org repeaters (`every weekday`, natural-language patterns, etc.); mapping is lossy.
- Current code only extracts `YYYY-MM-DD` from deadline (`emacs-todoist-org-heading-deadline`), so repeater support requires broad parser/hash/writeback changes.

Verdict:
- Feasible, but high behavioral risk and significant complexity from round-trip mapping + auto-sync interactions.

### Option B: Additional property for recurrence (recommended)

Example:
- `:TODOIST_DUE_STRING: every weekday`
- Keep `DEADLINE` as the current concrete due date (`YYYY-MM-DD`).

How it would work:
- Push:
  - If `TODOIST_DUE_STRING` is non-empty, send `due.string` (and optionally `due.date` as concrete anchor).
  - Else, send `due.date` from `DEADLINE` (current behavior).
- Pull:
  - If remote `due.is_recurring=true`, set/update `TODOIST_DUE_STRING` from `due.string`.
  - Always set `DEADLINE` from remote `due.date`.

Pros:
- Exact round-trip of Todoist recurrence syntax.
- No dependence on Org repeater side effects.
- Lower implementation risk; aligns with existing property-based sync-state model.

Cons:
- Less native than pure planning-line editing.
- Need precedence rules when `TODOIST_DUE_STRING` conflicts with `DEADLINE`.

Verdict:
- Best reliability/usability tradeoff for Todoist parity.

### Option C: Hybrid (optional later)

- Support both repeater and property.
- Make `TODOIST_DUE_STRING` canonical when present.
- If absent, derive recurrence from repeater for a limited subset.

Verdict:
- Good long-term UX, but should follow Option B baseline to avoid ambiguity early.

## Recommended path

1. Implement Option B first (`TODOIST_DUE_STRING`).
2. Define conflict/precedence policy:
- `TODOIST_DUE_STRING` present => recurrence source of truth (`due.string`).
- `TODOIST_DUE_STRING` absent => one-shot date (`due.date`).
3. For `DONE` auto-sync, always reconcile by applying returned remote item state from the push response.
4. Add a follow-up fetch only when the pushed item is missing from response `items`.
5. Add an opt-in compatibility layer later for a subset of Org repeaters.
6. Guard auto-sync behavior explicitly if repeater support is introduced (to avoid duplicate sync triggers on `DONE -> TODO` repeater transitions).

## Additional API findings for recurrence edits (live, 2026-03-08)

- `item_update` with `due.string` successfully edits recurrence in place.
  - Example: `every day` -> `every 2 days` preserved `is_recurring=true` and updated next `due.date`.
- `item_update` accepted `due.string` and `due.date` together in one command, preserving recurrence (`is_recurring=true`).
- Non-recurring -> recurring conversion works via `due.string`.
- Recurring -> non-recurring conversion works via `due.date`.

## References

- Todoist Sync API docs (command set, including recurring completion commands):  
  https://developer.todoist.com/sync/v9/
- Endpoint used by this project and by live verification:  
  https://api.todoist.com/api/v1/sync
