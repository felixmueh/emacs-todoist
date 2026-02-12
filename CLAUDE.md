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

- **`emacs-todoist-org.el`** — All functions assume point is on an org
  heading. No network calls. Testable in isolation.
- **`emacs-todoist-api.el`** — Stateless: sync tokens passed in by
  callers, new tokens returned. Uses `url-retrieve` (built-in async).
- **`emacs-todoist.el`** — Wires org + api together. All async logic
  uses callback chains since `url-retrieve` is async.

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

## Testing

```sh
make test              # All tests (org + api + integration)
make test-org          # Only org module tests
make test-api          # Only API tests (no HTTP, no rate limits)
make test-integration  # Only integration tests

# Filter by file and pattern:
make test FILE=test-org MATCH=description
```

All API tests mock `url-retrieve` via `cl-letf` — no real network
calls. Integration tests mock `emacs-todoist-api-sync` similarly.

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
- [x] Phase 1: Org module + 39 tests
- [x] Phase 2: API module + 36 tests
- [ ] Phase 3: Integration layer + tests (emacs-todoist.el in progress)
- [ ] Phase 4: Bulk sync (`sync-buffer`) + frontend (`emacs-todoist-open`)
- [ ] Phase 5: Polish (README.org, autoloads, package headers)
