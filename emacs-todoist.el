;;; emacs-todoist.el --- Bidirectional sync between org-mode and Todoist  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Felix

;; Author: Felix
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1"))
;; Keywords: outlines, convenience, comm
;; URL: https://github.com/felix/emacs-todoist

;;; Commentary:

;; Bidirectionally syncs org-mode TODOs with Todoist via the Sync API v1.
;; This is the integration layer that ties together the org-mode parser
;; (`emacs-todoist-org') and the API wrapper (`emacs-todoist-api') to
;; implement the actual sync logic.
;;
;; The core algorithm compares local and remote hashes to detect which side
;; changed, then pushes or pulls accordingly.  When both sides changed,
;; the user is prompted to choose.

;;; Code:

(require 'emacs-todoist-org)
(require 'emacs-todoist-api)
(require 'cl-lib)

;; ==============================================================================
;; Configuration
;; ==============================================================================

(defgroup emacs-todoist nil
  "Bidirectional Todoist sync for org-mode."
  :group 'org)

(defcustom emacs-todoist-api-token nil
  "Todoist API token.  String or function returning a string."
  :type '(choice string function)
  :group 'emacs-todoist)

(defcustom emacs-todoist-default-project nil
  "Default Todoist project for new tasks.
Accepts either a project name (e.g. \"agenda\") or a numeric project
ID string (e.g. \"2349578432\").  Names are resolved to IDs via the
project cache on first push."
  :type '(choice (const nil) string)
  :group 'emacs-todoist)

(defcustom emacs-todoist-todo-state-mapping
  '(("TODO" . nil) ("DONE" . 1))
  "Mapping from org TODO states to Todoist checked values.
nil means unchecked (active), 1 means checked (completed)."
  :type '(alist :key-type string :value-type (choice (const nil) integer))
  :group 'emacs-todoist)

(defcustom emacs-todoist-log-level 'info
  "Minimum log level for emacs-todoist messages."
  :type '(choice (const debug) (const info) (const error))
  :group 'emacs-todoist)

(defcustom emacs-todoist-log-buffer-name "*emacs-todoist-log*"
  "Name of the emacs-todoist log buffer."
  :type 'string
  :group 'emacs-todoist)

;; ==============================================================================
;; Logging
;; ==============================================================================

;; Numeric levels for comparison: debug=0, info=1, error=2.
(defconst emacs-todoist--log-level-alist
  '((debug . 0) (info . 1) (error . 2))
  "Mapping from log level symbols to numeric priority.")

(defun emacs-todoist-log (level fmt &rest args)
  "Log a message at LEVEL using format string FMT and ARGS.
Only logs when LEVEL >= `emacs-todoist-log-level'.  Messages are
timestamped and written to `emacs-todoist-log-buffer-name'."
  (let ((level-num    (alist-get level emacs-todoist--log-level-alist 1))
        (min-level-num (alist-get emacs-todoist-log-level
                                  emacs-todoist--log-level-alist 1)))
    (when (>= level-num min-level-num)
      (let ((msg (apply #'format fmt args))
            (timestamp (format-time-string "%Y-%m-%d %H:%M:%S"))
            (level-str (upcase (symbol-name level))))
        (with-current-buffer (get-buffer-create emacs-todoist-log-buffer-name)
          (goto-char (point-max))
          (insert (format "[%s] [%s] %s\n" timestamp level-str msg)))))))

;; ==============================================================================
;; Project cache
;; ==============================================================================

;; The Todoist Sync API requires numeric project IDs, but users configure
;; human-readable names.  We maintain a session-level cache of (name . id)
;; pairs, populated lazily on first push, so that names can be resolved
;; without an extra API call on every operation.

(defvar emacs-todoist--project-cache :not-fetched
  "Session-level project name → ID cache.
Set to `:not-fetched' initially; becomes an alist of (NAME . ID) after
the first fetch, where NAME is downcased for case-insensitive lookup.")

(defun emacs-todoist--project-cache-populate (projects)
  "Populate the project cache from PROJECTS, a list of API project alists.
Each entry has at least `name' and `id' keys."
  (setq emacs-todoist--project-cache
        (mapcar (lambda (proj)
                  (cons (downcase (alist-get 'name proj))
                        (format "%s" (alist-get 'id proj))))
                projects))
  (emacs-todoist-log 'debug "Project cache populated with %d entries"
                     (length emacs-todoist--project-cache)))

(defun emacs-todoist--ensure-projects (callback)
  "Ensure the project cache is populated, then call CALLBACK.
If the cache is already populated, calls CALLBACK immediately.
Otherwise fetches projects from the API first."
  (if (not (eq emacs-todoist--project-cache :not-fetched))
      (funcall callback)
    (emacs-todoist-log 'debug "Fetching project list for cache")
    (emacs-todoist-api-fetch-projects
     (lambda (response)
       (if (alist-get 'error response)
           (progn
             (emacs-todoist-log 'error "Failed to fetch projects: %s"
                                (alist-get 'error response))
             (message "emacs-todoist: failed to fetch projects"))
         (emacs-todoist--project-cache-populate
          (alist-get 'projects response))
         (funcall callback))))))

(defun emacs-todoist--resolve-project-id (project-string)
  "Resolve PROJECT-STRING to a numeric Todoist project ID.
Tries a case-insensitive name lookup in the project cache first.
If no match is found, assumes PROJECT-STRING is already a numeric ID
and returns it as-is.  Returns nil if PROJECT-STRING is nil."
  (when project-string
    (or (alist-get (downcase project-string) emacs-todoist--project-cache
                   nil nil #'equal)
        project-string)))

;; ==============================================================================
;; Sync status validation
;; ==============================================================================

(defun emacs-todoist--check-sync-status (response)
  "Check RESPONSE's `sync_status' for per-command errors.
Returns nil if all commands succeeded (every value is \"ok\"),
or if `sync_status' is absent (read-only syncs don't return it).
Returns a descriptive error string if any command failed."
  (let ((statuses (alist-get 'sync_status response))
        errors)
    (dolist (entry statuses)
      (let ((uuid (format "%s" (car entry)))
            (status (cdr entry)))
        (unless (equal status "ok")
          ;; Status may be an alist with `error' and `error_code' keys,
          ;; or a string describing the failure.
          (let ((msg (if (listp status)
                         (format "%s (code %s)"
                                 (or (alist-get 'error status) status)
                                 (alist-get 'error_code status))
                       (format "%s" status))))
            (push (format "command %s: %s" uuid msg) errors)))))
    (when errors
      (mapconcat #'identity (nreverse errors) "; "))))

;; ==============================================================================
;; TODO state ↔ Todoist checked conversion
;; ==============================================================================

(defun emacs-todoist--state-to-checked (state)
  "Convert org TODO STATE string to a Todoist `checked' value.
Returns 1 for completed states, 0 for active/nil states."
  (let ((entry (assoc state emacs-todoist-todo-state-mapping)))
    (if entry
        (or (cdr entry) 0)
      0)))

(defun emacs-todoist--checked-to-state (checked)
  "Convert Todoist CHECKED value to an org TODO state string.
CHECKED can be 0, 1, :json-false, or nil."
  (if (and checked (not (eq checked :json-false)) (not (equal checked 0)))
      "DONE"
    "TODO"))

;; ==============================================================================
;; Building a "fake" Todoist item from local heading data
;; ==============================================================================

;; When we push a new heading, we need to compute what the remote hash
;; *would* be for the data we're sending, so we can store it as
;; TODOIST_REMOTE_HASH without waiting for a round-trip fetch.

(defun emacs-todoist--heading-as-remote-item ()
  "Build a Todoist-like item alist from the heading at point.
This mirrors the structure that `emacs-todoist-api-hash-item' expects,
allowing us to compute a remote hash for data we're about to push."
  (let ((title   (emacs-todoist-org-heading-title))
        (desc    (emacs-todoist-org-heading-description))
        (due     (emacs-todoist-org-heading-deadline))
        (state   (emacs-todoist-org-heading-todo-state)))
    `((content     . ,title)
      (description . ,(or desc ""))
      (due         . ,(when due `((date . ,due))))
      (checked     . ,(emacs-todoist--state-to-checked state)))))

;; ==============================================================================
;; Command builders (extracted for reuse in bulk sync)
;; ==============================================================================

(defun emacs-todoist--build-push-commands (todoist-id)
  "Build item_update + item_complete/uncomplete commands for heading at point.
TODOIST-ID is the existing task's ID.  Returns a list of command alists
\(no API call is made)."
  (let* ((title  (emacs-todoist-org-heading-title))
         (desc   (emacs-todoist-org-heading-description))
         (due    (emacs-todoist-org-heading-deadline))
         (state  (emacs-todoist-org-heading-todo-state))
         (commands '()))
    ;; Build the item_update command with all current field values.
    (push (emacs-todoist-api-item-update
           todoist-id
           :content title
           :description (or desc "")
           :due-date due)
          commands)
    ;; Handle state changes separately: Todoist uses item_complete and
    ;; item_uncomplete rather than a field update.
    (when (equal state "DONE")
      (setq commands (append commands
                             (emacs-todoist-api-item-complete (list todoist-id)))))
    (when (or (equal state "TODO") (null state))
      (setq commands (append commands
                             (emacs-todoist-api-item-uncomplete (list todoist-id)))))
    commands))

(defun emacs-todoist--build-new-heading-commands ()
  "Build item_add commands for heading at point and its children.
Assumes the project cache is already populated.
Returns (COMMANDS . ENTRIES) where COMMANDS is a list of command alists
and ENTRIES is a list of (TEMP-ID . MARKER) pairs for writeback."
  (let* ((data   (emacs-todoist-org-heading-to-alist))
         (title  (alist-get 'title data))
         (desc   (alist-get 'description data))
         (due    (alist-get 'deadline data))
         (proj   (emacs-todoist--resolve-project-id (alist-get 'project data)))
         (parent-temp-id (emacs-todoist-api-generate-uuid))
         (commands '())
         (entries (list (cons parent-temp-id (point-marker)))))

    ;; Build the parent item_add command.
    (push (emacs-todoist-api-item-add
           title
           :description (unless (string-empty-p desc) desc)
           :due-date due
           :project-id proj
           :temp-id parent-temp-id)
          commands)

    ;; Build child item_add commands.  Each child references the parent
    ;; via the parent's temp_id, which Todoist resolves server-side.
    (dolist (child-marker (alist-get 'children data))
      (save-excursion
        (goto-char child-marker)
        (let* ((child-title (emacs-todoist-org-heading-title))
               (child-desc  (emacs-todoist-org-heading-description))
               (child-due   (emacs-todoist-org-heading-deadline))
               (child-temp  (emacs-todoist-api-generate-uuid))
               (child-cmd
                (emacs-todoist-api-item-add
                 child-title
                 :description (unless (string-empty-p child-desc) child-desc)
                 :due-date child-due
                 :parent-id parent-temp-id
                 :temp-id child-temp)))
          (push child-cmd commands)
          (push (cons child-temp child-marker) entries))))

    (cons (nreverse commands) (nreverse entries))))

;; ==============================================================================
;; Push new heading (no TODOIST_ID yet)
;; ==============================================================================

(defun emacs-todoist--push-new-heading ()
  "Push the heading at point as a new Todoist task.
Builds item_add commands for the heading and its direct children,
sends them via the Sync API, and writes back the resulting IDs and
hashes as org properties.

Fetches the project list on first use to resolve project names to IDs."
  (let ((marker (point-marker)))
    ;; Ensure the project cache is populated before we resolve names.
    (emacs-todoist--ensure-projects
     (lambda ()
       (with-current-buffer (marker-buffer marker)
         (save-excursion
           (goto-char marker)
           (emacs-todoist--push-new-heading-1)))))))

(defun emacs-todoist--push-new-heading-1 ()
  "Internal: build and send item_add commands for the heading at point.
Assumes the project cache is already populated.  Called by
`emacs-todoist--push-new-heading' after `emacs-todoist--ensure-projects'."
  (let* ((result  (emacs-todoist--build-new-heading-commands))
         (commands (car result))
         (entries  (cdr result))
         (marker   (cdar entries))  ;; first entry is the parent
         (title    (emacs-todoist-org-heading-title)))

    (emacs-todoist-log 'info "Pushing new heading: %s" title)

    ;; Send the batch to Todoist.  The callback writes properties back
    ;; onto the org headings once we have real IDs.
    (emacs-todoist-api-sync
     "*" '("items") commands
     (lambda (response)
       (cond
        ((alist-get 'error response)
         (emacs-todoist-log 'error "Sync error: %s" (alist-get 'error response))
         (message "emacs-todoist: sync error for \"%s\"" title))

        ((emacs-todoist--check-sync-status response)
         (emacs-todoist-log 'error "Push failed for %s: %s"
                            title (emacs-todoist--check-sync-status response))
         (message "emacs-todoist: push failed for \"%s\" (see log)" title))

        (t
         (emacs-todoist--write-new-heading-props entries response)
         (emacs-todoist-log 'info "Pushed new heading successfully: %s" title)
         (message "emacs-todoist: pushed new task \"%s\"" title)))))))

(defun emacs-todoist--write-new-heading-props (entries response)
  "Write IDs, hashes, and sync token to headings from a push response.
ENTRIES is a list of (TEMP-ID . MARKER) pairs.
RESPONSE is the parsed API response alist."
  (let ((sync-token (alist-get 'sync_token response))
        (id-mapping (alist-get 'temp_id_mapping response)))
    (dolist (entry entries)
      (let ((temp-id (car entry))
            (marker  (cdr entry)))
        (with-current-buffer (marker-buffer marker)
          (save-excursion
            (goto-char marker)
            (let* ((real-id (cdr (assoc temp-id id-mapping
                                        (lambda (a b)
                                          (equal (format "%s" a)
                                                 (format "%s" b)))))))
              (unless real-id
                (emacs-todoist-log 'error
                                   "No ID in temp_id_mapping for %s (mapping: %S)"
                                   (emacs-todoist-org-heading-title) id-mapping)
                (error "Push appeared to succeed but no ID was returned for \"%s\""
                       (emacs-todoist-org-heading-title)))
              (let* ((real-id-str (format "%s" real-id))
                     (local-hash  (emacs-todoist-org-heading-local-hash))
                     (remote-item (emacs-todoist--heading-as-remote-item))
                     (remote-hash (emacs-todoist-api-hash-item remote-item)))
                (emacs-todoist-org-set-props
                 `(("TODOIST_ID"          . ,real-id-str)
                   ("TODOIST_LOCAL_HASH"  . ,local-hash)
                   ("TODOIST_REMOTE_HASH" . ,remote-hash)
                   ("TODOIST_SYNC_TOKEN"  . ,sync-token)))))))))))


;; ==============================================================================
;; Push update (existing task, local changes)
;; ==============================================================================

(defun emacs-todoist--push-update (todoist-id sync-token &optional new-sync-token)
  "Push local changes for heading at point to Todoist.
TODOIST-ID is the existing task's ID.  SYNC-TOKEN is the current token.
NEW-SYNC-TOKEN, when non-nil, is a fresh token from a recent fetch
that should be stored after the push."
  (let* ((marker   (point-marker))
         (title    (emacs-todoist-org-heading-title))
         (commands (emacs-todoist--build-push-commands todoist-id)))

    (emacs-todoist-log 'info "Pushing update for: %s" title)

    (emacs-todoist-api-sync
     (or new-sync-token sync-token) '("items") commands
     (lambda (response)
       (cond
        ((alist-get 'error response)
         (emacs-todoist-log 'error "Push update error: %s"
                            (alist-get 'error response))
         (message "emacs-todoist: push update error for \"%s\"" title))

        ((emacs-todoist--check-sync-status response)
         (emacs-todoist-log 'error "Push update failed for %s: %s"
                            title (emacs-todoist--check-sync-status response))
         (message "emacs-todoist: push update failed for \"%s\" (see log)" title))

        (t
         (with-current-buffer (marker-buffer marker)
           (save-excursion
             (goto-char marker)
             (let* ((resp-token  (alist-get 'sync_token response))
                    (local-hash  (emacs-todoist-org-heading-local-hash))
                    (remote-item (emacs-todoist--heading-as-remote-item))
                    (remote-hash (emacs-todoist-api-hash-item remote-item)))
               (emacs-todoist-org-set-props
                `(("TODOIST_LOCAL_HASH"  . ,local-hash)
                  ("TODOIST_REMOTE_HASH" . ,remote-hash)
                  ("TODOIST_SYNC_TOKEN"  . ,resp-token))))))
         (emacs-todoist-log 'info "Pushed update successfully: %s" title)
         (message "emacs-todoist: pushed update for \"%s\"" title)))))))

;; ==============================================================================
;; Pull remote changes into local heading
;; ==============================================================================

(defun emacs-todoist--apply-pull (remote-item sync-token)
  "Apply REMOTE-ITEM data to the heading at point and update hashes.
SYNC-TOKEN is the new token to store."
  (let ((marker (point-marker))
        (title  (alist-get 'content remote-item)))
    (emacs-todoist-log 'info "Pulling remote changes for: %s" title)

    (save-excursion
      (goto-char marker)
      (emacs-todoist-org-apply-remote remote-item)
      ;; After applying remote data, recompute both hashes.  The local
      ;; hash now reflects the updated heading, and the remote hash
      ;; reflects the item we just applied.
      (let ((local-hash  (emacs-todoist-org-heading-local-hash))
            (remote-hash (emacs-todoist-api-hash-item remote-item)))
        (emacs-todoist-org-set-props
         `(("TODOIST_LOCAL_HASH"  . ,local-hash)
           ("TODOIST_REMOTE_HASH" . ,remote-hash)
           ("TODOIST_SYNC_TOKEN"  . ,sync-token)))))

    (emacs-todoist-log 'info "Pulled remote changes for: %s" title)
    (message "emacs-todoist: pulled remote changes for \"%s\"" title)))

;; ==============================================================================
;; Handle remote deletion
;; ==============================================================================

(defun emacs-todoist--handle-deletion ()
  "Handle a task that was deleted on Todoist.
Prompts the user with three choices:
  1. Delete the local heading
  2. Re-push as a new task (removes TODOIST_ID, calls push-new)
  3. Keep local heading and unlink (removes all TODOIST_* properties)"
  (let ((title (emacs-todoist-org-heading-title))
        (choice (read-char-choice
                 (format "Task \"%s\" deleted on Todoist. [d]elete local, [r]e-push, [k]eep & unlink? "
                         (emacs-todoist-org-heading-title))
                 '(?d ?r ?k))))
    (pcase choice
      (?d
       ;; Delete the entire org subtree.
       (org-back-to-heading t)
       (org-cut-subtree)
       (emacs-todoist-log 'info "Deleted local heading: %s" title)
       (message "emacs-todoist: deleted local heading \"%s\"" title))
      (?r
       ;; Remove the old TODOIST_ID and re-push as a brand new task.
       (dolist (prop '("TODOIST_ID" "TODOIST_LOCAL_HASH"
                       "TODOIST_REMOTE_HASH" "TODOIST_SYNC_TOKEN"))
         (org-entry-delete (point) prop))
       (emacs-todoist-log 'info "Re-pushing as new task: %s" title)
       (emacs-todoist--push-new-heading))
      (?k
       ;; Unlink: remove all Todoist properties but keep the heading.
       (dolist (prop '("TODOIST_ID" "TODOIST_LOCAL_HASH"
                       "TODOIST_REMOTE_HASH" "TODOIST_SYNC_TOKEN"))
         (org-entry-delete (point) prop))
       (emacs-todoist-log 'info "Unlinked heading: %s" title)
       (message "emacs-todoist: unlinked \"%s\" from Todoist" title)))))

;; ==============================================================================
;; Core sync logic
;; ==============================================================================

(defun emacs-todoist-sync-heading ()
  "Sync the org heading at point with Todoist.
This is the main entry point.  It detects whether the heading is new
or existing, checks for local and remote changes, and dispatches to
the appropriate push/pull/conflict handler."
  (interactive)
  (org-back-to-heading t)

  (let* ((props       (emacs-todoist-org-heading-props))
         (todoist-id  (alist-get "TODOIST_ID" props nil nil #'equal))
         (stored-local-hash  (alist-get "TODOIST_LOCAL_HASH" props nil nil #'equal))
         (stored-remote-hash (alist-get "TODOIST_REMOTE_HASH" props nil nil #'equal))
         (stored-sync-token  (alist-get "TODOIST_SYNC_TOKEN" props nil nil #'equal))
         (current-local-hash (emacs-todoist-org-heading-local-hash)))

    (if (null todoist-id)
        ;; No TODOIST_ID → this is a new heading, push it.
        (emacs-todoist--push-new-heading)

      ;; Existing task: fetch remote state, then compare hashes.
      (let ((local-changed (not (equal current-local-hash stored-local-hash)))
            (marker (point-marker))
            ;; Use stored sync token for incremental fetch, or "*" for
            ;; full sync if we don't have one yet.
            (fetch-token (or stored-sync-token "*")))

        (emacs-todoist-log 'debug "Fetching remote state for %s (token: %s)"
                           todoist-id fetch-token)

        (emacs-todoist-api-sync
         fetch-token '("items") nil
         (lambda (response)
           (if (alist-get 'error response)
               (emacs-todoist-log 'error "Fetch error: %s"
                                  (alist-get 'error response))

             (let* ((new-sync-token (alist-get 'sync_token response))
                    (items          (alist-get 'items response))
                    ;; Find this task in the returned items.
                    ;; Task IDs from org properties are strings, but the
                    ;; API returns them as numbers.  Coerce both to strings
                    ;; for comparison.
                    (remote-item
                     (cl-find-if (lambda (item)
                                   (equal (format "%s" (alist-get 'id item))
                                          todoist-id))
                                 items))
                    remote-changed)

               (with-current-buffer (marker-buffer marker)
                 (save-excursion
                   (goto-char marker)

                   (cond
                    ;; Task found in response: compute whether remote changed.
                    (remote-item
                     (let ((remote-hash (emacs-todoist-api-hash-item remote-item)))
                       (setq remote-changed
                             (not (equal remote-hash stored-remote-hash)))

                       (cond
                        ;; Neither side changed.
                        ((and (not local-changed) (not remote-changed))
                         (emacs-todoist-org-set-props
                          `(("TODOIST_SYNC_TOKEN" . ,new-sync-token)))
                         (emacs-todoist-log 'info "Already up to date: %s" todoist-id)
                         (message "emacs-todoist: already up to date"))

                        ;; Only remote changed → pull.
                        ((and (not local-changed) remote-changed)
                         (emacs-todoist--apply-pull remote-item new-sync-token))

                        ;; Only local changed → push.
                        ((and local-changed (not remote-changed))
                         (emacs-todoist--push-update
                          todoist-id stored-sync-token new-sync-token))

                        ;; Both changed → conflict.
                        (t
                         (let ((choice
                                (read-char-choice
                                 "Conflict: both local and remote changed. Use [l]ocal or [r]emote? "
                                 '(?l ?r))))
                           (pcase choice
                             (?l (emacs-todoist--push-update
                                  todoist-id stored-sync-token new-sync-token))
                             (?r (emacs-todoist--apply-pull
                                  remote-item new-sync-token))))))))

                    ;; Task not found and we did a full sync → deleted remotely.
                    ((equal fetch-token "*")
                     (emacs-todoist--handle-deletion))

                    ;; Task not found but incremental sync → task wasn't in
                    ;; the delta, meaning it's unchanged on the remote side.
                    (t
                     (if local-changed
                         (emacs-todoist--push-update
                          todoist-id stored-sync-token new-sync-token)
                       (emacs-todoist-org-set-props
                        `(("TODOIST_SYNC_TOKEN" . ,new-sync-token)))
                       (emacs-todoist-log 'info "Already up to date: %s" todoist-id)
                       (message "emacs-todoist: already up to date"))))))))))))))

;; ==============================================================================
;; Force push / force pull commands
;; ==============================================================================

(defun emacs-todoist-push-heading ()
  "Force push the heading at point to Todoist, ignoring remote state.
If the heading has no TODOIST_ID, pushes as a new task.  Otherwise,
sends an update with all current local field values."
  (interactive)
  (org-back-to-heading t)
  (let* ((props      (emacs-todoist-org-heading-props))
         (todoist-id (alist-get "TODOIST_ID" props nil nil #'equal))
         (sync-token (alist-get "TODOIST_SYNC_TOKEN" props nil nil #'equal)))
    (if (null todoist-id)
        (emacs-todoist--push-new-heading)
      (emacs-todoist--push-update todoist-id (or sync-token "*")))))

(defun emacs-todoist-pull-heading ()
  "Force pull remote data for the heading at point, ignoring local changes.
Requires the heading to have a TODOIST_ID property."
  (interactive)
  (org-back-to-heading t)
  (let* ((props      (emacs-todoist-org-heading-props))
         (todoist-id (alist-get "TODOIST_ID" props nil nil #'equal))
         (sync-token (alist-get "TODOIST_SYNC_TOKEN" props nil nil #'equal))
         (marker     (point-marker)))
    (unless todoist-id
      (user-error "No TODOIST_ID on this heading; nothing to pull"))

    (emacs-todoist-log 'info "Force pulling: %s" todoist-id)

    ;; Use "*" for a full sync to guarantee we find the item.
    (emacs-todoist-api-sync
     "*" '("items") nil
     (lambda (response)
       (if (alist-get 'error response)
           (emacs-todoist-log 'error "Pull error: %s" (alist-get 'error response))
         (let* ((new-sync-token (alist-get 'sync_token response))
                (items          (alist-get 'items response))
                (remote-item
                 (cl-find-if (lambda (item)
                               (equal (format "%s" (alist-get 'id item))
                                      todoist-id))
                             items)))
           (with-current-buffer (marker-buffer marker)
             (save-excursion
               (goto-char marker)
               (if remote-item
                   (emacs-todoist--apply-pull remote-item new-sync-token)
                 (emacs-todoist--handle-deletion))))))))))

;; ==============================================================================
;; Bulk sync core
;; ==============================================================================

(defun emacs-todoist--sync-entries (linked-markers new-markers)
  "Sync LINKED-MARKERS (existing) and NEW-MARKERS (to push) with Todoist.
LINKED-MARKERS are markers for headings that already have a TODOIST_ID.
NEW-MARKERS are markers for headings without a TODOIST_ID to push as
new tasks.  Both lists may be nil.

The flow:
1. If NEW-MARKERS non-nil, ensure the project cache is populated.
2. Fetch remote items for LINKED-MARKERS in one API call.
3. Classify each linked heading (pull/push/skip/conflict/deleted).
4. Build item_add commands for new headings.
5. Send all push commands in a single API call.
6. Write back IDs, hashes, and sync token."
  (if (and (null linked-markers) (null new-markers))
      (message "emacs-todoist: no headings to sync")
    ;; Step 1: ensure project cache if we have new headings to push.
    (let ((continue-fn
           (lambda ()
             (emacs-todoist--sync-entries-1 linked-markers new-markers))))
      (if new-markers
          (emacs-todoist--ensure-projects continue-fn)
        (funcall continue-fn)))))

(defun emacs-todoist--sync-entries-1 (linked-markers new-markers)
  "Internal continuation for `emacs-todoist--sync-entries'.
Called after project cache is ensured.  LINKED-MARKERS and NEW-MARKERS
are as in the parent function."
  (if (null linked-markers)
      ;; No linked headings — skip fetch, go straight to pushing new ones.
      (emacs-todoist--sync-entries-push nil nil new-markers nil)
    ;; Determine the batch sync token.
    (let* ((tokens
            (mapcar (lambda (m)
                      (save-excursion
                        (with-current-buffer (marker-buffer m)
                          (goto-char m)
                          (or (org-entry-get (point) "TODOIST_SYNC_TOKEN") "*"))))
                    linked-markers))
           (batch-token
            (if (cl-every (lambda (tok) (equal tok (car tokens))) tokens)
                (car tokens)
              "*")))
      (emacs-todoist-log 'debug "Bulk fetch with token: %s (%d headings)"
                         batch-token (length linked-markers))
      ;; Step 2: fetch remote items in one API call.
      (emacs-todoist-api-sync
       batch-token '("items") nil
       (lambda (response)
         (if (alist-get 'error response)
             (progn
               (emacs-todoist-log 'error "Bulk fetch error: %s"
                                  (alist-get 'error response))
               (message "emacs-todoist: bulk fetch error"))
           (emacs-todoist--sync-entries-classify
            linked-markers new-markers response batch-token)))))))

(defun emacs-todoist--sync-entries-classify
    (linked-markers new-markers response batch-token)
  "Classify linked headings and dispatch to push phase.
RESPONSE is the parsed fetch response.  BATCH-TOKEN is the token used
for the fetch (needed to detect deletions on full sync)."
  (let* ((new-sync-token (alist-get 'sync_token response))
         (items          (alist-get 'items response))
         (push-commands  '())
         (pushed-markers '())
         (pulled         0)
         (skipped        0))
    ;; Step 3: classify each linked heading.
    (dolist (marker linked-markers)
      (with-current-buffer (marker-buffer marker)
        (save-excursion
          (goto-char marker)
          (let* ((todoist-id (org-entry-get (point) "TODOIST_ID"))
                 (stored-local-hash (org-entry-get (point) "TODOIST_LOCAL_HASH"))
                 (stored-remote-hash (org-entry-get (point) "TODOIST_REMOTE_HASH"))
                 (current-local-hash (emacs-todoist-org-heading-local-hash))
                 (local-changed (not (equal current-local-hash stored-local-hash)))
                 (remote-item
                  (cl-find-if (lambda (item)
                                (equal (format "%s" (alist-get 'id item))
                                       todoist-id))
                              items)))
            (cond
             ;; Task found in response.
             (remote-item
              (let* ((remote-hash (emacs-todoist-api-hash-item remote-item))
                     (remote-changed (not (equal remote-hash stored-remote-hash))))
                (cond
                 ((and (not local-changed) (not remote-changed))
                  (emacs-todoist-org-set-props
                   `(("TODOIST_SYNC_TOKEN" . ,new-sync-token)))
                  (cl-incf skipped))
                 ((and (not local-changed) remote-changed)
                  (emacs-todoist--apply-pull remote-item new-sync-token)
                  (cl-incf pulled))
                 ((and local-changed (not remote-changed))
                  (let ((cmds (emacs-todoist--build-push-commands todoist-id)))
                    (setq push-commands (append push-commands cmds))
                    (push marker pushed-markers)))
                 (t
                  (let ((choice (read-char-choice
                                 (format "Conflict on \"%s\": [l]ocal or [r]emote? "
                                         (emacs-todoist-org-heading-title))
                                 '(?l ?r))))
                    (pcase choice
                      (?l (let ((cmds (emacs-todoist--build-push-commands todoist-id)))
                            (setq push-commands (append push-commands cmds))
                            (push marker pushed-markers)))
                      (?r (emacs-todoist--apply-pull remote-item new-sync-token)
                          (cl-incf pulled))))))))
             ;; Task not found + full sync → deleted remotely.
             ((equal batch-token "*")
              (emacs-todoist--handle-deletion))
             ;; Task not found + incremental → unchanged remotely.
             (t
              (if local-changed
                  (let ((cmds (emacs-todoist--build-push-commands todoist-id)))
                    (setq push-commands (append push-commands cmds))
                    (push marker pushed-markers))
                (emacs-todoist-org-set-props
                 `(("TODOIST_SYNC_TOKEN" . ,new-sync-token)))
                (cl-incf skipped))))))))
    ;; All headings classified — proceed to push phase.
    (emacs-todoist--sync-entries-push
     push-commands (nreverse pushed-markers)
     new-markers new-sync-token
     :pulled pulled :skipped skipped)))

(cl-defun emacs-todoist--sync-entries-push
    (push-commands pushed-markers new-markers sync-token
     &key (pulled 0) (skipped 0))
  "Send batch push and new-heading commands, then write back results.
PUSH-COMMANDS is a list of update/complete/uncomplete commands.
PUSHED-MARKERS are the markers whose hashes need updating.
NEW-MARKERS are markers for brand-new headings to push.
SYNC-TOKEN is the token to use for this push call.
PULLED and SKIPPED are counters for the summary message."
  (let ((new-entries '())
        (all-commands (copy-sequence (or push-commands '()))))
    ;; Step 4: build item_add commands for each new heading.
    ;; Filter out children whose parent is also in new-markers, since
    ;; `emacs-todoist--build-new-heading-commands' already creates
    ;; item_add commands for direct children of each heading.
    (let ((marker-positions (mapcar #'marker-position new-markers)))
      (setq new-markers
            (cl-remove-if
             (lambda (m)
               (with-current-buffer (marker-buffer m)
                 (save-excursion
                   (goto-char m)
                   (and (org-up-heading-safe)
                        (memq (point) marker-positions)))))
             new-markers)))
    (dolist (marker new-markers)
      (with-current-buffer (marker-buffer marker)
        (save-excursion
          (goto-char marker)
          (let* ((result (emacs-todoist--build-new-heading-commands))
                 (cmds   (car result))
                 (entries (cdr result)))
            (setq all-commands (append all-commands cmds))
            (setq new-entries (append new-entries entries))))))
    (if (null all-commands)
        ;; Nothing to push — report summary.
        (progn
          (emacs-todoist-log 'info "Bulk sync: pulled %d, skipped %d, pushed 0"
                             pulled skipped)
          (message "emacs-todoist: synced (pulled %d, pushed 0, skipped %d)"
                   pulled skipped))
      ;; Step 5: send all commands in one API call.
      (emacs-todoist-api-sync
       (or sync-token "*") '("items") all-commands
       (lambda (response)
         (cond
          ((alist-get 'error response)
           (emacs-todoist-log 'error "Bulk push error: %s"
                              (alist-get 'error response))
           (message "emacs-todoist: bulk push error"))
          ((emacs-todoist--check-sync-status response)
           (emacs-todoist-log 'error "Bulk push failed: %s"
                              (emacs-todoist--check-sync-status response))
           (message "emacs-todoist: bulk push failed (see log)"))
          (t
           (emacs-todoist--sync-entries-writeback
            pushed-markers new-entries new-markers response
            :pulled pulled :skipped skipped))))))))
(cl-defun emacs-todoist--sync-entries-writeback
    (pushed-markers new-entries new-markers response
     &key (pulled 0) (skipped 0))
  "Write back hashes and IDs after a successful bulk push.
PUSHED-MARKERS are markers for updated headings (need hash refresh).
NEW-ENTRIES is a list of (TEMP-ID . MARKER) for new headings.
NEW-MARKERS is the original list of new heading markers (for counting).
RESPONSE is the parsed API response."
  (let ((resp-token (alist-get 'sync_token response))
        (pushed-count 0))
    ;; Write hashes for pushed (updated) headings.
    (dolist (marker pushed-markers)
      (with-current-buffer (marker-buffer marker)
        (save-excursion
          (goto-char marker)
          (let* ((local-hash  (emacs-todoist-org-heading-local-hash))
                 (remote-item (emacs-todoist--heading-as-remote-item))
                 (remote-hash (emacs-todoist-api-hash-item remote-item)))
            (emacs-todoist-org-set-props
             `(("TODOIST_LOCAL_HASH"  . ,local-hash)
               ("TODOIST_REMOTE_HASH" . ,remote-hash)
               ("TODOIST_SYNC_TOKEN"  . ,resp-token)))
            (cl-incf pushed-count)))))
    ;; Write IDs + hashes for new headings.
    (when new-entries
      (emacs-todoist--write-new-heading-props new-entries response)
      (cl-incf pushed-count (length new-markers)))
    (emacs-todoist-log 'info "Bulk sync: pulled %d, pushed %d, skipped %d"
                       pulled pushed-count skipped)
    (message "emacs-todoist: synced (pulled %d, pushed %d, skipped %d)"
             pulled pushed-count skipped)))

;; ==============================================================================
;; User-facing bulk sync commands
;; ==============================================================================

(defun emacs-todoist-sync-buffer (&optional include-new)
  "Sync all Todoist-linked headings in the current buffer.
With a prefix argument (\\[universal-argument]), also push new TODO
headings (those without a TODOIST_ID) as new Todoist tasks."
  (interactive "P")
  (let ((linked (emacs-todoist-org-synced-entries))
        (new    (when include-new
                  ;; New = TODO headings without TODOIST_ID.
                  (cl-remove-if
                   (lambda (m)
                     (with-current-buffer (marker-buffer m)
                       (save-excursion
                         (goto-char m)
                         (org-entry-get (point) "TODOIST_ID"))))
                   (emacs-todoist-org-todo-entries)))))
    (emacs-todoist--sync-entries linked new)))

(defun emacs-todoist-sync-subtree (&optional include-new)
  "Sync all Todoist-linked headings in the subtree at point.
With a prefix argument (\\[universal-argument]), also push new TODO
headings as new Todoist tasks."
  (interactive "P")
  (org-back-to-heading t)
  (let ((linked (emacs-todoist-org-synced-entries-in-subtree))
        (new    (when include-new
                  (cl-remove-if
                   (lambda (m)
                     (with-current-buffer (marker-buffer m)
                       (save-excursion
                         (goto-char m)
                         (org-entry-get (point) "TODOIST_ID"))))
                   (emacs-todoist-org-todo-entries-in-subtree)))))
    (emacs-todoist--sync-entries linked new)))

(defun emacs-todoist-sync-region (&optional include-new)
  "Sync all Todoist-linked headings in the active region.
With a prefix argument (\\[universal-argument]), also push new TODO
headings as new Todoist tasks."
  (interactive "P")
  (unless (use-region-p)
    (user-error "No active region"))
  (let* ((beg (region-beginning))
         (end (region-end))
         (linked (emacs-todoist-org-synced-entries-in-region beg end))
         (new    (when include-new
                   (cl-remove-if
                    (lambda (m)
                      (with-current-buffer (marker-buffer m)
                        (save-excursion
                          (goto-char m)
                          (org-entry-get (point) "TODOIST_ID"))))
                    (emacs-todoist-org-todo-entries-in-region beg end)))))
    (emacs-todoist--sync-entries linked new)))

(provide 'emacs-todoist)
;;; emacs-todoist.el ends here
