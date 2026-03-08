;;; test-live.el --- Live API tests for emacs-todoist  -*- lexical-binding: t; -*-

;; These tests make real HTTP calls to the Todoist Sync API v1.
;; They require a valid API token in .todoist_api_token at the project root.
;;
;; Run with:
;;   make test FILE=test-live
;;
;; These tests are NOT included in the default `make test' target to avoid
;; hitting the API on every run.  They create tasks, verify sync behaviour,
;; and delete the tasks afterwards.

(require 'ert)
(require 'cl-lib)
(require 'emacs-todoist)

;; ==============================================================================
;; Token loading
;; ==============================================================================

(defvar emacs-todoist-test-live--token nil
  "Cached API token read from .todoist_api_token.")

(defun emacs-todoist-test-live--load-token ()
  "Read the API token from .todoist_api_token at the project root.
Returns the token string, or signals an error if the file is missing."
  (or emacs-todoist-test-live--token
      (let* ((project-root (locate-dominating-file
                            (or load-file-name buffer-file-name default-directory)
                            ".todoist_api_token"))
             (token-file (and project-root
                              (expand-file-name ".todoist_api_token" project-root))))
        (unless (and token-file (file-exists-p token-file))
          (error "Missing .todoist_api_token file — cannot run live tests"))
        (setq emacs-todoist-test-live--token
              (string-trim (with-temp-buffer
                             (insert-file-contents token-file)
                             (buffer-string)))))))

;; ==============================================================================
;; Synchronous sync wrapper
;; ==============================================================================

;; `emacs-todoist-api-sync' uses `url-retrieve' (async), which does not
;; work reliably in batch Emacs.  This wrapper uses
;; `url-retrieve-synchronously' directly, duplicating just enough of
;; the request-building logic from `emacs-todoist-api-sync' to form
;; the HTTP call.

