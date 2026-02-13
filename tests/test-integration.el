;;; test-integration.el --- Integration tests for emacs-todoist  -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'emacs-todoist)

;; ==============================================================================
;; Test helpers
;; ==============================================================================

(defvar emacs-todoist-test--sync-calls nil
  "List of captured `emacs-todoist-api-sync' call arguments.
Each entry is an alist with keys: `sync-token', `resource-types',
`commands'.")

(defvar emacs-todoist-test--sync-response nil
  "Response alist to return from the mocked sync call.")

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

(defmacro with-mock-sync (response &rest body)
  "Execute BODY with `emacs-todoist-api-sync' mocked.
RESPONSE is the alist the mock will pass to the callback.
Captured call arguments are stored in `emacs-todoist-test--sync-calls'."
  (declare (indent 1))
  `(let ((emacs-todoist-test--sync-calls nil)
         (emacs-todoist-test--sync-response ,response)
         ;; Suppress interactive messages during tests.
         (emacs-todoist-log-level 'error))
     (cl-letf (((symbol-function 'emacs-todoist-api-sync)
                (lambda (sync-token resource-types commands callback)
                  (push (list (cons 'sync-token sync-token)
                              (cons 'resource-types resource-types)
                              (cons 'commands commands))
                        emacs-todoist-test--sync-calls)
                  (funcall callback emacs-todoist-test--sync-response))))
       ,@body)))

;; ==============================================================================
;; Smoke test
;; ==============================================================================

(ert-deftest emacs-todoist-integration-smoke-test ()
  "Trivial smoke test to verify test infrastructure works."
  (should (featurep 'emacs-todoist)))

;; ==============================================================================
;; New heading push (no TODOIST_ID)
;; ==============================================================================

(ert-deftest emacs-todoist-integration/push-new-heading ()
  "Pushing a new heading (no TODOIST_ID) sends item_add and writes back IDs."
  (with-org-buffer "* TODO Buy groceries\nShopping list.\n"
    (let ((emacs-todoist-default-project "proj-123"))
      (with-mock-sync
          `((sync_token . "tok-after-push")
            (temp_id_mapping . nil)
            (items . nil))
        ;; The mock won't have the temp_id in the mapping, so we need to
        ;; intercept and set it up properly.  Override the mock to capture
        ;; the temp_id from the command and map it.
        (cl-letf (((symbol-function 'emacs-todoist-api-sync)
                   (lambda (sync-token resource-types commands callback)
                     (push (list (cons 'sync-token sync-token)
                                 (cons 'resource-types resource-types)
                                 (cons 'commands commands))
                           emacs-todoist-test--sync-calls)
                     ;; Extract temp_id from the first command and map it
                     ;; to a fake real ID.
                     (let* ((cmd (car commands))
                            (temp-id (alist-get 'temp_id cmd)))
                       (funcall callback
                                `((sync_token . "tok-after-push")
                                  (temp_id_mapping . ((,temp-id . "real-id-999")))
                                  (items . nil)))))))
          (emacs-todoist-sync-heading))

        ;; Verify the sync call was made.
        (should (= 1 (length emacs-todoist-test--sync-calls)))

        ;; Verify the command was item_add with correct content.
        (let* ((call (car emacs-todoist-test--sync-calls))
               (commands (alist-get 'commands call))
               (cmd (car commands))
               (args (alist-get 'args cmd)))
          (should (equal "item_add" (alist-get 'type cmd)))
          (should (equal "Buy groceries" (alist-get 'content args)))
          (should (equal "proj-123" (alist-get 'project_id args))))

        ;; Verify properties were written back to the heading.
        (should (equal "real-id-999"
                       (org-entry-get (point) "TODOIST_ID")))
        (should (org-entry-get (point) "TODOIST_LOCAL_HASH"))
        (should (org-entry-get (point) "TODOIST_REMOTE_HASH"))
        (should (equal "tok-after-push"
                       (org-entry-get (point) "TODOIST_SYNC_TOKEN")))))))

(ert-deftest emacs-todoist-integration/push-new-heading-with-children ()
  "Pushing a heading with children sends batch commands with temp_id references."
  (with-org-buffer "* TODO Parent task\n** TODO Child A\n** TODO Child B\n"
    (with-mock-sync nil
      ;; Override to capture temp_ids and build proper mapping.
      (cl-letf (((symbol-function 'emacs-todoist-api-sync)
                 (lambda (_sync-token _resource-types commands callback)
                   (push (list (cons 'commands commands))
                         emacs-todoist-test--sync-calls)
                   ;; Map all temp_ids to fake real IDs.
                   (let ((mapping nil)
                         (counter 100))
                     (dolist (cmd commands)
                       (when-let* ((tid (alist-get 'temp_id cmd)))
                         (push (cons tid (format "real-%d" counter)) mapping)
                         (cl-incf counter)))
                     (funcall callback
                              `((sync_token . "tok-children")
                                (temp_id_mapping . ,mapping)
                                (items . nil)))))))
        (emacs-todoist-sync-heading))

      ;; Should have sent 3 commands: parent + 2 children.
      (let* ((call (car emacs-todoist-test--sync-calls))
             (commands (alist-get 'commands call)))
        (should (= 3 (length commands)))
        ;; All should be item_add.
        (should (cl-every (lambda (cmd) (equal "item_add" (alist-get 'type cmd)))
                          commands))
        ;; The children should reference the parent's temp_id as parent_id.
        (let* ((parent-cmd (nth 0 commands))
               (parent-temp-id (alist-get 'temp_id parent-cmd))
               (child-1-args (alist-get 'args (nth 1 commands)))
               (child-2-args (alist-get 'args (nth 2 commands))))
          (should parent-temp-id)
          (should (equal parent-temp-id (alist-get 'parent_id child-1-args)))
          (should (equal parent-temp-id (alist-get 'parent_id child-2-args))))))))

;; ==============================================================================
;; Remote-only change (pull)
;; ==============================================================================

(ert-deftest emacs-todoist-integration/remote-only-change ()
  "When only the remote changed, applies remote data to the local heading."
  (with-org-buffer "* TODO Buy groceries\nOld description.\n"
    ;; Set up as if we've previously synced: store matching local hash
    ;; and a remote hash that will differ from the fetched item.
    (let ((local-hash (emacs-todoist-org-heading-local-hash)))
      (emacs-todoist-org-set-props
       `(("TODOIST_ID"          . "task-42")
         ("TODOIST_LOCAL_HASH"  . ,local-hash)
         ("TODOIST_REMOTE_HASH" . "old-remote-hash-that-will-differ")
         ("TODOIST_SYNC_TOKEN"  . "old-token"))))

    ;; Mock returns the item with changed content.
    (with-mock-sync
        `((sync_token . "new-token-after-pull")
          (items . (((id . "task-42")
                     (content . "Buy organic groceries")
                     (description . "Updated description.")
                     (due . ((date . "2026-03-01")))
                     (checked . 0)))))
      (emacs-todoist-sync-heading))

    ;; The heading should now have the remote data applied.
    (should (equal "Buy organic groceries" (emacs-todoist-org-heading-title)))
    (should (equal "Updated description." (emacs-todoist-org-heading-description)))
    (should (equal "2026-03-01" (emacs-todoist-org-heading-deadline)))
    (should (equal "new-token-after-pull"
                   (org-entry-get (point) "TODOIST_SYNC_TOKEN")))))

;; ==============================================================================
;; Local-only change (push update)
;; ==============================================================================

(ert-deftest emacs-todoist-integration/local-only-change ()
  "When only the local changed, pushes an update to Todoist."
  (with-org-buffer "* TODO Buy groceries\nOriginal.\n"
    ;; Simulate a previously-synced state with a stale local hash
    ;; (so it looks like local changed).
    (emacs-todoist-org-set-props
     `(("TODOIST_ID"          . "task-42")
       ("TODOIST_LOCAL_HASH"  . "stale-local-hash")
       ("TODOIST_REMOTE_HASH" . "does-not-matter")
       ("TODOIST_SYNC_TOKEN"  . "old-token")))

    ;; The fetch returns no items (incremental sync, task unchanged remotely).
    (let ((sync-call-count 0))
      (with-mock-sync nil
        (cl-letf (((symbol-function 'emacs-todoist-api-sync)
                   (lambda (sync-token resource-types commands callback)
                     (cl-incf sync-call-count)
                     (push (list (cons 'sync-token sync-token)
                                 (cons 'resource-types resource-types)
                                 (cons 'commands commands))
                           emacs-todoist-test--sync-calls)
                     (if (null commands)
                         ;; First call: fetch (no commands) → no items returned
                         (funcall callback
                                  `((sync_token . "mid-token")
                                    (items . nil)))
                       ;; Second call: push update → success
                       (funcall callback
                                `((sync_token . "final-token")
                                  (items . nil)))))))
          (emacs-todoist-sync-heading))

        ;; Two sync calls: one fetch, one push.
        (should (= 2 (length emacs-todoist-test--sync-calls)))

        ;; The push call should have item_update command.
        (let* ((push-call (car emacs-todoist-test--sync-calls))
               (commands (alist-get 'commands push-call)))
          (should commands)
          ;; Should contain item_update.
          (should (cl-some (lambda (cmd)
                             (equal "item_update" (alist-get 'type cmd)))
                           commands)))

        ;; Properties should be updated.
        (should (org-entry-get (point) "TODOIST_LOCAL_HASH"))
        (should (org-entry-get (point) "TODOIST_REMOTE_HASH"))))))

;; ==============================================================================
;; Neither changed (up to date)
;; ==============================================================================

(ert-deftest emacs-todoist-integration/neither-changed ()
  "When neither side changed, only the sync token is updated."
  (with-org-buffer "* TODO Buy groceries\nSame as before.\n"
    (let ((local-hash (emacs-todoist-org-heading-local-hash))
          ;; Build a remote item that matches current local state so its
          ;; hash will match the stored remote hash.
          (remote-item `((content . "Buy groceries")
                         (description . "Same as before.")
                         (due)
                         (checked . 0))))
      (let ((remote-hash (emacs-todoist-api-hash-item remote-item)))
        (emacs-todoist-org-set-props
         `(("TODOIST_ID"          . "task-42")
           ("TODOIST_LOCAL_HASH"  . ,local-hash)
           ("TODOIST_REMOTE_HASH" . ,remote-hash)
           ("TODOIST_SYNC_TOKEN"  . "old-token")))

        ;; Return the same item from remote (hashes will match).
        (with-mock-sync
            `((sync_token . "updated-token")
              (items . (,remote-item)))
          ;; Need to add `id' to the item for lookup.
          (cl-letf (((symbol-function 'emacs-todoist-api-sync)
                     (lambda (sync-token _resource-types commands callback)
                       (push (list (cons 'sync-token sync-token)
                                   (cons 'commands commands))
                             emacs-todoist-test--sync-calls)
                       (funcall callback
                                `((sync_token . "updated-token")
                                  (items . (((id . "task-42")
                                             (content . "Buy groceries")
                                             (description . "Same as before.")
                                             (due)
                                             (checked . 0)))))))))
            (emacs-todoist-sync-heading))

          ;; Only one sync call (the fetch), no push needed.
          (should (= 1 (length emacs-todoist-test--sync-calls)))
          ;; No commands were sent.
          (let ((call (car emacs-todoist-test--sync-calls)))
            (should (null (alist-get 'commands call))))
          ;; Sync token updated.
          (should (equal "updated-token"
                         (org-entry-get (point) "TODOIST_SYNC_TOKEN"))))))))

;; ==============================================================================
;; Incremental sync — task not in response means unchanged
;; ==============================================================================

(ert-deftest emacs-todoist-integration/incremental-no-item-means-unchanged ()
  "On incremental sync, missing item means unchanged, not deleted."
  (with-org-buffer "* TODO Stable task\n"
    (let ((local-hash (emacs-todoist-org-heading-local-hash)))
      (emacs-todoist-org-set-props
       `(("TODOIST_ID"          . "task-42")
         ("TODOIST_LOCAL_HASH"  . ,local-hash)
         ("TODOIST_REMOTE_HASH" . "some-hash")
         ("TODOIST_SYNC_TOKEN"  . "real-token"))))

    ;; Incremental sync returns no items (task not in delta).
    (with-mock-sync
        `((sync_token . "newer-token")
          (items . nil))
      (emacs-todoist-sync-heading))

    ;; Heading should still exist with updated sync token.
    (should (equal "task-42" (org-entry-get (point) "TODOIST_ID")))
    (should (equal "newer-token"
                   (org-entry-get (point) "TODOIST_SYNC_TOKEN")))))

;; ==============================================================================
;; Force push
;; ==============================================================================

(ert-deftest emacs-todoist-integration/force-push-existing ()
  "Force push sends an update regardless of remote state."
  (with-org-buffer "* TODO Updated task\nNew body.\n"
    (emacs-todoist-org-set-props
     '(("TODOIST_ID"         . "task-42")
       ("TODOIST_SYNC_TOKEN" . "some-token")))

    (with-mock-sync
        `((sync_token . "after-force-push")
          (items . nil))
      (emacs-todoist-push-heading)

      ;; Should have sent commands (not just a fetch).
      (should (= 1 (length emacs-todoist-test--sync-calls)))
      (let* ((call (car emacs-todoist-test--sync-calls))
             (commands (alist-get 'commands call)))
        (should commands)
        ;; Should include item_update.
        (should (cl-some (lambda (cmd)
                           (equal "item_update" (alist-get 'type cmd)))
                         commands))))))

(ert-deftest emacs-todoist-integration/force-push-new ()
  "Force push on a heading with no TODOIST_ID pushes as new."
  (with-org-buffer "* TODO Brand new task\n"
    (with-mock-sync nil
      (cl-letf (((symbol-function 'emacs-todoist-api-sync)
                 (lambda (_sync-token _resource-types commands callback)
                   (push (list (cons 'commands commands))
                         emacs-todoist-test--sync-calls)
                   (let* ((cmd (car commands))
                          (temp-id (alist-get 'temp_id cmd)))
                     (funcall callback
                              `((sync_token . "new-tok")
                                (temp_id_mapping . ((,temp-id . "real-new-1")))
                                (items . nil)))))))
        (emacs-todoist-push-heading)))

    (should (equal "real-new-1" (org-entry-get (point) "TODOIST_ID")))))

;; ==============================================================================
;; Force pull
;; ==============================================================================

(ert-deftest emacs-todoist-integration/force-pull ()
  "Force pull applies remote data regardless of local state."
  (with-org-buffer "* TODO Old title\nOld body.\n"
    (emacs-todoist-org-set-props
     '(("TODOIST_ID"         . "task-42")
       ("TODOIST_SYNC_TOKEN" . "some-token")))

    (with-mock-sync
        `((sync_token . "after-pull")
          (items . (((id . "task-42")
                     (content . "Remote title")
                     (description . "Remote body.")
                     (due . ((date . "2026-06-15")))
                     (checked . 0)))))
      (emacs-todoist-pull-heading))

    (should (equal "Remote title" (emacs-todoist-org-heading-title)))
    (should (equal "Remote body." (emacs-todoist-org-heading-description)))
    (should (equal "2026-06-15" (emacs-todoist-org-heading-deadline)))
    (should (equal "after-pull"
                   (org-entry-get (point) "TODOIST_SYNC_TOKEN")))))

(ert-deftest emacs-todoist-integration/force-pull-no-id-errors ()
  "Force pull on a heading without TODOIST_ID signals an error."
  (with-org-buffer "* TODO No ID task\n"
    (should-error (emacs-todoist-pull-heading) :type 'user-error)))

;; ==============================================================================
;; Logging
;; ==============================================================================

(ert-deftest emacs-todoist-integration/log-respects-level ()
  "Logging below the minimum level is suppressed."
  (let ((emacs-todoist-log-level 'info)
        (emacs-todoist-log-buffer-name "*test-todoist-log*"))
    (emacs-todoist-log 'debug "Should not appear")
    (emacs-todoist-log 'info "Should appear")
    (let ((buf (get-buffer emacs-todoist-log-buffer-name)))
      (should buf)
      (with-current-buffer buf
        (should-not (string-match-p "Should not appear" (buffer-string)))
        (should (string-match-p "Should appear" (buffer-string))))
      (kill-buffer buf))))

(ert-deftest emacs-todoist-integration/log-formats-message ()
  "Log messages include timestamp, level, and formatted text."
  (let ((emacs-todoist-log-level 'debug)
        (emacs-todoist-log-buffer-name "*test-todoist-log-fmt*"))
    (emacs-todoist-log 'info "Pushed %d tasks" 5)
    (let ((buf (get-buffer emacs-todoist-log-buffer-name)))
      (should buf)
      (with-current-buffer buf
        (should (string-match-p "\\[INFO\\]" (buffer-string)))
        (should (string-match-p "Pushed 5 tasks" (buffer-string))))
      (kill-buffer buf))))

;; ==============================================================================
;; State conversion
;; ==============================================================================

(ert-deftest emacs-todoist-integration/state-to-checked ()
  "TODO states map to the correct Todoist checked values."
  (should (= 0 (emacs-todoist--state-to-checked "TODO")))
  (should (= 1 (emacs-todoist--state-to-checked "DONE")))
  ;; Unknown state defaults to 0 (unchecked).
  (should (= 0 (emacs-todoist--state-to-checked "WAITING")))
  (should (= 0 (emacs-todoist--state-to-checked nil))))

(ert-deftest emacs-todoist-integration/checked-to-state ()
  "Todoist checked values map to the correct org TODO states."
  (should (equal "TODO" (emacs-todoist--checked-to-state 0)))
  (should (equal "DONE" (emacs-todoist--checked-to-state 1)))
  (should (equal "TODO" (emacs-todoist--checked-to-state nil))))

;; ==============================================================================
;; Sync status error detection
;; ==============================================================================

(ert-deftest emacs-todoist-integration/push-detects-sync-status-error ()
  "Pushing a heading reports failure when sync_status contains a command error.
The Todoist API can return HTTP 200 with no top-level error while
individual commands fail (e.g. invalid project_id).  Previously this
was silently ignored, leaving TODOIST_ID blank."
  (with-org-buffer "* TODO Failing task\n"
    (with-mock-sync nil
      (cl-letf (((symbol-function 'emacs-todoist-api-sync)
                 (lambda (_sync-token _resource-types commands callback)
                   (let* ((cmd (car commands))
                          (uuid (alist-get 'uuid cmd)))
                     ;; Simulate a per-command failure: sync_status
                     ;; maps the command UUID to an error object
                     ;; instead of "ok", and temp_id_mapping is empty.
                     (funcall callback
                              `((sync_token . "tok-1")
                                (sync_status . ((,uuid . ((error . "Invalid project_id")
                                                          (error_code . 22)))))
                                (temp_id_mapping . nil)
                                (items . nil)))))))
        (emacs-todoist-sync-heading)))

    ;; TODOIST_ID should NOT have been set.
    (should (null (org-entry-get (point) "TODOIST_ID")))
    ;; No hashes should have been written either.
    (should (null (org-entry-get (point) "TODOIST_LOCAL_HASH")))))

(ert-deftest emacs-todoist-integration/push-update-detects-sync-status-error ()
  "Pushing an update reports failure when sync_status contains a command error."
  (with-org-buffer "* TODO Existing task\nUpdated.\n"
    (emacs-todoist-org-set-props
     '(("TODOIST_ID"          . "task-42")
       ("TODOIST_LOCAL_HASH"  . "old-hash")
       ("TODOIST_REMOTE_HASH" . "old-remote")
       ("TODOIST_SYNC_TOKEN"  . "old-token")))

    (with-mock-sync nil
      (cl-letf (((symbol-function 'emacs-todoist-api-sync)
                 (lambda (_sync-token _resource-types commands callback)
                   (let* ((cmd (car commands))
                          (uuid (alist-get 'uuid cmd)))
                     (funcall callback
                              `((sync_token . "tok-2")
                                (sync_status . ((,uuid . ((error . "Task not found")
                                                          (error_code . 20)))))
                                (items . nil)))))))
        (emacs-todoist-push-heading)))

    ;; Hashes should NOT have been updated (still old values).
    (should (equal "old-hash" (org-entry-get (point) "TODOIST_LOCAL_HASH")))
    (should (equal "old-remote" (org-entry-get (point) "TODOIST_REMOTE_HASH")))))

(ert-deftest emacs-todoist-integration/push-errors-on-missing-temp-id-mapping ()
  "Pushing a heading errors when sync succeeds but temp_id_mapping is empty.
This catches the case where the API response is successful (all
commands have status \"ok\") but temp_id_mapping is missing — a
defensive check that shouldn't happen in practice."
  (with-org-buffer "* TODO Mysterious task\n"
    (with-mock-sync nil
      (cl-letf (((symbol-function 'emacs-todoist-api-sync)
                 (lambda (_sync-token _resource-types commands callback)
                   (let* ((cmd (car commands))
                          (uuid (alist-get 'uuid cmd)))
                     ;; sync_status says "ok" but temp_id_mapping is empty.
                     (funcall callback
                              `((sync_token . "tok-3")
                                (sync_status . ((,uuid . "ok")))
                                (temp_id_mapping . nil)
                                (items . nil)))))))
        ;; The callback should signal an error about missing ID.
        (should-error (emacs-todoist-sync-heading))))

    ;; TODOIST_ID should NOT have been set.
    (should (null (org-entry-get (point) "TODOIST_ID")))))

;; ==============================================================================
;; Check-sync-status unit tests
;; ==============================================================================

(ert-deftest emacs-todoist-integration/check-sync-status-all-ok ()
  "Returns nil when all commands succeeded."
  (should (null (emacs-todoist--check-sync-status
                 '((sync_status . ((cmd-1 . "ok") (cmd-2 . "ok"))))))))

(ert-deftest emacs-todoist-integration/check-sync-status-missing ()
  "Returns nil when sync_status is absent (read-only sync)."
  (should (null (emacs-todoist--check-sync-status
                 '((sync_token . "tok"))))))

(ert-deftest emacs-todoist-integration/check-sync-status-error-object ()
  "Returns error string when a command failed with an error object."
  (let ((result (emacs-todoist--check-sync-status
                 `((sync_status . ((cmd-1 . "ok")
                                   (cmd-2 . ((error . "Bad request")
                                             (error_code . 42)))))))))
    (should result)
    (should (string-match-p "Bad request" result))
    (should (string-match-p "42" result))))

(ert-deftest emacs-todoist-integration/check-sync-status-error-string ()
  "Returns error string when a command status is a non-\"ok\" string."
  (let ((result (emacs-todoist--check-sync-status
                 '((sync_status . ((cmd-1 . "error: rate limited")))))))
    (should result)
    (should (string-match-p "rate limited" result))))

;; ==============================================================================
;; Project name → ID resolution
;; ==============================================================================

(ert-deftest emacs-todoist-integration/project-name-resolved-to-id ()
  "Pushing a new heading resolves project name to numeric ID via cache."
  (with-org-buffer "* TODO Buy groceries\nShopping list.\n"
    (let ((emacs-todoist-default-project "Agenda")
          ;; Reset cache so ensure-projects triggers a fetch.
          (emacs-todoist--project-cache :not-fetched)
          (emacs-todoist-log-level 'error))
      ;; We mock both api-sync and api-fetch-projects.  The push flow
      ;; calls ensure-projects (which calls fetch-projects) first, then
      ;; calls api-sync to send the item_add commands.
      (let ((sync-calls nil))
        (cl-letf (((symbol-function 'emacs-todoist-api-fetch-projects)
                   (lambda (callback)
                     (funcall callback
                              `((projects . (((name . "Agenda")
                                              (id . "2349578432"))
                                             ((name . "Inbox")
                                              (id . "1111111111"))))))))
                  ((symbol-function 'emacs-todoist-api-sync)
                   (lambda (_sync-token _resource-types commands callback)
                     (push commands sync-calls)
                     (let* ((cmd (car commands))
                            (temp-id (alist-get 'temp_id cmd)))
                       (funcall callback
                                `((sync_token . "tok-resolved")
                                  (temp_id_mapping . ((,temp-id . "real-id-42")))
                                  (items . nil)))))))
          (emacs-todoist-sync-heading))

        ;; The item_add command should have the numeric project ID,
        ;; not the human-readable name.
        (should (= 1 (length sync-calls)))
        (let* ((commands (car sync-calls))
               (cmd (car commands))
               (args (alist-get 'args cmd)))
          (should (equal "item_add" (alist-get 'type cmd)))
          (should (equal "2349578432" (alist-get 'project_id args))))

        ;; TODOIST_ID should have been written back.
        (should (equal "real-id-42" (org-entry-get (point) "TODOIST_ID")))))))

(ert-deftest emacs-todoist-integration/numeric-project-id-passes-through ()
  "A project string that looks like a numeric ID passes through unchanged."
  (with-org-buffer "* TODO Buy groceries\n"
    (let ((emacs-todoist-default-project "2349578432")
          ;; Pre-populate cache with projects that don't match.
          (emacs-todoist--project-cache '(("inbox" . "1111111111")))
          (emacs-todoist-log-level 'error))
      (let ((sync-calls nil))
        (cl-letf (((symbol-function 'emacs-todoist-api-sync)
                   (lambda (_sync-token _resource-types commands callback)
                     (push commands sync-calls)
                     (let* ((cmd (car commands))
                            (temp-id (alist-get 'temp_id cmd)))
                       (funcall callback
                                `((sync_token . "tok-passthrough")
                                  (temp_id_mapping . ((,temp-id . "real-999")))
                                  (items . nil)))))))
          (emacs-todoist-sync-heading))

        ;; The numeric ID string should pass through as-is.
        (let* ((commands (car sync-calls))
               (cmd (car commands))
               (args (alist-get 'args cmd)))
          (should (equal "2349578432" (alist-get 'project_id args))))))))

(ert-deftest emacs-todoist-integration/nil-project-passes-through ()
  "When no project is configured, project_id is omitted from the command."
  (with-org-buffer "* TODO Buy groceries\n"
    (let ((emacs-todoist-default-project nil)
          (emacs-todoist--project-cache '(("inbox" . "1111111111")))
          (emacs-todoist-log-level 'error))
      (let ((sync-calls nil))
        (cl-letf (((symbol-function 'emacs-todoist-api-sync)
                   (lambda (_sync-token _resource-types commands callback)
                     (push commands sync-calls)
                     (let* ((cmd (car commands))
                            (temp-id (alist-get 'temp_id cmd)))
                       (funcall callback
                                `((sync_token . "tok-nil")
                                  (temp_id_mapping . ((,temp-id . "real-nil")))
                                  (items . nil)))))))
          (emacs-todoist-sync-heading))

        ;; project_id should be absent from the args.
        (let* ((commands (car sync-calls))
               (cmd (car commands))
               (args (alist-get 'args cmd)))
          (should (null (alist-get 'project_id args))))))))

(ert-deftest emacs-todoist-integration/project-cache-reuse ()
  "Second push reuses the project cache without re-fetching."
  (with-org-buffer "* TODO First task\n"
    (let ((emacs-todoist-default-project "Agenda")
          (emacs-todoist--project-cache :not-fetched)
          (emacs-todoist-log-level 'error)
          (fetch-count 0))
      (cl-letf (((symbol-function 'emacs-todoist-api-fetch-projects)
                 (lambda (callback)
                   (cl-incf fetch-count)
                   (funcall callback
                            `((projects . (((name . "Agenda")
                                            (id . "2349578432"))))))))
                ((symbol-function 'emacs-todoist-api-sync)
                 (lambda (_sync-token _resource-types commands callback)
                   (let* ((cmd (car commands))
                          (temp-id (alist-get 'temp_id cmd)))
                     (funcall callback
                              `((sync_token . "tok-reuse")
                                (temp_id_mapping . ((,temp-id . "real-reuse")))
                                (items . nil)))))))
        ;; First push: should fetch projects.
        (emacs-todoist-sync-heading)
        (should (= 1 fetch-count)))

      ;; Set up a second heading to push in the same buffer.
      (goto-char (point-max))
      (insert "* TODO Second task\n")
      (forward-line -1)
      (beginning-of-line)

      (cl-letf (((symbol-function 'emacs-todoist-api-fetch-projects)
                 (lambda (callback)
                   (cl-incf fetch-count)
                   (funcall callback
                            `((projects . (((name . "Agenda")
                                            (id . "2349578432"))))))))
                ((symbol-function 'emacs-todoist-api-sync)
                 (lambda (_sync-token _resource-types commands callback)
                   (let* ((cmd (car commands))
                          (temp-id (alist-get 'temp_id cmd)))
                     (funcall callback
                              `((sync_token . "tok-reuse-2")
                                (temp_id_mapping . ((,temp-id . "real-reuse-2")))
                                (items . nil)))))))
        ;; Second push: should NOT fetch projects again.
        (emacs-todoist-sync-heading)
        (should (= 1 fetch-count))))))

;;; test-integration.el ends here
