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
;;
;; Interactive commands:
;;   `emacs-todoist-sync-subtree'  — Smart sync for the current subtree
;;   `emacs-todoist-sync-single-heading' — Smart sync for one heading only
;;   `emacs-todoist-push-heading'  — Force push (ignore remote)
;;   `emacs-todoist-pull-heading'  — Force pull (ignore local)
;;   `emacs-todoist-sync-buffer'   — Bulk sync all linked headings (C-u: +new)
;;   `emacs-todoist-sync-subtree'  — Bulk sync subtree (C-u: +new)
;;   `emacs-todoist-sync-region'   — Bulk sync region (C-u: +new)
;;
;; All sync state is stored in org heading properties (TODOIST_ID,
;; TODOIST_LOCAL_HASH, TODOIST_REMOTE_HASH, TODOIST_SYNC_TOKEN).
;; No external state files or databases.
;;
;; Code organization (in order of appearance):
;;   1. Configuration (defcustom)
;;   2. Logging
;;   3. Project cache (name → ID resolution)
;;   4. Sync status validation
;;   5. TODO state ↔ checked conversion
;;   6. Building fake remote items (for hash computation)
;;   7. Command builders (push commands, new heading commands)
;;   8. Push new heading (single heading, async)
;;   9. Push update (existing task, async)
;;  10. Pull remote changes
;;  11. Handle remote deletion
;;  12. User-facing smart sync commands
;;  13. Force push / force pull
;;  14. Bulk sync core (classify → push → writeback pipeline)
;;  15. User-facing bulk sync commands

;;; Code:

(require 'emacs-todoist-org)
(require 'emacs-todoist-api)
(require 'cl-lib)

;;;###autoload
(autoload 'emacs-todoist-open "emacs-todoist-frontend" nil t)

;;;###autoload
(autoload 'emacs-todoist-frontend-agenda "emacs-todoist-frontend" nil t)

(autoload 'emacs-todoist-org-capture-install-template
  "emacs-todoist-org-capture" nil t)

(autoload 'emacs-todoist-org-capture
  "emacs-todoist-org-capture" nil t)

(defvar emacs-todoist-mode nil
  "Non-nil when `emacs-todoist-mode' is enabled in the current buffer.")

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
  :type '(choice (const debug) (const info) (const warn) (const error))
  :group 'emacs-todoist)