(defun emacs-todoist-test-live--sync-blocking (sync-token resource-types commands)
  "Perform a synchronous Todoist Sync API call.
Returns the parsed response alist.  Signals an error on failure."
  (let* ((url-request-method "POST")
         (url-request-extra-headers
          `(("Authorization" . ,(concat "Bearer " (emacs-todoist-api-token)))
            ("Content-Type"  . "application/json")))
         (body `((sync_token     . ,sync-token)
                 (resource_types . ,(vconcat resource-types))
                 (commands       . ,(vconcat (or commands [])))))
         (url-request-data (encode-coding-string (json-encode body) 'utf-8))
         (response-buffer (url-retrieve-synchronously
                           "https://api.todoist.com/api/v1/sync" t nil 30)))
    (unless response-buffer
      (error "url-retrieve-synchronously returned nil"))
    (unwind-protect
        (with-current-buffer response-buffer
          (goto-char (point-min))
          (re-search-forward "\r?\n\r?\n")
          (let* ((json-object-type 'alist)
                 (json-array-type  'list)
                 (json-key-type    'symbol)
                 (parsed (json-read)))
            ;; The API returns top-level `error' on auth/request failures
            ;; (e.g. invalid token), which is distinct from per-command
            ;; errors in `sync_status'.
            (when (alist-get 'error parsed)
              (error "Todoist API error: %s (code %s)"
                     (alist-get 'error parsed)
                     (alist-get 'error_code parsed)))
            (emacs-todoist-api-parse-response parsed)))
      (kill-buffer response-buffer))))

;; ==============================================================================
;; Cleanup tracking
;; ==============================================================================

;; We track all task IDs created during tests so we can delete them in
;; teardown, even if a test fails partway through.

(defvar emacs-todoist-test-live--created-ids nil
  "List of Todoist task IDs created during the current test.
Cleaned up by `emacs-todoist-test-live--cleanup'.")

(defun emacs-todoist-test-live--cleanup ()
  "Delete all tasks created during the current test."
  (when emacs-todoist-test-live--created-ids
    (let ((commands (emacs-todoist-api-item-delete
                     emacs-todoist-test-live--created-ids)))
      (condition-case err
          (emacs-todoist-test-live--sync-blocking "*" '("items") commands)
        (error (message "Live test cleanup warning: %s" (error-message-string err)))))
    (setq emacs-todoist-test-live--created-ids nil)))

(defun emacs-todoist-test-live--create-task (title &optional description)
  "Create a task on Todoist with TITLE and optional DESCRIPTION.
Returns the real task ID.  Registers the ID for cleanup."
  (let* ((temp-id (emacs-todoist-api-generate-uuid))
         (cmd (emacs-todoist-api-item-add
               title
               :description description
               :temp-id temp-id))
         (response (emacs-todoist-test-live--sync-blocking "*" '("items") (list cmd)))
         (mapping (alist-get 'temp_id_mapping response))
         ;; JSON keys are symbols, but temp-id is a string.
         (real-id (cdr (assoc temp-id mapping
                              (lambda (a b)
                                (equal (format "%s" a)
                                       (format "%s" b)))))))
    (unless real-id
      (error "Failed to create task — no ID in temp_id_mapping"))
    (push real-id emacs-todoist-test-live--created-ids)
    real-id))

(defun emacs-todoist-test-live--update-task (id &rest args)
  "Update task ID on Todoist.  ARGS are passed to `emacs-todoist-api-item-update'."
  (let ((cmd (apply #'emacs-todoist-api-item-update id args)))
    (emacs-todoist-test-live--sync-blocking "*" '("items") (list cmd))))

(defun emacs-todoist-test-live--complete-task (id)
  "Complete task ID on Todoist via the Sync API."
  (let ((commands (emacs-todoist-api-item-complete (list id))))
    (emacs-todoist-test-live--sync-blocking "*" '("items") commands)))

(defun emacs-todoist-test-live--fetch-task (id)
  "Fetch task ID from Todoist.  Returns the item alist, or nil if not found.
ID can be a string or number — comparison coerces both to strings
since org properties store IDs as strings but the API may return numbers."
  (let* ((response (emacs-todoist-test-live--sync-blocking "*" '("items") nil))
         (items (alist-get 'items response))
         (id-str (format "%s" id)))
    (cl-find-if (lambda (item)
                  (equal (format "%s" (alist-get 'id item)) id-str))
                items)))

;; ==============================================================================
;; Test helper: with-org-buffer (same as test-integration.el)
;; ==============================================================================

(defmacro with-org-buffer (text &rest body)
  "Execute BODY in a temp org-mode buffer containing TEXT.
Point is placed at the first heading."
  (declare (indent 1))
  `(with-temp-buffer
     (org-mode)
     (insert ,text)
     (goto-char (point-min))
     (when (re-search-forward "^\\*" nil t)
       (beginning-of-line))
     ,@body))

;; ==============================================================================
;; Test helper: synchronous sync-heading
;; ==============================================================================

;; `emacs-todoist-sync-heading' and friends use async callbacks internally.
;; We mock `emacs-todoist-api-sync' to call the callback synchronously
;; but still make the real HTTP call via `url-retrieve-synchronously'.

(defun emacs-todoist-test-live--install-sync-shim ()
  "Replace `emacs-todoist-api-sync' with a synchronous version.
Returns a function to restore the original."
  (let ((original (symbol-function 'emacs-todoist-api-sync)))
    (fset 'emacs-todoist-api-sync
          (lambda (sync-token resource-types commands callback)
            (let ((response (emacs-todoist-test-live--sync-blocking
                             sync-token resource-types commands)))
              (funcall callback response))))
    (lambda () (fset 'emacs-todoist-api-sync original))))

(defmacro with-live-sync (&rest body)
  "Execute BODY with `emacs-todoist-api-sync' running synchronously.
Also sets up the API token and ensures cleanup on failure."
  (declare (indent 0))
  `(let ((emacs-todoist-api-token (emacs-todoist-test-live--load-token))
         (emacs-todoist-test-live--created-ids nil)
         (emacs-todoist-log-level 'debug))
     (let ((restore (emacs-todoist-test-live--install-sync-shim)))
       (unwind-protect
           (progn ,@body)
         (funcall restore)
         (emacs-todoist-test-live--cleanup)))))

;; ==============================================================================
;; Tests: Push new heading
;; ==============================================================================

(ert-deftest emacs-todoist-live/push-new-heading ()
  "Pushing a new heading creates a task on Todoist and writes back properties."
  (with-live-sync
    (with-org-buffer "* TODO Live test task\nA description for live test.\n"
      (emacs-todoist-sync-heading)

      ;; Properties should be written back.
      (let ((todoist-id (org-entry-get (point) "TODOIST_ID")))
        (should todoist-id)
        (should (org-entry-get (point) "TODOIST_LOCAL_HASH"))
        (should (org-entry-get (point) "TODOIST_REMOTE_HASH"))
        (should (org-entry-get (point) "TODOIST_SYNC_TOKEN"))

        ;; Register for cleanup.
        (push todoist-id emacs-todoist-test-live--created-ids)

        ;; The task should exist on Todoist with the correct content.
        (let ((remote (emacs-todoist-test-live--fetch-task todoist-id)))
          (should remote)
          (should (equal "Live test task" (alist-get 'content remote)))
          (should (equal "A description for live test."
                         (alist-get 'description remote))))))))

;; ==============================================================================
;; Tests: Push then re-sync unchanged
;; ==============================================================================

(ert-deftest emacs-todoist-live/sync-unchanged-is-noop ()
  "Re-syncing an unchanged heading is a no-op (only token updates)."
  (with-live-sync
    (with-org-buffer "* TODO Unchanged task\n"
      ;; Initial push.
      (emacs-todoist-sync-heading)
      (let ((todoist-id (org-entry-get (point) "TODOIST_ID"))
            (hash-before (org-entry-get (point) "TODOIST_LOCAL_HASH")))
        (should todoist-id)
        (push todoist-id emacs-todoist-test-live--created-ids)

        ;; Re-sync without any changes.
        (emacs-todoist-sync-heading)

        ;; Local hash should be the same (nothing changed).
        (should (equal hash-before
                       (org-entry-get (point) "TODOIST_LOCAL_HASH")))
        ;; Title should still be the same.
        (should (equal "Unchanged task"
                       (emacs-todoist-org-heading-title)))))))

;; ==============================================================================
;; Tests: Push local changes
;; ==============================================================================

(ert-deftest emacs-todoist-live/push-local-changes ()
  "Editing the heading locally and syncing pushes the update to Todoist."
  (with-live-sync
    (with-org-buffer "* TODO Original title\n"
      ;; Initial push.
      (emacs-todoist-sync-heading)
      (let ((todoist-id (org-entry-get (point) "TODOIST_ID")))
        (should todoist-id)
        (push todoist-id emacs-todoist-test-live--created-ids)

        ;; Edit the heading title locally.
        (org-edit-headline "Updated title from Emacs")

        ;; Sync again — should detect local change and push.
        (emacs-todoist-sync-heading)

        ;; Verify on Todoist.
        (let ((remote (emacs-todoist-test-live--fetch-task todoist-id)))
          (should remote)
          (should (equal "Updated title from Emacs"
                         (alist-get 'content remote))))))))

;; ==============================================================================
;; Tests: Pull remote changes
;; ==============================================================================

(ert-deftest emacs-todoist-live/pull-remote-changes ()
  "When a task is modified on Todoist, syncing pulls the changes locally."
  (with-live-sync
    (with-org-buffer "* TODO Task for remote edit\nOriginal body.\n"
      ;; Initial push.
      (emacs-todoist-sync-heading)
      (let ((todoist-id (org-entry-get (point) "TODOIST_ID")))
        (should todoist-id)
        (push todoist-id emacs-todoist-test-live--created-ids)

        ;; Modify the task directly on Todoist via the API.
        (emacs-todoist-test-live--update-task
         todoist-id
         :content "Remotely changed title"
         :description "Remotely changed body.")

        ;; Sync — should detect remote changes and pull them.
        (emacs-todoist-sync-heading)

        ;; The heading should now reflect the remote changes.
        (should (equal "Remotely changed title"
                       (emacs-todoist-org-heading-title)))
        (should (equal "Remotely changed body."
                       (emacs-todoist-org-heading-description)))))))

;; ==============================================================================
;; Tests: Force pull
;; ==============================================================================

(ert-deftest emacs-todoist-live/force-pull ()
  "Force pull overwrites local state with remote data."
  (with-live-sync
    (with-org-buffer "* TODO Will be overwritten\n"
      ;; Initial push.
      (emacs-todoist-sync-heading)
      (let ((todoist-id (org-entry-get (point) "TODOIST_ID")))
        (should todoist-id)
        (push todoist-id emacs-todoist-test-live--created-ids)

        ;; Modify remotely.
        (emacs-todoist-test-live--update-task
         todoist-id
         :content "Force pulled title")

        ;; Also modify locally (creating a conflict scenario).
        (org-edit-headline "Local edit that should be lost")

        ;; Force pull — should overwrite local.
        (emacs-todoist-pull-heading)

        (should (equal "Force pulled title"
                       (emacs-todoist-org-heading-title)))))))

;; ==============================================================================
;; Tests: Force push
;; ==============================================================================

(ert-deftest emacs-todoist-live/force-push ()
  "Force push overwrites remote state with local data."
  (with-live-sync
    (with-org-buffer "* TODO Initial push target\n"
      ;; Initial push.
      (emacs-todoist-sync-heading)
      (let ((todoist-id (org-entry-get (point) "TODOIST_ID")))
        (should todoist-id)
        (push todoist-id emacs-todoist-test-live--created-ids)

        ;; Modify remotely (this change should be overwritten).
        (emacs-todoist-test-live--update-task
         todoist-id
         :content "Remote edit to be overwritten")

        ;; Modify locally and force push.
        (org-edit-headline "Force pushed from Emacs")
        (emacs-todoist-push-heading)

        ;; Verify remote now has local content.
        (let ((remote (emacs-todoist-test-live--fetch-task todoist-id)))
          (should remote)
          (should (equal "Force pushed from Emacs"
                         (alist-get 'content remote))))))))

;; ==============================================================================
;; Tests: Deadline round-trip
;; ==============================================================================

(ert-deftest emacs-todoist-live/deadline-round-trip ()
  "A heading with a DEADLINE syncs the date to Todoist and back."
  (with-live-sync
    (with-org-buffer "* TODO Deadline task\nDEADLINE: <2026-09-15 Tue>\n"
      ;; Push with deadline.
      (emacs-todoist-sync-heading)
      (let ((todoist-id (org-entry-get (point) "TODOIST_ID")))
        (should todoist-id)
        (push todoist-id emacs-todoist-test-live--created-ids)

        ;; Verify deadline made it to Todoist.
        (let ((remote (emacs-todoist-test-live--fetch-task todoist-id)))
          (should remote)
          (let ((due (alist-get 'due remote)))
            (should due)
            (should (equal "2026-09-15"
                           (alist-get 'date due)))))))))

;; ==============================================================================
;; Tests: Local recurring completion
;; ==============================================================================

(ert-deftest emacs-todoist-live/local-done-on-recurring-reopens-task ()
  "Marking a recurring task DONE locally should reopen at the next occurrence."
  (with-live-sync
    (let ((today (format-time-string "%Y-%m-%d")))
      (with-org-buffer
          (format "* TODO Recurring done test\nDEADLINE: <%s>\n:PROPERTIES:\n:TODOIST_DUE_STRING: every day\n:END:\n"
                  today)
        ;; Initial push.
        (emacs-todoist-sync-heading)
        (let ((todoist-id (org-entry-get (point) "TODOIST_ID")))
          (should todoist-id)
          (push todoist-id emacs-todoist-test-live--created-ids)

          ;; Complete locally, then sync.  For recurring tasks this should
          ;; close the current occurrence and immediately reopen the next one.
          (org-todo "DONE")
          (emacs-todoist-sync-heading)

          ;; Local heading should be reopened with recurrence still present.
          (should (equal "TODO" (org-get-todo-state)))
          (should (org-entry-get (point) "TODOIST_DUE_STRING"))
          (should (equal "every day"
                         (org-entry-get (point) "TODOIST_DUE_STRING")))
          (should (emacs-todoist-org-heading-deadline))
          (should-not (equal today (emacs-todoist-org-heading-deadline)))

          ;; Remote task should remain active and recurring.
          (let ((remote (emacs-todoist-test-live--fetch-task todoist-id)))
            (should remote)
            (should (equal "TODO"
                           (emacs-todoist--checked-to-state
                            (alist-get 'checked remote))))
            (let ((due (alist-get 'due remote)))
              (should due)
              (should (equal "every day" (alist-get 'string due)))
              (should (alist-get 'is_recurring due)))))))))

;; ==============================================================================
;; Tests: Description round-trip
;; ==============================================================================

(ert-deftest emacs-todoist-live/description-round-trip ()
  "Body text syncs as the Todoist description and back."
  (with-live-sync
    (with-org-buffer "* TODO Desc task\nThis is the body text.\n"
      (emacs-todoist-sync-heading)
      (let ((todoist-id (org-entry-get (point) "TODOIST_ID")))
        (should todoist-id)
        (push todoist-id emacs-todoist-test-live--created-ids)

        ;; Verify description on Todoist.
        (let ((remote (emacs-todoist-test-live--fetch-task todoist-id)))
          (should remote)
          (should (equal "This is the body text."
                         (alist-get 'description remote))))

        ;; Update description remotely.
        (emacs-todoist-test-live--update-task
         todoist-id
         :description "Remotely updated description.")

        ;; Sync back.
        (emacs-todoist-sync-heading)
        (should (equal "Remotely updated description."
                       (emacs-todoist-org-heading-description)))))))

;; ==============================================================================
;; Tests: Sync after remote completion
;; ==============================================================================

(ert-deftest emacs-todoist-live/sync-after-remote-complete ()
  "Syncing a heading after the task is completed on Todoist pulls the DONE state.
Reproduces: `Wrong type argument: number-or-marker-p, t' — the API
returns `checked' as JSON true (t in Elisp), but the code used `=' which
requires numeric arguments."
  (with-live-sync
    (with-org-buffer "* TODO Task to complete remotely\n"
      ;; Push the heading.
      (emacs-todoist-sync-heading)
      (let ((todoist-id (org-entry-get (point) "TODOIST_ID")))
        (should todoist-id)
        (push todoist-id emacs-todoist-test-live--created-ids)

        ;; Complete the task on Todoist via the API.
        (emacs-todoist-test-live--complete-task todoist-id)

        ;; Re-sync — this triggers the fetch path that reads `checked'.
        (emacs-todoist-sync-heading)

        ;; The heading should now be DONE.
        (should (equal "DONE" (org-get-todo-state)))))))

;;; test-live.el ends here
