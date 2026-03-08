# emacs-todoist

Bidirectional sync between org-mode TODOs and Todoist via the Sync
API v1.  **Not** v9 — we target the v1 endpoint at
`https://api.todoist.com/api/v1/sync`.

## Architecture

Four modules with strict dependency direction:

```
emacs-todoist.el           (integration: config, core sync logic, interactive commands)
  ├── emacs-todoist-org.el      (pure org-mode parsing/manipulation, no API)
  ├── emacs-todoist-api.el      (Todoist Sync API wrapper, no org dependency)
  └── emacs-todoist-frontend.el (ephemeral *Todoist* org buffer + incremental refresh)
```

- **`emacs-todoist-org.el`** (332 lines) — Pure org-mode operations.
  All functions assume point is on an org heading. No network calls.
  Testable in isolation.
- **`emacs-todoist-api.el`** (296 lines) — Stateless Todoist Sync
  API v1 wrapper. Sync tokens passed in by callers, new tokens
  returned. Uses `url-retrieve` (built-in async). No org dependency.
- **`emacs-todoist.el`** (1213 lines) — Wires org + api together.
  All async logic uses callback chains since `url-retrieve` is async.
  Contains `defcustom` declarations, logging, project cache, sync
  logic, and all interactive commands.
- **`emacs-todoist-frontend.el`** (208 lines) — UI/rendering module
  for `emacs-todoist-open` and `emacs-todoist-frontend-sync`.
  Renders all tasks in an ephemeral org buffer grouped by project and
  applies incremental remote inserts/updates in-place.

### Module function map

**`emacs-todoist-org.el`** — field extraction and org tree operations:

| Function | Purpose |
|----------|---------|
| `emacs-todoist-org-heading-title` | Heading text without TODO/priority/tags |
| `emacs-todoist-org-heading-deadline` | DEADLINE as "YYYY-MM-DD" or nil |
| `emacs-todoist-org-heading-description` | Body text (excludes drawers, planning, children) |
| `emacs-todoist-org-heading-todo-state` | TODO state string or nil |
| `emacs-todoist-org-heading-props` | Alist of all TODOIST_* properties |
| `emacs-todoist-org-set-props` | Write alist of TODOIST_* properties |
| `emacs-todoist-org-heading-local-hash` | SHA-1 of (title, deadline, desc, state) |
| `emacs-todoist-org-heading-local-changed-p` | Compare current vs stored hash |
| `emacs-todoist-org-heading-children` | Markers for direct child headings |
| `emacs-todoist-org-synced-entries` | All headings with TODOIST_ID in buffer |
| `emacs-todoist-org-synced-entries-in-region` | Synced headings in region |
| `emacs-todoist-org-synced-entries-in-subtree` | Synced headings in subtree |
| `emacs-todoist-org-todo-entries` | All TODO headings in buffer |
| `emacs-todoist-org-todo-entries-in-region` | TODO headings in region |
| `emacs-todoist-org-todo-entries-in-subtree` | TODO headings in subtree |
| `emacs-todoist-org-apply-remote` | Update heading from Todoist task alist |
| `emacs-todoist-org--replace-body` | Replace body text (preserves drawers/children) |
| `emacs-todoist-org-resolve-project` | Heading prop → file keyword → global default |
| `emacs-todoist-org-heading-to-alist` | Bundle heading into alist for sync |

**`emacs-todoist-api.el`** — Sync API v1 commands and HTTP:

| Function | Purpose |
|----------|---------|
| `emacs-todoist-api-token` | Get API token (handles string or function) |
| `emacs-todoist-api-generate-uuid` | UUID v4 for command IDs |
| `emacs-todoist-api-build-command` | Build generic Sync API command alist |
| `emacs-todoist-api-item-add` | Build `item_add` (keywords: `:description`, `:project-id`, `:parent-id`, `:due-date`, `:temp-id`) |
| `emacs-todoist-api-item-update` | Build `item_update` (keywords: `:content`, `:description`, `:due-date`, `:project-id`) |
| `emacs-todoist-api-item-complete` | Build `item_complete` commands (one per ID) |
| `emacs-todoist-api-item-uncomplete` | Build `item_uncomplete` commands |
| `emacs-todoist-api-item-delete` | Build `item_delete` commands |
| `emacs-todoist-api-parse-response` | Extract sync_token, sync_status, temp_id_mapping, items, projects |
| `emacs-todoist-api-hash-item` | SHA-1 of (content, description, due, checked) for TODOIST_REMOTE_HASH |
| `emacs-todoist-api-sync` | Core async Sync API call via `url-retrieve` |
| `emacs-todoist-api-fetch-items` | Convenience: read-only items fetch |
| `emacs-todoist-api-fetch-projects` | Convenience: full-sync projects fetch |

