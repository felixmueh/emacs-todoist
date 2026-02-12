# emacs-todoist

Bidirectional sync between org-mode TODOs and Todoist via the Sync
API v1.

## Architecture

Three modules with strict dependency direction:

```
emacs-todoist.el  (integration: config, sync logic, interactive commands)
  ├── emacs-todoist-org.el  (pure org-mode parsing/manipulation, no API)
  └── emacs-todoist-api.el  (Todoist Sync API wrapper, no org dependency)
```

- **`emacs-todoist-org.el`** — 13 functions. All assume point is on
  an org heading. No network calls. Testable in isolation.
- **`emacs-todoist-api.el`** — 12 functions. Stateless: sync tokens
  passed in by callers, new tokens returned. Uses `url-retrieve`
  (built-in async). No org dependency.
- **`emacs-todoist.el`** — Wires org + api together. All async logic
  uses callback chains since `url-retrieve` is async. Contains
  `defcustom` declarations, logging, sync logic, and interactive
  commands.

## Sync state model

All state lives in org heading properties — no external caches:

| Property              | Purpose                                      |
|-----------------------|----------------------------------------------|
| `TODOIST_ID`          | Real Todoist task ID                         |
| `TODOIST_PROJECT`     | Project ID override                          |
| `TODOIST_LOCAL_HASH`  | SHA-1 of (title, deadline, desc, state)      |
| `TODOIST_REMOTE_HASH` | SHA-1 of Todoist item's sync-relevant fields |
| `TODOIST_SYNC_TOKEN`  | Sync token from last successful sync         |

**Change detection** (two-hash scheme):
```
local_changed  = sha1(current heading) ≠ TODOIST_LOCAL_HASH
remote_changed = sha1(fetched task)    ≠ TODOIST_REMOTE_HASH
```

Both hashes update together after each successful sync.

**Sync token strategy for batch operations** (`sync-buffer`):
- All tokens identical → use that token (incremental)
- Tokens differ → use `"*"` (full sync)
- Response token written back to all synced headings

**Deletion detection**:
- Incremental sync: missing item = unchanged (no action)
- Full sync (`"*"`): missing item = deleted remotely → prompt user:
  delete local, re-push, or unlink

## Testing

```sh
make test              # All 90 tests (39 org + 36 api + 14 integration + 1 smoke)
make test-org          # Only org module tests
make test-api          # Only API tests (no HTTP, no rate limits)
make test-integration  # Only integration tests

# Filter by file and pattern:
make test FILE=test-org MATCH=description
```

All API tests mock `url-retrieve` via `cl-letf` — no real network
calls. Integration tests mock `emacs-todoist-api-sync` similarly.

Test helpers: `with-org-buffer` (temp org buffer with point at first
heading), `with-mock-sync` (mocks `emacs-todoist-api-sync` and
captures calls in `emacs-todoist-test--sync-calls`).

## Conventions

- **defvar vs defcustom**: `emacs-todoist-api-token` and
  `emacs-todoist-default-project` have `defvar` stubs in their
  respective sub-modules (to avoid byte-compiler warnings). The real
  `defcustom` definitions live in `emacs-todoist.el`.
- **Hashing**: Local hash uses `(sha1 (format "%S" (list ...)))` on
  org heading fields. Remote hash uses the same approach on Todoist
  item alist fields. The two hash functions intentionally operate on
  different data shapes.
- **Temp IDs**: When pushing a heading with children, the parent gets
  a temp_id that children reference as `parent_id`. The API resolves
  these server-side, and the response's `temp_id_mapping` maps them to
  real IDs.
- **Async callbacks**: All code after `emacs-todoist-api-sync` runs
  in a callback. Use `point-marker` before the async call to safely
  navigate back to the heading.

## Implementation phases

- [x] Phase 0: Dev tooling (Makefile, test runner)
- [x] Phase 1: Org module — 13 functions + 39 tests
- [x] Phase 2: API module — 12 functions + 36 tests
- [x] Phase 3: Integration layer — sync logic, logging, 14 tests
- [ ] Phase 4: Bulk sync + frontend
- [ ] Phase 5: Polish (README.org, autoloads, package headers)

## Phase 4: Bulk sync + frontend (next up)

### `emacs-todoist-sync-buffer` command

Sync all `TODOIST`-linked headings in the current buffer:
1. Collect all headings via `emacs-todoist-org-synced-entries`
2. Determine sync token strategy:
   - All `TODOIST_SYNC_TOKEN` identical → use it (incremental)
   - Tokens differ → use `"*"` (full sync)
3. Fetch remote items in one API call
4. For each heading: compare hashes, push/pull/skip as needed
5. Write new sync token back to all synced headings

### `emacs-todoist-open` frontend buffer

1. Call `emacs-todoist-api-fetch-items` with `"*"` to get all tasks
2. Create ephemeral `*Todoist*` buffer in `org-mode`
3. Render each task as an org heading:
   - TODO/DONE state from `checked`
   - DEADLINE from `due.date`
   - Description as body text
   - All `TODOIST_*` properties set
   - Sub-tasks nested as sub-headings
4. Group top-level headings by project (as level-1 headings)
5. Mark buffer as not visiting a file (ephemeral)
6. All `emacs-todoist-sync-*` commands work in this buffer

### Tests needed for Phase 4

- `sync-buffer`: all same token → incremental; mixed → full sync
- `sync-buffer`: handles mix of changed/unchanged headings
- Deletion: full sync missing task → prompts user with 3 options
- Frontend: renders tasks correctly, groups by project

## Phase 5: Polish

- Add `;;;###autoload` cookies to interactive commands
- Package headers (Version, Package-Requires, URL, Keywords)
- `README.org` with usage instructions
- `SESSION.md` for discovered issues

## Known future work (not MVP)

- Parent/child structure change conflict resolution
- ediff for conflict resolution (currently prompts local vs remote)
- Todoist labels/priorities mapping
- Recurring task support