(defcustom emacs-todoist-log-buffer-name "*emacs-todoist-log*"
  "Name of the emacs-todoist log buffer."
  :type 'string
  :group 'emacs-todoist)

(defcustom emacs-todoist-on-done-action nil
  "Action to run after a successful sync when a heading is DONE.
Supported values:
- nil               : keep heading as-is.
- `delete-properties': remove all TODOIST_* properties.
- `delete-heading'  : delete the heading subtree.
- function          : called with one marker argument pointing at heading."
  :type '(choice
          (const :tag "Keep heading" nil)
          (const :tag "Delete Todoist properties" delete-properties)
          (const :tag "Delete heading" delete-heading)
          (function :tag "Custom function"))
  :group 'emacs-todoist)

(defcustom emacs-todoist-frontend-on-done-action 'delete-heading
  "Buffer-local DONE action override used in frontend Todoist buffers.
When this variable is buffer-local, it overrides
`emacs-todoist-on-done-action' for that buffer."
  :type '(choice
          (const :tag "Keep heading" nil)
          (const :tag "Delete Todoist properties" delete-properties)
          (const :tag "Delete heading" delete-heading)
          (function :tag "Custom function"))
  :group 'emacs-todoist)

(defcustom emacs-todoist-auto-sync-on-todo-change t
  "When non-nil, `emacs-todoist-mode' auto-syncs the current subtree on TODO changes."
  :type 'boolean
  :group 'emacs-todoist)

(defcustom emacs-todoist-frontend-sync-on-save nil
  "When non-nil, saving the frontend Todoist buffer triggers a sync."
  :type 'boolean
  :group 'emacs-todoist)

;; ==============================================================================
;; Logging
;; ==============================================================================

;; Numeric levels for comparison: debug=0, info=1, warn=2, error=3.
(defconst emacs-todoist--log-level-alist
  '((debug . 0) (info . 1) (warn . 2) (error . 3))
  "Mapping from log level symbols to numeric priority.")

(defconst emacs-todoist--sync-state-property-keys
  '("TODOIST_ID" "TODOIST_LOCAL_HASH" "TODOIST_REMOTE_HASH" "TODOIST_SYNC_TOKEN")
  "Todoist sync-state properties written by successful sync operations.")

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

(defun emacs-todoist--effective-on-done-action ()
  "Return the active DONE action for current buffer."
  (if (local-variable-p 'emacs-todoist-frontend-on-done-action (current-buffer))
      emacs-todoist-frontend-on-done-action
    emacs-todoist-on-done-action))

(defun emacs-todoist--delete-heading-properties (properties)
  "Delete each property in PROPERTIES from the heading at point."
  (dolist (prop properties)
    (org-entry-delete (point) prop)))

(defun emacs-todoist--delete-sync-state-properties ()
  "Delete emacs-todoist sync-state properties from the heading at point."
  (emacs-todoist--delete-heading-properties
   emacs-todoist--sync-state-property-keys))

(defun emacs-todoist--delete-todoist-properties ()
  "Delete all TODOIST_* properties from the heading at point."
  (emacs-todoist--delete-heading-properties
   (mapcar #'car (emacs-todoist-org-heading-props))))

(defun emacs-todoist--run-on-done-action (marker)
  "Run configured DONE action for MARKER if that heading is DONE."
  (when (and (markerp marker) (marker-buffer marker))
    (with-current-buffer (marker-buffer marker)
      (save-excursion
        (goto-char marker)
        (when (equal (org-get-todo-state) "DONE")
          (let ((action (emacs-todoist--effective-on-done-action)))
            (pcase action
              ('delete-properties
               (emacs-todoist--delete-todoist-properties))
              ('delete-heading
               (org-back-to-heading t)
               (org-cut-subtree))
              ((pred functionp)
               (funcall action (copy-marker (point) t)))
              (_ nil))))))))

(defun emacs-todoist--auto-sync-todo-state-change ()
  "Auto-sync the current subtree after TODO state changes."
  (when (and emacs-todoist-mode
             emacs-todoist-auto-sync-on-todo-change
             (org-get-todo-state))
    (emacs-todoist-sync-subtree)))

(define-minor-mode emacs-todoist-mode
  "Minor mode for automatic emacs-todoist behavior in Org buffers.
When enabled, TODO keyword changes trigger `emacs-todoist-sync-subtree'
for the current subtree when `emacs-todoist-auto-sync-on-todo-change'
is non-nil.  Use `emacs-todoist-sync-single-heading' for explicit
heading-only syncs."
  :lighter " ETodoist"
  (if emacs-todoist-mode
      (add-hook 'org-after-todo-state-change-hook
                #'emacs-todoist--auto-sync-todo-state-change nil t)
    (remove-hook 'org-after-todo-state-change-hook
                 #'emacs-todoist--auto-sync-todo-state-change t)))

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
    (or (and (listp emacs-todoist--project-cache)
             (alist-get (downcase project-string) emacs-todoist--project-cache
                        nil nil #'equal))
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
        (due-date (emacs-todoist-org-heading-deadline))
        (due-string (emacs-todoist-org-heading-due-string))
        (state   (emacs-todoist-org-heading-todo-state)))
    `((content     . ,title)
      (description . ,(or desc ""))
      (due         . ,(when (or due-date due-string)
                        (let ((due-obj '()))
                          (when due-date
                            (push `(date . ,due-date) due-obj))
                          (when due-string
                            (push `(string . ,due-string) due-obj)
                            (push '(is_recurring . t) due-obj))
                          (nreverse due-obj))))
      (checked     . ,(emacs-todoist--state-to-checked state)))))

(defun emacs-todoist--find-item-by-id (items todoist-id)
  "Return item from ITEMS matching TODOIST-ID, or nil.
Coerces both numeric API IDs and string Org property values to strings."
  (cl-find-if (lambda (item)
                (equal (emacs-todoist--item-id item)
                       (format "%s" todoist-id)))
              items))

(defun emacs-todoist--log-conflict-debug (scope todoist-id remote-item
                                                current-local-hash
                                                stored-local-hash
                                                remote-hash
                                                stored-remote-hash)
  "Log detailed conflict info for SCOPE and TODOIST-ID.
REMOTE-ITEM is the fetched Todoist item.  Hash arguments are the current
and stored values used by conflict detection."
  (let* ((local-title-raw (emacs-todoist-org-heading-title))
         (local-desc-raw (emacs-todoist-org-heading-description))
         (local-deadline-raw (emacs-todoist-org-heading-deadline))
         (local-due-string-raw (emacs-todoist-org-heading-due-string))
         (local-state-raw (emacs-todoist-org-heading-todo-state))
         (remote-title-raw (alist-get 'content remote-item))
         (remote-desc-raw (alist-get 'description remote-item))
         (remote-due (alist-get 'due remote-item))
         (remote-deadline (when-let* ((date (alist-get 'date remote-due)))
                            (format "%s" date)))
         (remote-due-string (when-let* ((due-string
                                         (alist-get 'string remote-due)))
                              (format "%s" due-string)))
         (remote-state (emacs-todoist--checked-to-state
                        (alist-get 'checked remote-item)))
         (local-title (if (stringp local-title-raw)
                          (substring-no-properties local-title-raw)
                        local-title-raw))
         (local-desc (if (stringp local-desc-raw)
                         (substring-no-properties local-desc-raw)
                       local-desc-raw))
         (local-deadline (if (stringp local-deadline-raw)
                             (substring-no-properties local-deadline-raw)
                           local-deadline-raw))
         (local-due-string (if (stringp local-due-string-raw)
                               (substring-no-properties local-due-string-raw)
                             local-due-string-raw))
         (local-state (if (stringp local-state-raw)
                          (substring-no-properties local-state-raw)
                        local-state-raw))
         (remote-title (if (stringp remote-title-raw)
                           (substring-no-properties remote-title-raw)
                         remote-title-raw))
         (remote-desc (if (stringp remote-desc-raw)
                          (substring-no-properties remote-desc-raw)
                        remote-desc-raw)))
    (emacs-todoist-log
     'debug "Conflict detected (%s) for TODOIST_ID=%s" scope todoist-id)
    (emacs-todoist-log
     'debug "  title: local=%S remote=%S" local-title remote-title)
    (emacs-todoist-log
     'debug "  description: local=%S remote=%S" local-desc remote-desc)
    (emacs-todoist-log
     'debug "  deadline: local=%S remote=%S" local-deadline remote-deadline)
    (emacs-todoist-log
     'debug "  recurrence: local=%S remote=%S" local-due-string remote-due-string)
    (emacs-todoist-log
     'debug "  state: local=%S remote=%S" local-state remote-state)
    (emacs-todoist-log
     'debug "  hashes: local(current=%s stored=%s) remote(current=%s stored=%s)"
     current-local-hash stored-local-hash remote-hash stored-remote-hash)))

;; ==============================================================================
;; Item upsert helpers (shared by sync + frontend)
;; ==============================================================================

(defun emacs-todoist--item-id (item)
  "Return ITEM's `id' as a string, or nil."
  (when-let* ((id (alist-get 'id item)))
    (format "%s" id)))

(defun emacs-todoist--item-parent-id (item)
  "Return ITEM's `parent_id' as a string, or nil for top-level items."
  (let ((parent-id (alist-get 'parent_id item)))
    (unless (or (null parent-id) (eq parent-id :json-false))
      (format "%s" parent-id))))

(defun emacs-todoist--item-project-id (item)
  "Return ITEM's `project_id' as a string, or nil."
  (when-let* ((project-id (alist-get 'project_id item)))
    (format "%s" project-id)))

(defun emacs-todoist--item-completed-p (item)
  "Return non-nil when ITEM is completed (`checked')."
  (equal "DONE" (emacs-todoist--checked-to-state (alist-get 'checked item))))

(defun emacs-todoist--unsynced-todo-markers (markers)
  "Return TODO MARKERS that do not yet have a TODOIST_ID."
  (cl-remove-if
   (lambda (marker)
     (with-current-buffer (marker-buffer marker)
       (save-excursion
         (goto-char marker)
         (org-entry-get (point) "TODOIST_ID"))))
   markers))

(defun emacs-todoist--build-id-map-from-markers (markers)
  "Build hash table mapping TODOIST_ID strings to MARKERS."
  (let ((id-map (make-hash-table :test #'equal)))
    (dolist (marker markers id-map)
      (when (and (markerp marker) (marker-buffer marker))
        (with-current-buffer (marker-buffer marker)
          (save-excursion
            (goto-char marker)
            (when-let* ((item-id (org-entry-get (point) "TODOIST_ID")))
              (puthash item-id (copy-marker (point) t) id-map))))))))

(defun emacs-todoist--build-id-map ()
  "Build TODOIST_ID → marker map for the current buffer."
  (emacs-todoist--build-id-map-from-markers
   (emacs-todoist-org-synced-entries)))

(defun emacs-todoist--topological-sort-items (items)
  "Return ITEMS sorted so parents precede children."
  (let ((id-set (make-hash-table :test #'equal))
        (children-by-parent (make-hash-table :test #'equal))
        (roots '())
        (queue '())
        (seen (make-hash-table :test #'equal))
        (sorted '()))
    (dolist (item items)
      (when-let* ((item-id (emacs-todoist--item-id item)))
        (puthash item-id t id-set)))
    (dolist (item items)
      (let ((parent-id (emacs-todoist--item-parent-id item)))
        (if (or (null parent-id) (not (gethash parent-id id-set)))
            (push item roots)
          (puthash parent-id
                   (append (gethash parent-id children-by-parent)
                           (list item))
                   children-by-parent))))
    (setq queue (nreverse roots))
    (while queue
      (let* ((item (pop queue))
             (item-id (emacs-todoist--item-id item)))
        (unless (and item-id (gethash item-id seen))
          (when item-id
            (puthash item-id t seen))
          (push item sorted)
          (when item-id
            (setq queue (append queue
                                (copy-sequence
                                 (or (gethash item-id children-by-parent)
                                     '()))))))))
    ;; Keep cycle/orphan edge cases deterministic by appending unseen items.
    (dolist (item items)
      (when-let* ((item-id (emacs-todoist--item-id item)))
        (unless (gethash item-id seen)
          (push item sorted))))
    (nreverse sorted)))

(defun emacs-todoist--insert-child-heading (parent-marker)
  "Insert an empty child heading under PARENT-MARKER.
Returns a marker at the newly inserted heading."
  (let (child-marker)
    (with-current-buffer (marker-buffer parent-marker)
      (save-excursion
        (goto-char parent-marker)
        (org-back-to-heading t)
        (let ((child-level (1+ (org-current-level))))
          (org-end-of-subtree t t)
          (unless (bolp)
            (insert "\n"))
          (let ((start (point)))
            (insert (make-string child-level ?*) " \n")
            (goto-char start)
            (setq child-marker (point-marker))
            (set-marker-insertion-type child-marker t)))))
    child-marker))

(defun emacs-todoist--upsert-item-at-point (item sync-token)
  "Apply ITEM to heading at point and write sync properties.
SYNC-TOKEN is written when non-nil."
  (let* ((item-id (emacs-todoist--item-id item))
         (project-id (emacs-todoist--item-project-id item))
         (pre-props (list (cons "TODOIST_ID" item-id))))
    (when project-id
      (push (cons "TODOIST_PROJECT" project-id) pre-props))
    (when sync-token
      (push (cons "TODOIST_SYNC_TOKEN" sync-token) pre-props))
    ;; Write ID before applying remote fields to keep local hash stable.
    (emacs-todoist-org-set-props (nreverse pre-props))
    (emacs-todoist-org-apply-remote item)
    (let ((post-props
           `(("TODOIST_LOCAL_HASH"  . ,(emacs-todoist-org-heading-local-hash))
             ("TODOIST_REMOTE_HASH" . ,(emacs-todoist-api-hash-item item)))))
      (when sync-token
        (push (cons "TODOIST_SYNC_TOKEN" sync-token) post-props))
      (emacs-todoist-org-set-props (nreverse post-props)))))

(defun emacs-todoist--apply-items (items sync-token id-map)
  "Upsert ITEMS into the current org hierarchy using ID-MAP.
Updates existing headings in place and inserts new headings when their
parent exists in ID-MAP.  Returns the number of inserted headings."
  (let ((inserted 0))
    (dolist (item items inserted)
      (when-let* ((item-id (emacs-todoist--item-id item)))
        (let ((marker (gethash item-id id-map)))
          (cond
           ;; Existing heading: update in place.
           ((and (markerp marker) (marker-buffer marker))
            (with-current-buffer (marker-buffer marker)
              (save-excursion
                (goto-char marker)
                (emacs-todoist--upsert-item-at-point item sync-token))))
           ;; Missing heading: insert as child when parent exists.
           (t
            (unless (emacs-todoist--item-completed-p item)
              (when-let* ((parent-id (emacs-todoist--item-parent-id item))
                          (parent-marker (gethash parent-id id-map))
                          (_ (and (markerp parent-marker)
                                  (marker-buffer parent-marker))))
                (let ((new-marker (emacs-todoist--insert-child-heading
                                   parent-marker)))
                  (with-current-buffer (marker-buffer new-marker)
                    (save-excursion
                      (goto-char new-marker)
                      (emacs-todoist--upsert-item-at-point item sync-token)))
                  (puthash item-id new-marker id-map)
                  (cl-incf inserted)))))))))))

(defun emacs-todoist--apply-top-level-items (items sync-token id-map project-fn)
  "Insert top-level (or orphan) ITEMS using PROJECT-FN for placement.
PROJECT-FN receives an item and should return a marker/position inside
the parent project container subtree.  Returns inserted heading count."
  (let ((inserted 0))
    (dolist (item items inserted)
      (when-let* ((item-id (emacs-todoist--item-id item)))
        (let ((existing (gethash item-id id-map)))
          (unless (and (markerp existing) (marker-buffer existing))
          (let ((parent-id (emacs-todoist--item-parent-id item)))
            (when (and (not (emacs-todoist--item-completed-p item))
                       (or (null parent-id) (not (gethash parent-id id-map))))
              (let* ((anchor (funcall project-fn item))
                     (project-marker
                      (cond
                       ((and (markerp anchor) (marker-buffer anchor)) anchor)
                       ((integerp anchor)
                        (save-excursion
                          (goto-char anchor)
                          (org-back-to-heading t)
                          (copy-marker (point) t)))
                       (t nil))))
                (when (and project-marker (marker-buffer project-marker))
                  (let ((new-marker (emacs-todoist--insert-child-heading
                                     project-marker)))
                    (with-current-buffer (marker-buffer new-marker)
                      (save-excursion
                        (goto-char new-marker)
                        (emacs-todoist--upsert-item-at-point item sync-token)))
                    (puthash item-id new-marker id-map)
                      (cl-incf inserted))))))))))))

;; ==============================================================================
;; Command builders (extracted for reuse in bulk sync)
;; ==============================================================================

(defun emacs-todoist--build-push-commands (todoist-id)
  "Build item_update + item_close/uncomplete commands for heading at point.
TODOIST-ID is the existing task's ID.  Returns a list of command alists
\(no API call is made)."
  (let* ((title  (emacs-todoist-org-heading-title))
         (desc   (emacs-todoist-org-heading-description))
         (due-date (emacs-todoist-org-heading-deadline))
         (due-string (emacs-todoist-org-heading-due-string))
         (state  (emacs-todoist-org-heading-todo-state))
         (update-args (list :content title
                            :description (or desc "")))
         (commands '()))
    ;; `DONE' completion must avoid a due.date-only update, which can
    ;; strip recurring metadata on Todoist.  Use due.string whenever
    ;; recurrence is known.
    (cond
     ((equal state "DONE")
      (when due-string
        (setq update-args (append update-args
                                  (list :due-string due-string)))
        (when due-date
          (setq update-args (append update-args
                                    (list :due-date due-date))))))
     (due-string
      (setq update-args (append update-args
                                (list :due-string due-string)))
      (when due-date
        (setq update-args (append update-args
                                  (list :due-date due-date)))))
     (due-date
      (setq update-args (append update-args
                                (list :due-date due-date)))))
    (push (apply #'emacs-todoist-api-item-update todoist-id update-args)
          commands)
    ;; Handle state changes separately: Todoist uses item_close and
    ;; item_uncomplete rather than a field update.
    (when (equal state "DONE")
      (setq commands (append commands
                             (emacs-todoist-api-item-close (list todoist-id)))))
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
         (due-date (alist-get 'deadline data))
         (due-string (alist-get 'due-string data))
         (proj   (emacs-todoist--resolve-project-id (alist-get 'project data)))
         (parent-temp-id (emacs-todoist-api-generate-uuid))
         (commands '())
         (entries (list (cons parent-temp-id (point-marker)))))

    ;; Build the parent item_add command.
    (push (emacs-todoist-api-item-add
           title
           :description (unless (string-empty-p desc) desc)
           :due-date due-date
           :due-string due-string
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
               (child-due-date (emacs-todoist-org-heading-deadline))
               (child-due-string (emacs-todoist-org-heading-due-string))
               (child-temp  (emacs-todoist-api-generate-uuid))
               (child-cmd
                (emacs-todoist-api-item-add
                 child-title
                 :description (unless (string-empty-p child-desc) child-desc)
                 :due-date child-due-date
                 :due-string child-due-string
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
        (id-mapping (alist-get 'temp_id_mapping response))
        (items (alist-get 'items response)))
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
                     (response-item (emacs-todoist--find-item-by-id
                                     items real-id-str))
                     (remote-item (or response-item
                                      (emacs-todoist--heading-as-remote-item)))
                     (remote-hash (emacs-todoist-api-hash-item remote-item)))
                (emacs-todoist-org-set-props
                 `(("TODOIST_ID"          . ,real-id-str)
                   ("TODOIST_LOCAL_HASH"  . ,local-hash)
                   ("TODOIST_REMOTE_HASH" . ,remote-hash)
                   ("TODOIST_SYNC_TOKEN"  . ,sync-token)))))))))))

(defun emacs-todoist--write-local-push-writeback (marker sync-token)
  "Write hash/token properties for MARKER from local heading state."
  (when (and (markerp marker) (marker-buffer marker))
    (with-current-buffer (marker-buffer marker)
      (save-excursion
        (goto-char marker)
        (let* ((local-hash  (emacs-todoist-org-heading-local-hash))
               (remote-item (emacs-todoist--heading-as-remote-item))
               (remote-hash (emacs-todoist-api-hash-item remote-item)))
          (emacs-todoist-org-set-props
           `(("TODOIST_LOCAL_HASH"  . ,local-hash)
             ("TODOIST_REMOTE_HASH" . ,remote-hash)
             ("TODOIST_SYNC_TOKEN"  . ,sync-token)))
          (emacs-todoist--run-on-done-action marker))))))

(defun emacs-todoist--reconcile-done-push (marker todoist-id response callback)
  "Reconcile MARKER against remote state after closing TODOIST-ID.
Prefers RESPONSE items; if TODOIST-ID is missing, performs one fallback
full fetch.  CALLBACK is invoked after reconcile/writeback."
  (let* ((resp-token (alist-get 'sync_token response))
         (resp-item (emacs-todoist--find-item-by-id
                     (alist-get 'items response) todoist-id)))
    (if resp-item
        (progn
          (when (and (markerp marker) (marker-buffer marker))
            (with-current-buffer (marker-buffer marker)
              (save-excursion
                (goto-char marker)
                (emacs-todoist--apply-pull resp-item resp-token :silent t))))
          (funcall callback))
      (emacs-todoist-log
       'warn "DONE push for %s returned no item; fetching full state for reconcile"
       todoist-id)
      (emacs-todoist-api-sync
       "*" '("items") nil
       (lambda (fetch-response)
         (if (alist-get 'error fetch-response)
             (progn
               (emacs-todoist-log
                'warn "Fallback reconcile fetch failed for %s: %s"
                todoist-id (alist-get 'error fetch-response))
               (emacs-todoist--write-local-push-writeback marker resp-token))
           (let* ((fetch-token (alist-get 'sync_token fetch-response))
                  (fetched-item (emacs-todoist--find-item-by-id
                                 (alist-get 'items fetch-response)
                                 todoist-id)))
             (if fetched-item
                 (when (and (markerp marker) (marker-buffer marker))
                   (with-current-buffer (marker-buffer marker)
                     (save-excursion
                       (goto-char marker)
                       (emacs-todoist--apply-pull
                        fetched-item fetch-token :silent t))))
               (progn
                 (emacs-todoist-log
                  'warn "Fallback reconcile fetch missing item %s; using local writeback"
                  todoist-id)
                 (emacs-todoist--write-local-push-writeback marker fetch-token)))))
         (funcall callback))))))


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
         (state-at-push (emacs-todoist-org-heading-todo-state))
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
         (let ((resp-token (alist-get 'sync_token response)))
           (if (equal state-at-push "DONE")
               (emacs-todoist--reconcile-done-push
                marker todoist-id response
                (lambda ()
                  (emacs-todoist-log 'info "Pushed update successfully: %s" title)
                  (message "emacs-todoist: pushed update for \"%s\"" title)))
             (progn
               (emacs-todoist--write-local-push-writeback marker resp-token)
               (emacs-todoist-log 'info "Pushed update successfully: %s" title)
               (message "emacs-todoist: pushed update for \"%s\"" title))))))))))

;; ==============================================================================
;; Pull remote changes into local heading
;; ==============================================================================

(cl-defun emacs-todoist--apply-pull (remote-item sync-token &key silent)
  "Apply REMOTE-ITEM data to the heading at point and update hashes.
SYNC-TOKEN is the new token to store.
When SILENT is non-nil, suppress user-facing log/message chatter."
  (let ((marker (point-marker))
        (title  (alist-get 'content remote-item)))
    (unless silent
      (emacs-todoist-log 'info "Pulling remote changes for: %s" title))

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
           ("TODOIST_SYNC_TOKEN"  . ,sync-token))))
      (emacs-todoist--run-on-done-action marker))

    (unless silent
      (emacs-todoist-log 'info "Pulled remote changes for: %s" title)
      (message "emacs-todoist: pulled remote changes for \"%s\"" title))))

(defun emacs-todoist--handle-deletion (&optional sync-token)
  "Handle a task missing from a full Todoist fetch.
Treats the missing item as a remote completion and applies
`emacs-todoist-on-done-action' without prompting.

When SYNC-TOKEN is non-nil, write it before running DONE action."
  (let ((title (emacs-todoist-org-heading-title))
        (marker (point-marker)))
    (unless (equal (org-get-todo-state) "DONE")
      (emacs-todoist-set-todo-state "DONE"))
    (when sync-token
      (emacs-todoist-org-set-props
       `(("TODOIST_SYNC_TOKEN" . ,sync-token))))
    (emacs-todoist-log
     'info "Remote item missing; treating as completed and applying done action: %s"
     title)
    (emacs-todoist--run-on-done-action marker)))

;; ==============================================================================
;; User-facing smart sync commands
;; ==============================================================================

(defun emacs-todoist-sync-single-heading ()
  "Sync only the org heading at point with Todoist.
This command does not walk or reconcile descendant headings.  It
detects whether the current heading is new or existing, checks for
local and remote changes, and dispatches to the appropriate
push/pull/conflict handler."
  (interactive)
  (org-back-to-heading t)
  (let* ((props (emacs-todoist-org-heading-props))
         (todoist-id (alist-get "TODOIST_ID" props nil nil #'equal))
         (stored-local-hash (alist-get "TODOIST_LOCAL_HASH" props nil nil #'equal))
         (stored-remote-hash (alist-get "TODOIST_REMOTE_HASH" props nil nil #'equal))
         (stored-sync-token (alist-get "TODOIST_SYNC_TOKEN" props nil nil #'equal))
         (current-local-hash (emacs-todoist-org-heading-local-hash)))
    (if (null todoist-id)
        (emacs-todoist--push-new-heading)
      (let ((local-changed (not (equal current-local-hash stored-local-hash)))
            (marker (point-marker))
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
                    (items (alist-get 'items response))
                    (remote-item
                     (emacs-todoist--find-item-by-id items todoist-id))
                    remote-changed)
               (with-current-buffer (marker-buffer marker)
                 (save-excursion
                   (goto-char marker)
                   (if remote-item
                       (let ((remote-hash (emacs-todoist-api-hash-item remote-item)))
                         (setq remote-changed
                               (not (equal remote-hash stored-remote-hash)))
                         (cond
                          ((and (not local-changed) (not remote-changed))
                           (emacs-todoist-org-set-props
                            `(("TODOIST_SYNC_TOKEN" . ,new-sync-token)))
                           (emacs-todoist-log 'info "Already up to date: %s" todoist-id)
                           (message "emacs-todoist: already up to date"))
                          ((and (not local-changed) remote-changed)
                           (emacs-todoist--apply-pull remote-item new-sync-token))
                          ((and local-changed (not remote-changed))
                           (emacs-todoist--push-update
                            todoist-id stored-sync-token new-sync-token))
                          (t
                           (emacs-todoist--log-conflict-debug
                            'single todoist-id remote-item
                            current-local-hash stored-local-hash
                            remote-hash stored-remote-hash)
                           (pcase
                               (read-char-choice
                                "Conflict: both local and remote changed. Use [l]ocal or [r]emote? "
                                '(?l ?r))
                             (?l
                              (emacs-todoist--push-update
                               todoist-id stored-sync-token new-sync-token))
                             (?r
                              (emacs-todoist--apply-pull
                               remote-item new-sync-token))))))
                     (if (equal fetch-token "*")
                         (emacs-todoist--handle-deletion new-sync-token)
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
                 (emacs-todoist--find-item-by-id items todoist-id)))
           (with-current-buffer (marker-buffer marker)
             (save-excursion
               (goto-char marker)
                 (if remote-item
                     (emacs-todoist--apply-pull remote-item new-sync-token)
                   (emacs-todoist--handle-deletion new-sync-token))))))))))

;;;###autoload
(defun emacs-todoist-set-recurrence (due-string)
  "Set Todoist recurrence for the heading at point.
DUE-STRING is stored in the `TODOIST_DUE_STRING' property.

When DUE-STRING is empty (or whitespace), the recurrence property is
cleared."
  (interactive
   (progn
     (org-back-to-heading t)
     (list
      (read-string
       "Todoist recurrence (empty clears): "
       (or (org-entry-get (point) "TODOIST_DUE_STRING") "")))))
  (org-back-to-heading t)
  (let ((normalized (string-trim (or due-string ""))))
    (if (string-empty-p normalized)
        (org-entry-delete (point) "TODOIST_DUE_STRING")
      (org-entry-put (point) "TODOIST_DUE_STRING" normalized))
    (message
     "emacs-todoist: recurrence updated locally; run sync to validate with Todoist")))

;; ==============================================================================
;; Bulk sync core
;; ==============================================================================

(cl-defun emacs-todoist--sync-entries
    (linked-markers new-markers &key post-classify-fn done-fn fetch-token-override)
  "Sync LINKED-MARKERS (existing) and NEW-MARKERS (to push) with Todoist.
LINKED-MARKERS are markers for headings that already have a TODOIST_ID.
NEW-MARKERS are markers for headings without a TODOIST_ID to push as
new tasks.  Both lists may be nil.

POST-CLASSIFY-FN, when non-nil, is called after remote classification
and child insertion but before push dispatch.  It receives a context
plist and should return the number of additionally inserted headings.

DONE-FN, when non-nil, is called with a summary plist after a successful
sync pass (or no-op sync).

FETCH-TOKEN-OVERRIDE, when non-nil, replaces the normal batch-token
selection logic for the fetch phase.  This exists for frontend bootstrap:
a frontend file can be seeded by a freshly captured heading whose stored
`TODOIST_SYNC_TOKEN' would otherwise force an incremental fetch and miss
older remote items that have never been rendered locally.

The flow:
1. If NEW-MARKERS non-nil, ensure the project cache is populated.
2. Fetch remote items for LINKED-MARKERS in one API call.
3. Classify each linked heading (pull/push/skip/conflict/deleted).
4. Build item_add commands for new headings.
5. Send all push commands in a single API call.
6. Write back IDs, hashes, and sync token."
  (if (and (null linked-markers) (null new-markers) (null post-classify-fn))
      (progn
        (message "emacs-todoist: no headings to sync")
        (when done-fn
          (funcall done-fn
                   '(:status no-op :pulled 0 :pushed 0 :inserted 0 :skipped 0))))
    ;; Step 1: ensure project cache if we have new headings to push.
    (let* ((origin-buffer (current-buffer))
           (continue-fn
            (lambda ()
              (emacs-todoist--sync-entries-1
               linked-markers new-markers
               :post-classify-fn post-classify-fn
               :done-fn done-fn
               :fetch-token-override fetch-token-override
               :target-buffer origin-buffer))))
      (if new-markers
          (emacs-todoist--ensure-projects continue-fn)
        (funcall continue-fn)))))

(cl-defun emacs-todoist--sync-entries-1
    (linked-markers new-markers
                    &key post-classify-fn done-fn target-buffer fetch-token-override)
  "Internal continuation for `emacs-todoist--sync-entries'.
Called after project cache is ensured.  LINKED-MARKERS and NEW-MARKERS
are as in the parent function.  TARGET-BUFFER is the Org buffer that
requested sync and is used for post-classification hooks.

When FETCH-TOKEN-OVERRIDE is non-nil, use it as the fetch token instead
of deriving one from heading properties.  The frontend uses this to force
an initial `*' fetch before switching to incremental sync tokens."
  (if (and (null linked-markers) (null post-classify-fn))
      ;; No linked headings — skip fetch, go straight to pushing new ones.
      (emacs-todoist--sync-entries-push
       nil nil new-markers nil :done-fn done-fn)
    (let* ((tokens
            (mapcar (lambda (m)
                      (save-excursion
                        (with-current-buffer (marker-buffer m)
                          (goto-char m)
                          (or (org-entry-get (point) "TODOIST_SYNC_TOKEN") "*"))))
                    linked-markers))
           (batch-token
            (or fetch-token-override
                ;; Normal bulk sync reuses a shared incremental token only when
                ;; every linked heading agrees on it; otherwise fall back to a
                ;; full fetch.  `fetch-token-override' is reserved for callers
                ;; such as the frontend bootstrap flow that need to bypass this
                ;; heuristic intentionally.
                (if (null linked-markers)
                    "*"
                  (if (cl-every (lambda (tok) (equal tok (car tokens))) tokens)
                      (car tokens)
                    "*")))))
      (emacs-todoist-log 'debug "Bulk fetch with token: %s (%d headings)"
                         batch-token (length linked-markers))
      (emacs-todoist-api-sync
       batch-token '("items") nil
       (lambda (response)
         (if (alist-get 'error response)
             (progn
               (emacs-todoist-log 'error "Bulk fetch error: %s"
                                  (alist-get 'error response))
               (message "emacs-todoist: bulk fetch error"))
           (emacs-todoist--sync-entries-classify
            linked-markers new-markers response batch-token
            :post-classify-fn post-classify-fn
            :done-fn done-fn
            :target-buffer target-buffer)))))))

(cl-defun emacs-todoist--sync-entries-classify
    (linked-markers new-markers response batch-token
                    &key post-classify-fn done-fn target-buffer)
  "Classify linked headings and dispatch to push phase.
RESPONSE is the parsed fetch response.  BATCH-TOKEN is the token used
for the fetch (needed to detect deletions on full sync).  TARGET-BUFFER
is where post-classification hooks run."
  (let* ((new-sync-token (alist-get 'sync_token response))
         (items          (alist-get 'items response))
         (push-commands  '())
         (pushed-entries '())
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
                  (emacs-todoist--find-item-by-id items todoist-id)))
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
                    (push (list :marker marker
                                :todoist-id todoist-id
                                :state (emacs-todoist-org-heading-todo-state))
                          pushed-entries)))
                 (t
                  (emacs-todoist--log-conflict-debug
                   'bulk todoist-id remote-item
                   current-local-hash stored-local-hash
                   remote-hash stored-remote-hash)
                  (let ((choice (read-char-choice
                                 (format "Conflict on \"%s\": [l]ocal or [r]emote? "
                                         (emacs-todoist-org-heading-title))
                                 '(?l ?r))))
                    (pcase choice
                      (?l (let ((cmds (emacs-todoist--build-push-commands todoist-id)))
                            (setq push-commands (append push-commands cmds))
                            (push (list :marker marker
                                        :todoist-id todoist-id
                                        :state (emacs-todoist-org-heading-todo-state))
                                  pushed-entries)))
                      (?r (emacs-todoist--apply-pull remote-item new-sync-token)
                          (cl-incf pulled))))))))
             ;; Task not found + full sync → deleted remotely.
             ((equal batch-token "*")
              (emacs-todoist--handle-deletion new-sync-token))
             ;; Task not found + incremental → unchanged remotely.
             (t
              (if local-changed
                  (let ((cmds (emacs-todoist--build-push-commands todoist-id)))
                    (setq push-commands (append push-commands cmds))
                    (push (list :marker marker
                                :todoist-id todoist-id
                                :state (emacs-todoist-org-heading-todo-state))
                          pushed-entries))
                (emacs-todoist-org-set-props
                 `(("TODOIST_SYNC_TOKEN" . ,new-sync-token)))
                (cl-incf skipped))))))))
    ;; Step 4: apply remote items that are not yet represented by a
    ;; linked marker.  In normal buffers this inserts only children
    ;; whose parents already exist in the current tree.
    (let* ((id-map (emacs-todoist--build-id-map-from-markers linked-markers))
           (new-remote-items
            (cl-remove-if
             (lambda (item)
               (and-let* ((item-id (emacs-todoist--item-id item)))
                 (gethash item-id id-map)))
             (or items '())))
           (sorted-new-remote-items
            (emacs-todoist--topological-sort-items new-remote-items))
           (inserted-from-children
            (emacs-todoist--apply-items
             sorted-new-remote-items new-sync-token id-map))
           (inserted-from-hook
            (if post-classify-fn
                (let ((hook-buffer (and (buffer-live-p target-buffer)
                                        target-buffer)))
                  (if hook-buffer
                      (with-current-buffer hook-buffer
                        (or (funcall post-classify-fn
                                     (list :new-remote-items sorted-new-remote-items
                                           :new-sync-token new-sync-token
                                           :id-map id-map
                                           :items items))
                            0))
                    (progn
                      (emacs-todoist-log
                       'warn "Skipping post-classify hook: target buffer is dead")
                      0)))
              0))
           (inserted-total (+ inserted-from-children inserted-from-hook)))
    ;; All headings classified — proceed to push phase.
    (emacs-todoist--sync-entries-push
     push-commands (nreverse pushed-entries)
     new-markers new-sync-token
     :pulled pulled :skipped skipped :inserted inserted-total
     :done-fn done-fn)))

)

(cl-defun emacs-todoist--sync-entries-push
    (push-commands pushed-entries new-markers sync-token
     &key (pulled 0) (skipped 0) (inserted 0) done-fn)
  "Send batch push and new-heading commands, then write back results.
PUSH-COMMANDS is a list of update/complete/uncomplete commands.
PUSHED-ENTRIES is a list of plist entries with marker/id/state metadata.
NEW-MARKERS are markers for brand-new headings to push.
SYNC-TOKEN is the token to use for this push call.
PULLED, SKIPPED, and INSERTED are counters for the summary message."
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
          (emacs-todoist-log
           'info "Bulk sync: pulled %d, pushed 0, inserted %d, skipped %d"
           pulled inserted skipped)
          (message
           "emacs-todoist: synced (pulled %d, pushed 0, inserted %d, skipped %d)"
           pulled inserted skipped)
          (when done-fn
            (funcall done-fn
                     (list :status 'ok :pulled pulled :pushed 0
                           :inserted inserted :skipped skipped))))
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
            pushed-entries new-entries new-markers response
            :pulled pulled :skipped skipped :inserted inserted
            :done-fn done-fn))))))))
(cl-defun emacs-todoist--sync-entries-writeback
    (pushed-entries new-entries new-markers response
     &key (pulled 0) (skipped 0) (inserted 0) done-fn)
  "Write back hashes and IDs after a successful bulk push.
PUSHED-ENTRIES are plist entries for updated headings.
NEW-ENTRIES is a list of (TEMP-ID . MARKER) for new headings.
NEW-MARKERS is the original list of new heading markers (for counting).
RESPONSE is the parsed API response."
  (let ((resp-token (alist-get 'sync_token response))
        (resp-items (alist-get 'items response))
        (pushed-count 0))
    (cl-labels
        ((finalize (summary-token)
           ;; Write IDs + hashes for new headings.
           (when new-entries
             (emacs-todoist--write-new-heading-props new-entries response)
             (cl-incf pushed-count (length new-markers)))
           (emacs-todoist-log
            'info "Bulk sync: pulled %d, pushed %d, inserted %d, skipped %d"
            pulled pushed-count inserted skipped)
           (message
            "emacs-todoist: synced (pulled %d, pushed %d, inserted %d, skipped %d)"
            pulled pushed-count inserted skipped)
           (when done-fn
             (funcall done-fn
                      (list :status 'ok :pulled pulled :pushed pushed-count
                            :inserted inserted :skipped skipped
                            :sync-token summary-token)))))
      (let ((missing-done-entries '()))
        (dolist (entry pushed-entries)
          (let* ((marker (plist-get entry :marker))
                 (todoist-id (plist-get entry :todoist-id))
                 (state (plist-get entry :state))
                 (done-p (equal state "DONE")))
            (if done-p
                (let ((resp-item (emacs-todoist--find-item-by-id
                                  resp-items todoist-id)))
                  (if resp-item
                      (progn
                        (when (and (markerp marker) (marker-buffer marker))
                          (with-current-buffer (marker-buffer marker)
                            (save-excursion
                              (goto-char marker)
                              (emacs-todoist--apply-pull
                               resp-item resp-token :silent t))))
                        (cl-incf pushed-count))
                    (push entry missing-done-entries)))
              (emacs-todoist--write-local-push-writeback marker resp-token)
              (cl-incf pushed-count))))
        (if (null missing-done-entries)
            (finalize resp-token)
          (emacs-todoist-log
           'warn "Bulk DONE reconcile missing %d item(s); fetching full state"
           (length missing-done-entries))
          (emacs-todoist-api-sync
           "*" '("items") nil
           (lambda (fetch-response)
             (let ((summary-token
                    (or (alist-get 'sync_token fetch-response) resp-token)))
               (if (alist-get 'error fetch-response)
                   (progn
                     (emacs-todoist-log
                      'warn "Bulk fallback reconcile fetch failed: %s"
                      (alist-get 'error fetch-response))
                     (dolist (entry missing-done-entries)
                       (emacs-todoist--write-local-push-writeback
                        (plist-get entry :marker) resp-token)
                       (cl-incf pushed-count)))
                 (let ((fetch-items (alist-get 'items fetch-response)))
                   (dolist (entry missing-done-entries)
                     (let* ((marker (plist-get entry :marker))
                            (todoist-id (plist-get entry :todoist-id))
                            (fetched-item (emacs-todoist--find-item-by-id
                                           fetch-items todoist-id)))
                       (if fetched-item
                           (when (and (markerp marker) (marker-buffer marker))
                             (with-current-buffer (marker-buffer marker)
                               (save-excursion
                                 (goto-char marker)
                                 (emacs-todoist--apply-pull
                                  fetched-item summary-token :silent t))))
                         (progn
                           (emacs-todoist-log
                            'warn "Bulk fallback reconcile missing item %s; using local writeback"
                            todoist-id)
                           (emacs-todoist--write-local-push-writeback
                            marker summary-token)))
                       (cl-incf pushed-count)))))
               (finalize summary-token)))))))))

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
                  (emacs-todoist--unsynced-todo-markers
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
                  (emacs-todoist--unsynced-todo-markers
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
                   (emacs-todoist--unsynced-todo-markers
                    (emacs-todoist-org-todo-entries-in-region beg end)))))
    (emacs-todoist--sync-entries linked new)))

(provide 'emacs-todoist)
;;; emacs-todoist.el ends here