**`emacs-todoist.el`** — interactive commands (entry points):

| Command | Purpose |
|---------|---------|
| `emacs-todoist-sync-heading` | Main sync for heading at point (detect + push/pull/conflict) |
| `emacs-todoist-push-heading` | Force push heading (ignore remote state) |
| `emacs-todoist-pull-heading` | Force pull heading (ignore local changes) |
| `emacs-todoist-sync-buffer` | Sync all linked headings in buffer; with `C-u` also push new TODOs |
| `emacs-todoist-sync-subtree` | Sync all linked headings in subtree; with `C-u` also push new TODOs |
| `emacs-todoist-sync-region` | Sync all linked headings in region; with `C-u` also push new TODOs |

**`emacs-todoist-frontend.el`** — frontend commands:

| Command | Purpose |
|---------|---------|
| `emacs-todoist-open` | Create/recreate ephemeral `*Todoist*` org buffer from remote items |
| `emacs-todoist-frontend-sync` | Incremental refresh for the frontend buffer using stored sync token |

**`emacs-todoist.el`** — key internal functions:

| Function | Purpose |
|----------|---------|
| `emacs-todoist-log` | Timestamped logging to `*emacs-todoist-log*` |
| `emacs-todoist--ensure-projects` | Populate project name→ID cache (async, callback-based) |
| `emacs-todoist--resolve-project-id` | Look up name in cache (case-insensitive); pass-through for numeric IDs |
| `emacs-todoist--check-sync-status` | Check per-command sync_status for errors |
| `emacs-todoist--state-to-checked` / `--checked-to-state` | TODO↔checked conversion |
| `emacs-todoist--heading-as-remote-item` | Build fake Todoist item from heading (for hash computation) |
| `emacs-todoist--build-push-commands` | item_update + complete/uncomplete for existing task |
| `emacs-todoist--build-new-heading-commands` | item_add for heading + children; returns (COMMANDS . ENTRIES) |
| `emacs-todoist--push-new-heading` | Push new heading (ensures projects, async) |
| `emacs-todoist--push-update` | Push update for existing task |
| `emacs-todoist--apply-pull` | Apply remote item to heading + update hashes |
| `emacs-todoist--sync-children` | Pull cascaded changes to child headings |
| `emacs-todoist--handle-deletion` | Prompt: delete local / re-push / unlink |
| `emacs-todoist--sync-entries` | Bulk sync entry point (linked + new markers) |
| `emacs-todoist--sync-entries-1` | Continuation after project cache |
| `emacs-todoist--sync-entries-classify` | Classify linked headings: pull/push/skip/conflict/deleted |
| `emacs-todoist--sync-entries-push` | Send batch push + new commands |
| `emacs-todoist--sync-entries-writeback` | Write IDs/hashes/token after bulk push |

### Configuration (`defcustom` in `emacs-todoist.el`)

| Variable | Type | Purpose |
|----------|------|---------|
| `emacs-todoist-api-token` | string or function | Todoist API token |
| `emacs-todoist-default-project` | string or nil | Default project name or numeric ID |
| `emacs-todoist-todo-state-mapping` | alist | TODO states → checked values (default: TODO=nil, DONE=1) |
| `emacs-todoist-log-level` | symbol | Minimum log level: `debug`, `info`, `error` |
| `emacs-todoist-log-buffer-name` | string | Log buffer name (default: `"*emacs-todoist-log*"`) |

## Sync state model

All state lives in org heading properties — no external caches:

| Property | Purpose |
|----------|---------|
| `TODOIST_ID` | Real Todoist task ID |
| `TODOIST_PROJECT` | Project ID override |
| `TODOIST_LOCAL_HASH` | SHA-1 of (title, deadline, desc, state) |
| `TODOIST_REMOTE_HASH` | SHA-1 of Todoist item's sync-relevant fields |
| `TODOIST_SYNC_TOKEN` | Sync token from last successful sync |

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

### Bulk sync flow (internal)

The bulk sync commands (`sync-buffer`, `sync-subtree`, `sync-region`)
share a common internal pipeline:

```
emacs-todoist--sync-entries(linked-markers, new-markers)
  │
  ├─ if new-markers → emacs-todoist--ensure-projects (async)
  │
  └─ emacs-todoist--sync-entries-1
       │
       ├─ Determine batch token (all same → incremental, mixed → "*")
       ├─ emacs-todoist-api-sync (fetch items)
       │
       └─ emacs-todoist--sync-entries-classify
            │
            ├─ For each linked heading: classify as pull/push/skip/conflict/deleted
            ├─ Apply pulls immediately
            ├─ Collect push commands
            │
            └─ emacs-todoist--sync-entries-push
                 │
                 ├─ Filter child markers (avoid duplicate item_add)
                 ├─ Build item_add commands for new headings
                 ├─ emacs-todoist-api-sync (send all commands)
                 │
                 └─ emacs-todoist--sync-entries-writeback
                      └─ Write hashes, IDs, sync token to all affected headings
```

## Testing

```sh
make test              # All non-live tests (141 tests)
make test-org          # Only org module tests (45 tests)
make test-api          # Only API tests (37 tests, mocked HTTP)
make test-integration  # Only integration tests (39 tests)
make test-frontend     # Only frontend tests (20 tests)
make test-live         # Live API tests (9 tests, requires token)

# Filter by file and pattern:
make test FILE=test-org MATCH=description
```

### Test architecture

- **`tests/test-org.el`** (45 tests) — Unit tests for all
  `emacs-todoist-org-*` functions. Uses `with-org-buffer` helper.
- **`tests/test-api.el`** (37 tests) — Unit tests for API command
  builders, parsing, and hashing. Mocks `url-retrieve` via `cl-letf`.
- **`tests/test-integration.el`** (39 tests) — End-to-end sync
  logic. Mocks `emacs-todoist-api-sync` via `with-mock-sync`. Tests
  cover single heading sync, force push/pull, bulk sync, project
  resolution, deletion handling, parent/child cascading, logging.
- **`tests/test-frontend.el`** (20 tests) — Frontend rendering and
  incremental sync tests for `emacs-todoist-open` and
  `emacs-todoist-frontend-sync`, including project grouping and
  top-level insertion behavior.
- **`tests/test-live.el`** (9 tests) — Real API calls, excluded
  from `make test`. See below.

### Test helpers

| Helper | File | Purpose |
|--------|------|---------|
| `with-org-buffer` | test-org.el, test-integration.el | Temp org buffer with TEXT, point at first heading |
| `with-mock-sync` | test-integration.el | Mock `emacs-todoist-api-sync`, captures calls in `emacs-todoist-test--sync-calls` |
| `emacs-todoist-test--sync-response` | test-integration.el | Variable: response to return from mock sync |
| `with-live-sync` | test-live.el | Sets up token, installs sync shim, ensures cleanup |
| `emacs-todoist-test-live--sync-blocking` | test-live.el | Synchronous Sync API call via `url-retrieve-synchronously` |
| `emacs-todoist-test-live--fetch-task` | test-live.el | Full-sync fetch of a single task by ID |
| `emacs-todoist-test-live--update-task` | test-live.el | Modify a task server-side (for pull testing) |

### Live API tests

`tests/test-live.el` contains 9 tests that hit the real Todoist Sync
API v1.  They are **excluded** from the default `make test` target
(via `run-tests.el`) and must be run explicitly with `make test-live`.

**Setup**: place a valid Todoist API token in `.todoist_api_token` at
the project root (this file is gitignored).

