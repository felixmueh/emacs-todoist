# emacs-todoist

Two-way sync between Org mode TODO headings and Todoist, using the
Todoist Sync API v1.

A heading that is linked to a Todoist task keeps its sync state in its
property drawer. Edits on either side are detected by comparing hashes,
and when both sides changed you choose which version to keep.

emacs-todoist replaces my earlier package
[todoist-sync](https://github.com/felixmueh/todoist-sync), which uses
the deprecated Sync API v9.

## Features

- Sync a single heading, a subtree, a region or a whole buffer.
- Push new TODO headings as new tasks. Child headings become subtasks.
- Pull remote changes into the heading: title, description, due date,
  recurrence and completion state.
- Conflict detection when both the heading and the task changed since
  the last sync.
- Recurring tasks: completing a recurring task in Org closes the current
  occurrence and Todoist schedules the next one.
- Project selection per heading, per subtree, per file or globally,
  by project name or numeric ID.
- A file-backed frontend buffer that renders all active tasks grouped
  by project, with incremental refresh and an agenda view.
- An Org capture template that writes into the frontend file and pushes
  the new task right away, with optional desktop notifications.
- `emacs-todoist-mode`, a minor mode that syncs the subtree when you
  change a TODO keyword.
- A configurable action for completed headings: keep them, strip the
  Todoist properties or delete the subtree.

## Requirements

- Emacs 28.1 or newer (tested with Emacs 30)
- Org mode (the version bundled with Emacs is enough)
- A Todoist account and its API token

There are no dependencies outside Emacs. HTTP requests use the built-in
`url` library.

## Installation

The package is not on MELPA. Install it from this repository.

### straight.el / use-package

```elisp
(use-package emacs-todoist
  :straight (:host github :repo "felixmueh/emacs-todoist")
  :after org)
```

### Doom Emacs

In `packages.el`:

```elisp
(package! emacs-todoist
  :recipe (:host github :repo "felixmueh/emacs-todoist"))
```

In `config.el`:

```elisp
(use-package! emacs-todoist
  :after org)
```

`examples/sample_doom_config.el` shows a fuller Doom setup with leader key
bindings, the capture template and frontend hooks.

### Manual

Clone the repository and add it to the `load-path`:

```elisp
(add-to-list 'load-path "/path/to/emacs-todoist")
(require 'emacs-todoist)
```

## Configuration

### API token

You find the token in Todoist under Settings, Integrations, Developer.

`emacs-todoist-api-token` accepts a string or a function that returns
the token. Use a function so the token stays out of your configuration
file. With auth-source, add a line to `~/.authinfo.gpg`:

```
machine api.todoist.com password YOUR-TOKEN
```

and configure:

```elisp
(setq emacs-todoist-api-token
      (lambda ()
        (require 'auth-source)
        (auth-source-pick-first-password :host "api.todoist.com")))
```

Any other source works the same way, for example `pass` through
`auth-source-pass` or a file outside version control:

```elisp
(setq emacs-todoist-api-token
      (lambda ()
        (with-temp-buffer
          (insert-file-contents "~/.config/todoist/token")
          (string-trim (buffer-string)))))
```

Do not put the token in a file that you commit.

### Options

| Variable | Default | Purpose |
|----------|---------|---------|
| `emacs-todoist-api-token` | `nil` | Token string or function returning it |
| `emacs-todoist-default-project` | `nil` | Project for new tasks (name or ID). `nil` uses the Todoist Inbox |
| `emacs-todoist-todo-state-mapping` | TODO open, DONE completed | Org TODO states and their Todoist completion state |
| `emacs-todoist-auto-sync-on-todo-change` | `t` | In `emacs-todoist-mode`, sync the subtree after a TODO keyword change |
| `emacs-todoist-on-done-action` | `nil` | After syncing a DONE heading: `nil`, `delete-properties`, `delete-heading` or a function taking a marker |
| `emacs-todoist-frontend-on-done-action` | `delete-heading` | The same, for the frontend buffer |
| `emacs-todoist-frontend-file-name` | `"todoist.org"` | Frontend file, created in `org-directory` |
| `emacs-todoist-frontend-sync-on-save` | `nil` | Sync when the frontend file is saved |
| `emacs-todoist-frontend-project-order-function` | Inbox first, then alphabetical | Order of projects in the frontend |
| `emacs-todoist-org-capture-template-key` | `"T"` | Key of the capture template |
| `emacs-todoist-org-capture-project` | `nil` | Project for captured tasks |
| `emacs-todoist-org-capture-notify-send` | `t` | Report capture push results with `notify-send` |
| `emacs-todoist-log-level` | `info` | Log level for the `*emacs-todoist-log*` buffer |

Hooks: `emacs-todoist-frontend-after-creation-hook` runs after the
frontend has been rendered, `emacs-todoist-frontend-agenda-hook` runs
in the agenda buffer opened by `emacs-todoist-frontend-agenda`.

### Projects

The project of a new task is taken from the first of:

1. the heading's `TODOIST_PROJECT` property
2. the nearest ancestor's `TODOIST_PROJECT` property
3. a `#+TODOIST_PROJECT:` keyword in the file
4. `emacs-todoist-default-project`

Project names are resolved to IDs once per session and matched without
regard to case.

### Example

```elisp
(use-package emacs-todoist
  :after org
  :hook (org-mode . emacs-todoist-mode)
  :custom
  (emacs-todoist-default-project "Inbox")
  (emacs-todoist-api-token
   (lambda ()
     (require 'auth-source)
     (auth-source-pick-first-password :host "api.todoist.com")))
  :config
  (require 'emacs-todoist-org-capture)
  (emacs-todoist-org-capture-install-template t))
```

## Commands

Sync commands work on the heading at point or on a set of headings.
The bulk commands sync headings that are already linked. With a prefix
argument (`C-u`) they also push TODO headings that are not linked yet.

| Command | Purpose |
|---------|---------|
| `emacs-todoist-sync-single-heading` | Sync the heading at point, without its children |
| `emacs-todoist-sync-subtree` | Sync the linked headings in the subtree |
| `emacs-todoist-sync-region` | Sync the linked headings in the region |
| `emacs-todoist-sync-buffer` | Sync the linked headings in the buffer |
| `emacs-todoist-push-heading` | Push the heading and overwrite the remote task |
| `emacs-todoist-pull-heading` | Pull the remote task and overwrite the heading |
| `emacs-todoist-set-project` | Set or clear `TODOIST_PROJECT` on the heading |
| `emacs-todoist-set-recurrence` | Set or clear the recurrence (`TODOIST_DUE_STRING`, e.g. `every monday`) |
| `emacs-todoist-open` | Open the frontend buffer and sync it |
| `emacs-todoist-open-recreate` | Render the frontend buffer again from scratch |
| `emacs-todoist-frontend-sync` | Refresh the frontend buffer |
| `emacs-todoist-frontend-agenda` | Refresh the frontend, then open an agenda for its tasks |
| `emacs-todoist-view-canonical-heading` | Show the original heading of the frontend task at point |
| `emacs-todoist-org-capture` | Capture a new task with the Todoist template |
| `emacs-todoist-org-capture-install-template` | Add the Todoist template to `org-capture-templates` |

The package defines no key bindings.

## How the sync works

A linked heading carries these properties:

| Property | Content |
|----------|---------|
| `TODOIST_ID` | ID of the Todoist task |
| `TODOIST_LOCAL_HASH` | Hash of title, deadline, due string, body and TODO state at the last sync |
| `TODOIST_REMOTE_HASH` | Hash of the task's content, description, due date and completion state at the last sync |
| `TODOIST_SYNC_TOKEN` | Sync token of the last sync |

On sync the package fetches the tasks, incrementally from the stored
sync token when possible, and compares both hashes with their stored
values:

- only the heading changed: the heading is pushed
- only the task changed: the task is pulled into the heading
- both changed: you are asked to keep the local or the remote version
- neither changed: nothing happens

Title maps to the task content, the body to the description,
`DEADLINE` to the due date and `TODOIST_DUE_STRING` to the due string.
A task that is missing from a full fetch is treated as completed in
Todoist. The heading is marked DONE and the configured done action runs.

New headings with children are pushed in one request. The children
reference the parent through a temporary ID and become subtasks.

The frontend file (`todoist.org` in `org-directory`) is generated from
Todoist. The package keeps a small cache of heading locations in
`emacs-todoist-find-heading-cache.el` in your Emacs directory, which
`emacs-todoist-view-canonical-heading` uses to find a task's original
heading.

## Running the tests

```sh
make test              # all offline tests
make test-org          # one test file
make test FILE=test-org MATCH=description
make compile           # byte-compile the package
```

The offline tests mock all HTTP calls. `tests/test-live.el` runs
against the real Todoist API, creates tasks in your account and deletes
them again. It is not part of `make test`. Run it with `make test-live`
and a token in `.todoist_api_token` at the repository root (the file is
git-ignored).

## Status and limitations

The package works well for my own use. It has not been tested by
other users yet.

- Only TODO and DONE are mapped by default. Other keywords need an entry
  in `emacs-todoist-todo-state-mapping`.
- Priorities, tags/labels, `SCHEDULED`, comments and task order are not
  synced.
- The project is set when a task is created. Moving an existing task to
  another project, or a heading to another parent, is not synced.
- A conflict offers local or remote, there is no merge.
- Deletions are only noticed during a full fetch, and they are treated
  as completions.

emacs-todoist was developed with the help of AI coding agents (Claude
Code and Codex).

## License

GPL-3.0-or-later. See `LICENSE`.