**Codex note**: in restricted sandbox environments, `make test-live`
may fail due to blocked network and must be rerun with elevated
permissions.

**How they work**:
- `emacs-todoist-api-sync` (async via `url-retrieve`) is replaced at
  runtime by a synchronous shim that uses
  `url-retrieve-synchronously` — necessary because batch Emacs has no
  event loop for async callbacks.
- Each test creates tasks via the API, runs `emacs-todoist-sync-heading`
  (or `push-heading`/`pull-heading`), then verifies org properties and
  remote state.
- All created tasks are deleted in an `unwind-protect` cleanup, even
  if a test fails midway.

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
- **Callback buffer context (critical)**: `url-retrieve` callbacks run
  in a temporary HTTP response buffer, not your org buffer. Any org
  edit, heading lookup, or frontend hook must wrap mutations in
  `with-current-buffer` for the target org/frontend buffer first.
- **ID type coercion**: Todoist returns numeric IDs, but org
  properties store them as strings. All ID comparisons use
  `(format "%s" ...)` on both sides to coerce to strings.
- **`checked` normalization**: The API returns `checked` as `t`,
  `:json-false`, 0, 1, or nil depending on context. All code that
  inspects `checked` must handle all forms — see
  `emacs-todoist-api-hash-item` and `emacs-todoist-org-apply-remote`
  for the canonical pattern.
- **Project resolution**: Three-level cascade: heading property
  `TODOIST_PROJECT` → file keyword `#+TODOIST_PROJECT:` → global
  `emacs-todoist-default-project`. Names are resolved to numeric IDs
  via a session-level cache populated lazily from the API.
- **Child deduplication in bulk sync**: When pushing new headings in
  bulk, children whose parent is also being pushed are filtered out,
  since `emacs-todoist--build-new-heading-commands` already includes
  item_add commands for direct children.
- **Marker stability for insert-heavy flows (critical)**: Any marker
  used as a long-lived anchor in id/project maps must be created with
  insertion-type `t` (`(copy-marker POS t)`). Otherwise top-level
  insertions can leave anchors behind and cause incorrect parent/project
  placement on subsequent inserts.
- **HTTP body encoding (critical)**: `url-retrieve` request payloads
  must be unibyte. JSON containing multibyte characters can trigger
  `Multibyte text in HTTP request`. Encode sync payloads as ASCII-safe
  JSON (`\uXXXX` escapes) and convert with `string-as-unibyte` before
  calling `url-retrieve`.

## Implementation phases

- [x] Phase 0: Dev tooling (Makefile, test runner)
- [x] Phase 1: Org module (13 public functions, 45 tests)
- [x] Phase 2: API module (14 public functions, 37 tests)
- [x] Phase 3: Integration layer — sync logic, logging, 39 tests
- [x] Phase 4a: Bulk sync commands (`sync-buffer`, `sync-subtree`,
  `sync-region`) — done, 14 bulk-specific integration tests
- [x] Phase 4b: `emacs-todoist-open` frontend buffer + incremental
  `emacs-todoist-frontend-sync` (20 tests)
- [ ] Phase 5: Polish (README.org, package metadata cleanup)

## Current project snapshot (2026-03-08)

- Core non-live test suite: `141/141` passing.
- Live API suite: `9/9` passing.
- Frontend buffer is implemented and autoloaded from
  `emacs-todoist.el`.
- Recent regression classes now covered by tests:
  - async callback buffer context for frontend post-classify hooks
  - marker-anchor drift during top-level insertions
  - non-ASCII payload encoding in Sync API requests

## Phase 5: Polish

- Package headers cleanup in sub-modules
- `README.org` with usage/configuration and frontend workflow
- Address items in `SESSION.md`

## Known future work (not MVP)

- Parent/child structure change conflict resolution
- ediff for conflict resolution (currently prompts local vs remote)
- Todoist labels/priorities mapping
- Recurring task support
- `sync-dwim` command: region if active → subtree → buffer
- Non-interactive mode for `--handle-deletion` (currently uses
  `read-char-choice` which blocks in batch mode)
- Error messages surfaced to user via `message` (not just logged)
