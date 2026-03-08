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
;; DONE push behavior (recurring-safe completion)
;; ==============================================================================

(ert-deftest emacs-todoist-integration/build-push-commands-done-uses-item-close ()
  "DONE pushes use item_close (not item_complete)."
  (with-org-buffer "* DONE Task\n"
    (let ((cmds (emacs-todoist--build-push-commands "task-1")))
      (should (cl-some (lambda (cmd)
                         (equal "item_close" (alist-get 'type cmd)))
                       cmds))
      (should-not (cl-some (lambda (cmd)
                             (equal "item_complete" (alist-get 'type cmd)))
                           cmds)))))

(ert-deftest emacs-todoist-integration/build-push-commands-done-no-date-only-due ()
  "DONE pushes do not send due.date-only updates."
  (with-org-buffer "* DONE Task\nDEADLINE: <2026-03-08 Sun>\n"
    (let* ((cmds (emacs-todoist--build-push-commands "task-1"))
           (update (cl-find-if (lambda (cmd)
                                 (equal "item_update" (alist-get 'type cmd)))
                               cmds))
           (args (alist-get 'args update)))
      (should update)
      (should-not (alist-get 'due args)))))

(ert-deftest emacs-todoist-integration/build-push-commands-done-recurring-sends-due-string ()
  "DONE pushes with TODOIST_DUE_STRING send due.string (and due.date when present)."
  (with-org-buffer
      "* DONE Task\nDEADLINE: <2026-03-08 Sun>\n:PROPERTIES:\n:TODOIST_DUE_STRING: every day\n:END:\n"
    (let* ((cmds (emacs-todoist--build-push-commands "task-1"))
           (update (cl-find-if (lambda (cmd)
                                 (equal "item_update" (alist-get 'type cmd)))
                               cmds))
           (due (alist-get 'due (alist-get 'args update))))
      (should update)
      (should (equal "every day" (alist-get 'string due)))
      (should (equal "2026-03-08" (alist-get 'date due))))))

(ert-deftest emacs-todoist-integration/push-done-reconciles-from-response-item ()
  "DONE push applies returned remote item state without extra fetch."
  (with-org-buffer
      "* DONE Recurring task\nDEADLINE: <2026-03-08 Sun>\n:PROPERTIES:\n:TODOIST_ID: task-1\n:TODOIST_DUE_STRING: every day\n:TODOIST_SYNC_TOKEN: tok-0\n:END:\n"
    (let ((call-count 0)
          (action-called nil)
          (emacs-todoist-on-done-action (lambda (_marker)
                                          (setq action-called t))))
      (cl-letf (((symbol-function 'emacs-todoist-api-sync)
                 (lambda (_sync-token _resource-types commands callback)
                   (cl-incf call-count)
                   (should commands)
                   (funcall callback
                            '((sync_token . "tok-push")
                              (items . (((id . "task-1")
                                         (content . "Recurring task")
                                         (description . "")
                                         (due . ((date . "2026-03-09")
                                                 (string . "every day")
                                                 (is_recurring . t)))
                                         (checked . 0)))))))))
        (emacs-todoist-push-heading))
      (should (= 1 call-count))
      (should (equal "TODO" (org-get-todo-state)))
      (should (equal "2026-03-09" (emacs-todoist-org-heading-deadline)))
      (should (equal "every day" (org-entry-get (point) "TODOIST_DUE_STRING")))
      (should (equal "tok-push" (org-entry-get (point) "TODOIST_SYNC_TOKEN")))
      (should-not action-called))))

(ert-deftest emacs-todoist-integration/push-done-reconcile-fallback-fetch ()
  "DONE push fetches full state once when response omits the pushed item."
  (with-org-buffer
      "* DONE Recurring task\nDEADLINE: <2026-03-08 Sun>\n:PROPERTIES:\n:TODOIST_ID: task-1\n:TODOIST_DUE_STRING: every day\n:TODOIST_SYNC_TOKEN: tok-0\n:END:\n"
    (let ((calls '()))
      (cl-letf
          (((symbol-function 'emacs-todoist-api-sync)
            (lambda (sync-token _resource-types commands callback)
              (push (list sync-token commands) calls)
              (if commands
                  (funcall callback
                           '((sync_token . "tok-push")
                             (items . nil)))
                (funcall callback
                         '((sync_token . "tok-fetch")
                           (items . (((id . "task-1")
                                      (content . "Recurring task")
                                      (description . "")
                                      (due . ((date . "2026-03-09")
                                              (string . "every day")
                                              (is_recurring . t)))
                                      (checked . 0))))))))))
        (emacs-todoist-push-heading))
      ;; One push call plus one fallback fetch call.
      (should (= 2 (length calls)))
      (should (equal "*" (caar calls)))
      (should (null (cadar calls)))
      (should (equal "TODO" (org-get-todo-state)))
      (should (equal "2026-03-09" (emacs-todoist-org-heading-deadline)))
      (should (equal "tok-fetch" (org-entry-get (point) "TODOIST_SYNC_TOKEN"))))))

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

(ert-deftest emacs-todoist-integration/neither-changed-ignores-description-edge-whitespace ()
  "Remote description edge whitespace does not count as a change."
  (with-org-buffer "* TODO Buy groceries\nBody text\n"
    (let* ((local-hash (emacs-todoist-org-heading-local-hash))
           (stored-remote-item
            '((content . "Buy groceries")
              (description . "Body text")
              (due)
              (checked . 0)))
           (remote-hash (emacs-todoist-api-hash-item stored-remote-item))
           (pull-called nil))
      (emacs-todoist-org-set-props
       `(("TODOIST_ID"          . "task-42")
         ("TODOIST_LOCAL_HASH"  . ,local-hash)
         ("TODOIST_REMOTE_HASH" . ,remote-hash)
         ("TODOIST_SYNC_TOKEN"  . "old-token")))
      (cl-letf (((symbol-function 'emacs-todoist--apply-pull)
                 (lambda (&rest _args)
                   (setq pull-called t)))
                ((symbol-function 'emacs-todoist-api-sync)
                 (lambda (_sync-token _resource-types commands callback)
                   (push (list (cons 'commands commands))
                         emacs-todoist-test--sync-calls)
                   (funcall callback
                            '((sync_token . "updated-token")
                              (items . (((id . "task-42")
                                         (content . "Buy groceries")
                                         (description . "\n  Body text \n")
                                         (due)
                                         (checked . 0)))))))))
        (setq emacs-todoist-test--sync-calls nil)
        (emacs-todoist-sync-heading))
      (should-not pull-called)
      (should (= 1 (length emacs-todoist-test--sync-calls)))
      (should (null (alist-get 'commands (car emacs-todoist-test--sync-calls))))
      (should (equal "updated-token" (org-entry-get (point) "TODOIST_SYNC_TOKEN"))))))

(ert-deftest emacs-todoist-integration/neither-changed-ignores-local-text-properties ()
  "Local text properties on title/state do not trigger false conflicts."
  (with-org-buffer "* TODO Buy groceries\nSame as before.\n"
    (let* ((local-hash (emacs-todoist-org-heading-local-hash))
           (remote-item `((content . "Buy groceries")
                          (description . "Same as before.")
                          (due)
                          (checked . 0)))
           (remote-hash (emacs-todoist-api-hash-item remote-item))
           (conflict-prompted nil)
           (propertized-title (copy-sequence "Buy groceries"))
           (propertized-state (copy-sequence "TODO")))
      (add-text-properties 0 (length propertized-title) '(face org-level-2)
                           propertized-title)
      (add-text-properties 0 (length propertized-state) '(face org-todo)
                           propertized-state)
      (emacs-todoist-org-set-props
       `(("TODOIST_ID"          . "task-42")
         ("TODOIST_LOCAL_HASH"  . ,local-hash)
         ("TODOIST_REMOTE_HASH" . ,remote-hash)
         ("TODOIST_SYNC_TOKEN"  . "old-token")))
      (cl-letf (((symbol-function 'emacs-todoist-org-heading-title)
                 (lambda () propertized-title))
                ((symbol-function 'emacs-todoist-org-heading-todo-state)
                 (lambda () propertized-state))
                ((symbol-function 'read-char-choice)
                 (lambda (&rest _args)
                   (setq conflict-prompted t)
                   ?l))
                ((symbol-function 'emacs-todoist-api-sync)
                 (lambda (_sync-token _resource-types _commands callback)
                   (funcall callback
                            `((sync_token . "updated-token")
                              (items . (((id . "task-42")
                                         (content . "Buy groceries")
                                         (description . "Same as before.")
                                         (due)
                                         (checked . 0)))))))))
        (emacs-todoist-sync-heading))
      (should-not conflict-prompted)
      (should (equal "updated-token" (org-entry-get (point) "TODOIST_SYNC_TOKEN"))))))

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

(ert-deftest emacs-todoist-integration/sync-heading-conflict-logs-both-versions ()
  "Conflict logging includes local and remote versions for single sync."
  (with-org-buffer "* TODO Local title\nLocal body\n"
    (let ((captured-logs nil)
          (pushed nil))
      (emacs-todoist-org-set-props
       '(("TODOIST_ID" . "task-42")
         ("TODOIST_LOCAL_HASH" . "stale-local")
         ("TODOIST_REMOTE_HASH" . "stale-remote")
         ("TODOIST_SYNC_TOKEN" . "tok-0")))
      (cl-letf (((symbol-function 'emacs-todoist-log)
                 (lambda (_level fmt &rest args)
                   (push (apply #'format fmt args) captured-logs)))
                ((symbol-function 'emacs-todoist-api-sync)
                 (lambda (_sync-token _resource-types _commands callback)
                   (funcall callback
                            '((sync_token . "tok-1")
                              (items . (((id . "task-42")
                                         (content . "Remote title")
                                         (description . "\nRemote body\n")
                                         (due . ((date . "2026-04-01")))
                                         (checked . 1))))))))
                ((symbol-function 'read-char-choice)
                 (lambda (_prompt _chars) ?l))
                ((symbol-function 'emacs-todoist--push-update)
                 (lambda (&rest _args)
                   (setq pushed t))))
        (emacs-todoist-sync-heading))
      (should pushed)
      (let ((combined (mapconcat #'identity (nreverse captured-logs) "\n")))
        (should (string-match-p "Conflict detected (single) for TODOIST_ID=task-42" combined))
        (should (string-match-p "title: local=\"Local title\" remote=\"Remote title\"" combined))
        (should (string-match-p "description: local=\"Local body\" remote=\"" combined))
        (should (string-match-p "Remote body" combined))
        (should (string-match-p "deadline: local=nil remote=\"2026-04-01\"" combined))
        (should (string-match-p "state: local=\"TODO\" remote=\"DONE\"" combined))))))

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
;; Recurrence command
;; ==============================================================================

(ert-deftest emacs-todoist-integration/set-recurrence-updates-property ()
  "set-recurrence writes TODOIST_DUE_STRING on the current heading."
  (with-org-buffer "* TODO Task\n"
    (emacs-todoist-set-recurrence "every weekday")
    (should (equal "every weekday"
                   (org-entry-get (point) "TODOIST_DUE_STRING")))))

(ert-deftest emacs-todoist-integration/set-recurrence-empty-clears-property ()
  "Empty set-recurrence input clears TODOIST_DUE_STRING."
  (with-org-buffer "* TODO Task\n:PROPERTIES:\n:TODOIST_DUE_STRING: every day\n:END:\n"
    (emacs-todoist-set-recurrence "   ")
    (should-not (org-entry-get (point) "TODOIST_DUE_STRING"))))

(ert-deftest emacs-todoist-integration/set-recurrence-linked-no-sync ()
  "On linked headings, set-recurrence does not auto-sync."
  (with-org-buffer "* TODO Task\n:PROPERTIES:\n:TODOIST_ID: task-1\n:END:\n"
    (let ((sync-called nil))
      (cl-letf (((symbol-function 'emacs-todoist-sync-heading)
                 (lambda () (setq sync-called t))))
        (emacs-todoist-set-recurrence "every month"))
      (should-not sync-called))))

(ert-deftest emacs-todoist-integration/set-recurrence-unlinked-no-sync ()
  "On unlinked headings, set-recurrence does not trigger sync."
  (with-org-buffer "* TODO Task\n"
    (let ((sync-called nil))
      (cl-letf (((symbol-function 'emacs-todoist-sync-heading)
                 (lambda () (setq sync-called t))))
        (emacs-todoist-set-recurrence "every month"))
      (should-not sync-called))))

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

;; ==============================================================================
;; Bulk sync (sync-buffer)
;; ==============================================================================

(ert-deftest emacs-todoist-integration/sync-buffer-all-same-token-incremental ()
  "When all headings share the same sync token, uses it for an incremental fetch."
  (with-org-buffer
      (concat "* TODO H1\n:PROPERTIES:\n:TODOIST_ID: t1\n"
              ":TODOIST_SYNC_TOKEN: tok-A\n:TODOIST_LOCAL_HASH: x\n"
              ":TODOIST_REMOTE_HASH: y\n:END:\n"
              "* TODO H2\n:PROPERTIES:\n:TODOIST_ID: t2\n"
              ":TODOIST_SYNC_TOKEN: tok-A\n:TODOIST_LOCAL_HASH: x\n"
              ":TODOIST_REMOTE_HASH: y\n:END:\n")
    (let ((emacs-todoist-log-level 'error))
      (let ((fetch-token nil))
        (cl-letf (((symbol-function 'emacs-todoist-api-sync)
                   (lambda (sync-token _resource-types commands callback)
                     (when (null commands)
                       (setq fetch-token sync-token))
                     (funcall callback
                              `((sync_token . "tok-B")
                                (items . nil))))))
          (emacs-todoist-sync-buffer))
        ;; Should have used the shared token, not "*".
        (should (equal "tok-A" fetch-token))))))

(ert-deftest emacs-todoist-integration/sync-buffer-mixed-tokens-full-sync ()
  "When headings have different sync tokens, uses \"*\" for a full sync."
  (with-org-buffer
      (concat "* TODO H1\n:PROPERTIES:\n:TODOIST_ID: t1\n"
              ":TODOIST_SYNC_TOKEN: tok-A\n:END:\n"
              "* TODO H2\n:PROPERTIES:\n:TODOIST_ID: t2\n"
              ":TODOIST_SYNC_TOKEN: tok-B\n:END:\n")
    ;; Store matching local hashes so headings appear locally unchanged
    ;; (we only care about which token is used for the fetch).
    (goto-char (point-min))
    (re-search-forward "^\\* TODO H1") (beginning-of-line)
    (org-entry-put (point) "TODOIST_LOCAL_HASH"
                   (emacs-todoist-org-heading-local-hash))
    (re-search-forward "^\\* TODO H2") (beginning-of-line)
    (org-entry-put (point) "TODOIST_LOCAL_HASH"
                   (emacs-todoist-org-heading-local-hash))
    (let ((emacs-todoist-log-level 'error))
      (let ((fetch-token nil))
        (cl-letf (((symbol-function 'emacs-todoist-api-sync)
                   (lambda (sync-token _resource-types _commands callback)
                     (when (null fetch-token)
                       (setq fetch-token sync-token))
                     ;; Return both items so full sync doesn't trigger
                     ;; deletion prompts.
                     (funcall callback
                              `((sync_token . "tok-C")
                                (items . (((id . "t1") (content . "H1")
                                           (description . "") (due) (checked . 0))
                                          ((id . "t2") (content . "H2")
                                           (description . "") (due) (checked . 0)))))))))
          (emacs-todoist-sync-buffer))
        (should (equal "*" fetch-token))))))

(ert-deftest emacs-todoist-integration/sync-buffer-no-entries ()
  "Sync-buffer with no synced headings messages 'no headings to sync'."
  (with-org-buffer "* TODO Plain heading\n* Another plain\n"
    (let ((emacs-todoist-log-level 'error)
          (msg nil))
      (cl-letf (((symbol-function 'message)
                 (lambda (fmt &rest args) (setq msg (apply #'format fmt args)))))
        (emacs-todoist-sync-buffer))
      (should (string-match-p "no headings" msg)))))

(ert-deftest emacs-todoist-integration/sync-buffer-mix-push-pull-skip ()
  "Sync-buffer classifies headings correctly: push, pull, and skip."
  (with-org-buffer
      ;; H1: local changed (stale local hash) → push
      ;; H2: remote changed → pull
      ;; H3: neither changed → skip
      (concat "* TODO H1 local-changed\n:PROPERTIES:\n:TODOIST_ID: t1\n"
              ":TODOIST_SYNC_TOKEN: tok-X\n:TODOIST_LOCAL_HASH: stale\n"
              ":TODOIST_REMOTE_HASH: r1\n:END:\n"
              "* TODO H2 remote-changed\n:PROPERTIES:\n:TODOIST_ID: t2\n"
              ":TODOIST_SYNC_TOKEN: tok-X\n:TODOIST_REMOTE_HASH: stale-remote\n"
              ":END:\n"
              "* TODO H3 unchanged\n:PROPERTIES:\n:TODOIST_ID: t3\n"
              ":TODOIST_SYNC_TOKEN: tok-X\n:END:\n")
    ;; Compute and store matching hashes for H2 (local unchanged) and H3.
    (goto-char (point-min))
    (re-search-forward "^\\* TODO H2")
    (beginning-of-line)
    (org-entry-put (point) "TODOIST_LOCAL_HASH"
                   (emacs-todoist-org-heading-local-hash))
    (re-search-forward "^\\* TODO H3")
    (beginning-of-line)
    (org-entry-put (point) "TODOIST_LOCAL_HASH"
                   (emacs-todoist-org-heading-local-hash))
    ;; H3 remote hash must match what the API returns.
    (let* ((h3-remote `((content . "H3 unchanged")
                         (description . "")
                         (due) (checked . 0)))
           (h3-hash (emacs-todoist-api-hash-item h3-remote)))
      (org-entry-put (point) "TODOIST_REMOTE_HASH" h3-hash))

    (let ((emacs-todoist-log-level 'error)
          (push-commands nil))
      (cl-letf (((symbol-function 'emacs-todoist-api-sync)
                 (lambda (_sync-token _resource-types commands callback)
                   (if (null commands)
                       ;; Fetch call: return items for t2 (changed) and t3 (unchanged).
                       (funcall callback
                                `((sync_token . "tok-Y")
                                  (items . (((id . "t2")
                                             (content . "H2 UPDATED remotely")
                                             (description . "")
                                             (due) (checked . 0))
                                            ((id . "t3")
                                             (content . "H3 unchanged")
                                             (description . "")
                                             (due) (checked . 0))))))
                     ;; Push call.
                     (setq push-commands commands)
                     (funcall callback
                              `((sync_token . "tok-Z")
                                (items . nil)))))))
        (emacs-todoist-sync-buffer))

      ;; H1 should have been pushed (item_update in commands).
      (should push-commands)
      (should (cl-some (lambda (cmd)
                         (and (equal "item_update" (alist-get 'type cmd))
                              (equal "t1" (alist-get 'id (alist-get 'args cmd)))))
                       push-commands))

      ;; H2 should have been pulled (title updated).
      (goto-char (point-min))
      (re-search-forward "^\\* TODO H2")
      (beginning-of-line)
      (should (equal "H2 UPDATED remotely" (emacs-todoist-org-heading-title)))

      ;; H3 should be unchanged.
      (re-search-forward "^\\* TODO H3")
      (beginning-of-line)
      (should (equal "H3 unchanged" (emacs-todoist-org-heading-title))))))

(ert-deftest emacs-todoist-integration/sync-buffer-batch-push-single-call ()
  "All update + add commands go in a single API call."
  (with-org-buffer
      (concat "* TODO Existing\n:PROPERTIES:\n:TODOIST_ID: t1\n"
              ":TODOIST_SYNC_TOKEN: tok-A\n:TODOIST_LOCAL_HASH: stale\n"
              ":TODOIST_REMOTE_HASH: r1\n:END:\n")
    (let ((emacs-todoist-log-level 'error)
          (api-call-count 0))
      (cl-letf (((symbol-function 'emacs-todoist-api-sync)
                 (lambda (_sync-token _resource-types commands callback)
                   (cl-incf api-call-count)
                   (funcall callback
                            `((sync_token . "tok-final")
                              (items . nil))))))
        (emacs-todoist-sync-buffer))
      ;; Should be exactly 2 calls: one fetch, one push.
      (should (= 2 api-call-count)))))

(ert-deftest emacs-todoist-integration/sync-buffer-updates-token-on-all-headings ()
  "After sync, all headings get the new sync token."
  (with-org-buffer
      (concat "* TODO H1\n:PROPERTIES:\n:TODOIST_ID: t1\n"
              ":TODOIST_SYNC_TOKEN: old\n:END:\n"
              "* TODO H2\n:PROPERTIES:\n:TODOIST_ID: t2\n"
              ":TODOIST_SYNC_TOKEN: old\n:END:\n")
    ;; Store matching local hashes so headings appear unchanged.
    (goto-char (point-min))
    (re-search-forward "^\\* TODO H1") (beginning-of-line)
    (org-entry-put (point) "TODOIST_LOCAL_HASH"
                   (emacs-todoist-org-heading-local-hash))
    (re-search-forward "^\\* TODO H2") (beginning-of-line)
    (org-entry-put (point) "TODOIST_LOCAL_HASH"
                   (emacs-todoist-org-heading-local-hash))

    (let ((emacs-todoist-log-level 'error))
      (cl-letf (((symbol-function 'emacs-todoist-api-sync)
                 (lambda (_sync-token _resource-types _commands callback)
                   (funcall callback
                            `((sync_token . "new-tok")
                              (items . nil))))))
        (emacs-todoist-sync-buffer)))

    ;; Both headings should have the new token.
    (goto-char (point-min))
    (re-search-forward "^\\* TODO H1") (beginning-of-line)
    (should (equal "new-tok" (org-entry-get (point) "TODOIST_SYNC_TOKEN")))
    (re-search-forward "^\\* TODO H2") (beginning-of-line)
    (should (equal "new-tok" (org-entry-get (point) "TODOIST_SYNC_TOKEN")))))

(ert-deftest emacs-todoist-integration/sync-buffer-with-prefix-pushes-new-headings ()
  "With prefix arg, sync-buffer pushes new TODO headings without TODOIST_ID."
  (with-org-buffer "* TODO Brand new task\nSome description.\n"
    (let ((emacs-todoist-log-level 'error)
          (emacs-todoist--project-cache '(("inbox" . "111")))
          (pushed-commands nil))
      (cl-letf (((symbol-function 'emacs-todoist-api-sync)
                 (lambda (_sync-token _resource-types commands callback)
                   (when commands
                     (setq pushed-commands commands))
                   (let* ((cmd (car commands))
                          (temp-id (and cmd (alist-get 'temp_id cmd))))
                     (funcall callback
                              `((sync_token . "tok-new")
                                (temp_id_mapping
                                 . ,(when temp-id
                                      `((,temp-id . "real-new-1"))))
                                (items . nil)))))))
        ;; Pass non-nil for include-new (simulating C-u).
        (emacs-todoist-sync-buffer t))

      ;; Should have sent item_add.
      (should pushed-commands)
      (should (cl-some (lambda (cmd)
                         (equal "item_add" (alist-get 'type cmd)))
                       pushed-commands))
      ;; ID should be written back.
      (should (equal "real-new-1" (org-entry-get (point) "TODOIST_ID"))))))

(ert-deftest emacs-todoist-integration/sync-buffer-new-children-not-duplicated ()
  "Children of new headings are pushed only once (via parent), not independently."
  (with-org-buffer
      (concat "* TODO Parent task\n"
              "** TODO Child task\n")
    (let ((emacs-todoist-log-level 'error)
          (emacs-todoist--project-cache '(("inbox" . "111")))
          (pushed-commands nil))
      (cl-letf (((symbol-function 'emacs-todoist-api-sync)
                 (lambda (_sync-token _resource-types commands callback)
                   (when commands
                     (setq pushed-commands commands))
                   ;; Build temp_id_mapping for all item_add commands.
                   (let ((mapping nil)
                         (counter 0))
                     (dolist (cmd commands)
                       (when (equal "item_add" (alist-get 'type cmd))
                         (let ((tid (alist-get 'temp_id cmd)))
                           (push (cons tid (format "real-%d" (cl-incf counter)))
                                 mapping))))
                     (funcall callback
                              `((sync_token . "tok-new")
                                (temp_id_mapping . ,mapping)
                                (items . nil)))))))
        (emacs-todoist-sync-buffer t))

      ;; Should have exactly 2 item_add commands: one parent, one child.
      (let ((add-cmds (cl-remove-if-not
                       (lambda (cmd)
                         (equal "item_add" (alist-get 'type cmd)))
                       pushed-commands)))
        (should (= 2 (length add-cmds)))
        ;; The child should reference the parent via parent_id.
        (let* ((parent-cmd (cl-find-if
                            (lambda (cmd)
                              (equal "Parent task"
                                     (alist-get 'content (alist-get 'args cmd))))
                            add-cmds))
               (child-cmd (cl-find-if
                           (lambda (cmd)
                             (equal "Child task"
                                    (alist-get 'content (alist-get 'args cmd))))
                           add-cmds)))
          (should parent-cmd)
          (should child-cmd)
          (should (equal (alist-get 'temp_id parent-cmd)
                         (alist-get 'parent_id (alist-get 'args child-cmd)))))))))

(ert-deftest emacs-todoist-integration/sync-buffer-without-prefix-skips-new-headings ()
  "Without prefix arg, sync-buffer skips headings without TODOIST_ID."
  (with-org-buffer "* TODO Brand new task\n"
    (let ((emacs-todoist-log-level 'error)
          (msg nil))
      (cl-letf (((symbol-function 'message)
                 (lambda (fmt &rest args) (setq msg (apply #'format fmt args)))))
        (emacs-todoist-sync-buffer))
      ;; No TODOIST_ID headings + no prefix → nothing to sync.
      (should (string-match-p "no headings" msg))
      (should (null (org-entry-get (point) "TODOIST_ID"))))))

(ert-deftest emacs-todoist-integration/sync-buffer-deletion-on-full-sync ()
  "On full sync, a missing task triggers deletion handling."
  (with-org-buffer
      (concat "* TODO Present task\n:PROPERTIES:\n:TODOIST_ID: t1\n"
              ":TODOIST_SYNC_TOKEN: *\n:TODOIST_LOCAL_HASH: h\n"
              ":TODOIST_REMOTE_HASH: r\n:END:\n"
              "* TODO Deleted task\n:PROPERTIES:\n:TODOIST_ID: t2\n"
              ":TODOIST_SYNC_TOKEN: *\n:TODOIST_LOCAL_HASH: h\n"
              ":TODOIST_REMOTE_HASH: r\n:END:\n")
    (let ((emacs-todoist-log-level 'error)
          (deletion-prompted nil))
      (cl-letf (((symbol-function 'emacs-todoist-api-sync)
                 (lambda (_sync-token _resource-types _commands callback)
                   ;; Full sync returns only t1, not t2.
                   (funcall callback
                            `((sync_token . "tok-del")
                              (items . (((id . "t1")
                                         (content . "Present task")
                                         (description . "")
                                         (due) (checked . 0))))))))
                ;; Mock deletion handler to choose "keep & unlink".
                ((symbol-function 'read-char-choice)
                 (lambda (_prompt _chars)
                   (setq deletion-prompted t)
                   ?k)))
        (emacs-todoist-sync-buffer))
      ;; Should have prompted for the deleted task.
      (should deletion-prompted)
      ;; t2 should be unlinked (no TODOIST_ID).
      (goto-char (point-min))
      (re-search-forward "^\\* TODO Deleted")
      (beginning-of-line)
      (should (null (org-entry-get (point) "TODOIST_ID"))))))

(ert-deftest emacs-todoist-integration/sync-buffer-conflict-logs-both-versions ()
  "Bulk conflict logging includes local and remote versions."
  (with-org-buffer
      (concat "* TODO Local title\n:PROPERTIES:\n:TODOIST_ID: task-42\n"
              ":TODOIST_LOCAL_HASH: stale-local\n:TODOIST_REMOTE_HASH: stale-remote\n"
              ":TODOIST_SYNC_TOKEN: tok-0\n:END:\nLocal body\n")
    (let ((captured-logs nil))
      (cl-letf (((symbol-function 'emacs-todoist-log)
                 (lambda (_level fmt &rest args)
                   (push (apply #'format fmt args) captured-logs)))
                ((symbol-function 'emacs-todoist-api-sync)
                 (lambda (_sync-token _resource-types commands callback)
                   (if commands
                       (funcall callback '((sync_token . "tok-push") (items . nil)))
                     (funcall callback
                              '((sync_token . "tok-1")
                                (items . (((id . "task-42")
                                           (content . "Remote title")
                                           (description . "\nRemote body\n")
                                           (due . ((date . "2026-04-01")))
                                           (checked . 1)))))))))
                ((symbol-function 'read-char-choice)
                 (lambda (_prompt _chars) ?l))
                ((symbol-function 'emacs-todoist--build-push-commands)
                 (lambda (_todoist-id) nil)))
        (emacs-todoist-sync-buffer))
      (let ((combined (mapconcat #'identity (nreverse captured-logs) "\n")))
        (should (string-match-p "Conflict detected (bulk) for TODOIST_ID=task-42" combined))
        (should (string-match-p "title: local=\"Local title\" remote=\"Remote title\"" combined))
        (should (string-match-p "description: local=\"Local body\" remote=\"" combined))
        (should (string-match-p "Remote body" combined))
        (should (string-match-p "deadline: local=nil remote=\"2026-04-01\"" combined))
        (should (string-match-p "state: local=\"TODO\" remote=\"DONE\"" combined))))))

(ert-deftest emacs-todoist-integration/sync-buffer-new-heading-ids-written-back ()
  "New headings get their real IDs from temp_id_mapping after bulk push."
  (with-org-buffer
      (concat "* TODO New parent\n"
              "** TODO New child\n")
    (let ((emacs-todoist-log-level 'error)
          (emacs-todoist--project-cache '(("inbox" . "111"))))
      (cl-letf (((symbol-function 'emacs-todoist-api-sync)
                 (lambda (_sync-token _resource-types commands callback)
                   ;; Map all temp_ids to sequential real IDs.
                   (let ((mapping nil)
                         (counter 500))
                     (dolist (cmd commands)
                       (when-let* ((tid (alist-get 'temp_id cmd)))
                         (push (cons tid (format "real-%d" counter)) mapping)
                         (cl-incf counter)))
                     (funcall callback
                              `((sync_token . "tok-ids")
                                (temp_id_mapping . ,mapping)
                                (items . nil)))))))
        (emacs-todoist-sync-buffer t))

      ;; Parent should have an ID.
      (goto-char (point-min))
      (re-search-forward "^\\* TODO New parent") (beginning-of-line)
      (should (org-entry-get (point) "TODOIST_ID"))
      (should (string-prefix-p "real-" (org-entry-get (point) "TODOIST_ID")))
      ;; Child should have an ID.
      (re-search-forward "^\\*\\* TODO New child") (beginning-of-line)
      (should (org-entry-get (point) "TODOIST_ID"))
      (should (string-prefix-p "real-" (org-entry-get (point) "TODOIST_ID"))))))

;; ==============================================================================
;; Sync heading with children — remote completion
;; ==============================================================================

(ert-deftest emacs-todoist-integration/sync-parent-completed-remotely-no-conflict ()
  "Syncing a parent completed remotely should pull cleanly, not report a conflict.
Reproduces a bug where syncing a parent with a child heading falsely
detected a conflict (local-changed was true) even though the org buffer
was unmodified.  Also verifies that children are synced before the
parent so that `org-enforce-todo-dependencies' does not block the
parent's state change."
  (with-org-buffer "* TODO test1\n** TODO test2\n"
    ;; Enable the blocker hook that org-enforce-todo-dependencies uses.
    ;; Setting the variable alone doesn't activate the :set function in
    ;; batch mode, so we add the hook directly.
    (add-hook 'org-blocker-hook
              #'org-block-todo-from-children-or-siblings-or-parent)
    ;; Simulate initial push: write properties as if both headings were
    ;; already synced to Todoist.
    (let* ((parent-local-hash (emacs-todoist-org-heading-local-hash))
           (parent-remote-item `((content . "test1")
                                 (description . "")
                                 (due . nil)
                                 (checked . 0)))
           (parent-remote-hash (emacs-todoist-api-hash-item parent-remote-item)))
      (emacs-todoist-org-set-props
       `(("TODOIST_ID"          . "parent-1")
         ("TODOIST_LOCAL_HASH"  . ,parent-local-hash)
         ("TODOIST_REMOTE_HASH" . ,parent-remote-hash)
         ("TODOIST_SYNC_TOKEN"  . "tok-0")))
      ;; Also set up the child heading.
      (save-excursion
        (org-goto-first-child)
        (let* ((child-local-hash (emacs-todoist-org-heading-local-hash))
               (child-remote-item `((content . "test2")
                                    (description . "")
                                    (due . nil)
                                    (checked . 0)))
               (child-remote-hash (emacs-todoist-api-hash-item child-remote-item)))
          (emacs-todoist-org-set-props
           `(("TODOIST_ID"          . "child-1")
             ("TODOIST_LOCAL_HASH"  . ,child-local-hash)
             ("TODOIST_REMOTE_HASH" . ,child-remote-hash)
             ("TODOIST_SYNC_TOKEN"  . "tok-0"))))))

    ;; Now verify the local hash is still consistent (the bug is that
    ;; writing child properties causes parent's local hash to change).
    (let ((current-local-hash (emacs-todoist-org-heading-local-hash))
          (stored-local-hash (org-entry-get (point) "TODOIST_LOCAL_HASH")))
      (should (equal current-local-hash stored-local-hash)))

    ;; Mock: remote returns parent as completed (checked=1).
    (let ((conflict-prompted nil))
      (with-mock-sync nil
        (cl-letf (((symbol-function 'emacs-todoist-api-sync)
                   (lambda (sync-token _resource-types commands callback)
                     (push (list (cons 'sync-token sync-token)
                                 (cons 'commands commands))
                           emacs-todoist-test--sync-calls)
                     ;; Todoist completes children when parent is completed,
                     ;; so the response includes both items.
                     (funcall callback
                              `((sync_token . "tok-1")
                                (items . (((id . "parent-1")
                                           (content . "test1")
                                           (description . "")
                                           (due . nil)
                                           (checked . 1))
                                          ((id . "child-1")
                                           (content . "test2")
                                           (description . "")
                                           (due . nil)
                                           (checked . 1))))))))
                  ;; Intercept read-char-choice to detect false conflict.
                  ((symbol-function 'read-char-choice)
                   (lambda (_prompt _chars)
                     (setq conflict-prompted t)
                     ?r)))
          (emacs-todoist-sync-heading))

        ;; No conflict should have been prompted.
        (should-not conflict-prompted))

      ;; Parent should now be DONE.
      (should (equal "DONE" (org-get-todo-state)))
      ;; Child should also be DONE (cascaded from Todoist).
      (save-excursion
        (org-goto-first-child)
        (should (equal "DONE" (org-get-todo-state))))
      ;; Sync token should be updated on both headings.
      (should (equal "tok-1" (org-entry-get (point) "TODOIST_SYNC_TOKEN"))))))

(ert-deftest emacs-todoist-integration/pull-parent-preserves-child-properties ()
  "Pulling remote changes to parent must not remove child heading properties.
Reproduces a bug where `emacs-todoist-org-apply-remote' (via
`--replace-body') clobbered the child heading's property drawer."
  (with-org-buffer "* TODO test1\n** TODO test2\n"
    ;; Set up both headings as synced.
    (emacs-todoist-org-set-props
     '(("TODOIST_ID"          . "parent-1")
       ("TODOIST_LOCAL_HASH"  . "hash-p")
       ("TODOIST_REMOTE_HASH" . "hash-p-remote")
       ("TODOIST_SYNC_TOKEN"  . "tok-0")))
    (save-excursion
      (org-goto-first-child)
      (emacs-todoist-org-set-props
       '(("TODOIST_ID"          . "child-1")
         ("TODOIST_LOCAL_HASH"  . "hash-c")
         ("TODOIST_REMOTE_HASH" . "hash-c-remote")
         ("TODOIST_SYNC_TOKEN"  . "tok-0"))))

    ;; Apply a remote pull to the parent (completing it).
    (emacs-todoist-org-apply-remote
     '((content . "test1")
       (description . "")
       (due . nil)
       (checked . 1)))

    ;; Parent should be DONE.
    (should (equal "DONE" (org-get-todo-state)))

    ;; Child heading must still exist and retain all its properties.
    (save-excursion
      (should (org-goto-first-child))
      (should (equal "test2" (emacs-todoist-org-heading-title)))
      (should (equal "child-1" (org-entry-get (point) "TODOIST_ID")))
      (should (equal "hash-c" (org-entry-get (point) "TODOIST_LOCAL_HASH")))
      (should (equal "hash-c-remote" (org-entry-get (point) "TODOIST_REMOTE_HASH")))
      (should (equal "tok-0" (org-entry-get (point) "TODOIST_SYNC_TOKEN"))))))

;; ==============================================================================
;; Frontend usability polish
;; ==============================================================================

(ert-deftest emacs-todoist-integration/on-done-delete-properties-after-push ()
  "DONE headings can clear Todoist properties after a successful push."
  (with-org-buffer "* DONE Task\n"
    (let ((emacs-todoist-on-done-action 'delete-properties))
      (emacs-todoist-org-set-props
       '(("TODOIST_ID" . "task-1")
         ("TODOIST_LOCAL_HASH" . "stale")
         ("TODOIST_REMOTE_HASH" . "remote-old")
         ("TODOIST_SYNC_TOKEN" . "tok-0")))
      (with-mock-sync nil
        (cl-letf (((symbol-function 'emacs-todoist-api-sync)
                   (lambda (_sync-token _resource-types commands callback)
                     (if (null commands)
                         (funcall callback
                                  '((sync_token . "tok-fetch")
                                    (items . nil)))
                       (funcall callback
                                '((sync_token . "tok-push")
                                  (items . nil)))))))
          (emacs-todoist-sync-heading)))
      (should (equal "DONE" (org-get-todo-state)))
      (should-not (org-entry-get (point) "TODOIST_ID"))
      (should-not (org-entry-get (point) "TODOIST_LOCAL_HASH"))
      (should-not (org-entry-get (point) "TODOIST_REMOTE_HASH"))
      (should-not (org-entry-get (point) "TODOIST_SYNC_TOKEN")))))

(ert-deftest emacs-todoist-integration/on-done-delete-heading-after-pull ()
  "DONE headings can be deleted after a successful pull."
  (with-org-buffer "* TODO Task\n"
    (let* ((local-hash (emacs-todoist-org-heading-local-hash))
           (remote-hash (emacs-todoist-api-hash-item
                         '((content . "Task")
                           (description . "")
                           (due . nil)
                           (checked . 0))))
           (emacs-todoist-on-done-action 'delete-heading))
      (emacs-todoist-org-set-props
       `(("TODOIST_ID" . "task-1")
         ("TODOIST_LOCAL_HASH" . ,local-hash)
         ("TODOIST_REMOTE_HASH" . ,remote-hash)
         ("TODOIST_SYNC_TOKEN" . "tok-0")))
      (with-mock-sync
          '((sync_token . "tok-1")
            (items . (((id . "task-1")
                       (content . "Task")
                       (description . "")
                       (project_id . "proj-1")
                       (due . nil)
                       (checked . 1)))))
        (emacs-todoist-sync-heading))
      (goto-char (point-min))
      (should-not (re-search-forward "^\\*" nil t)))))

(ert-deftest emacs-todoist-integration/auto-sync-on-todo-state-change ()
  "Changing TODO state auto-syncs when `emacs-todoist-mode' is enabled."
  (with-org-buffer "* TODO Task\n"
    (let ((emacs-todoist-auto-sync-on-todo-change t)
          (sync-call-count 0)
          (done-item '((id . "task-1")
                       (content . "Task")
                       (description . "")
                       (due . nil)
                       (checked . 1))))
      (emacs-todoist-org-set-props
       '(("TODOIST_ID" . "task-1")
         ("TODOIST_LOCAL_HASH" . "stale")
         ("TODOIST_REMOTE_HASH" . "remote-old")
         ("TODOIST_SYNC_TOKEN" . "tok-0")))
      (cl-letf (((symbol-function 'emacs-todoist-api-sync)
                 (lambda (_sync-token _resource-types commands callback)
                   (cl-incf sync-call-count)
                   (if (null commands)
                       (funcall callback
                                '((sync_token . "tok-fetch")
                                  (items . nil)))
                     (funcall callback
                               `((sync_token . "tok-push")
                                 (items . (,done-item))))))))
        (emacs-todoist-mode 1)
        (org-todo "DONE")
        (should (= 2 sync-call-count))))))

(ert-deftest emacs-todoist-integration/capture-relocates-to-frontend ()
  "Capture finalize moves Todoist TODOs into frontend and syncs them."
  (with-org-buffer
      "* TODO Captured\n:PROPERTIES:\n:TODOIST_PROJECT: proj-1\n:END:\nBody.\n"
    (let ((org-capture-last-stored-marker (point-marker))
          (emacs-todoist-capture-to-frontend t)
          (captured-subtree nil)
          (captured-project nil)
          (sync-called nil)
          (frontend-buf (generate-new-buffer " *et-capture*"))
          (opened-frontend (generate-new-buffer emacs-todoist-frontend-buffer-name)))
      (unwind-protect
          (cl-letf (((symbol-function 'emacs-todoist-frontend-insert-captured-subtree)
                     (lambda (subtree project-id &optional _project-name)
                       (setq captured-subtree subtree
                             captured-project project-id)
                       (with-current-buffer frontend-buf
                         (erase-buffer)
                         (org-mode)
                         (insert subtree)
                         (goto-char (point-min))
                         (point-marker))))
                    ((symbol-function 'emacs-todoist-sync-heading)
                     (lambda ()
                       (setq sync-called t))))
            (emacs-todoist--capture-after-finalize))
        (kill-buffer frontend-buf)
        (when (buffer-live-p opened-frontend)
          (kill-buffer opened-frontend)))
      (should sync-called)
      (should (equal "proj-1" captured-project))
      (should (string-match-p "^\\* TODO Captured" captured-subtree))
      (goto-char (point-min))
      (should-not (re-search-forward "^\\*" nil t)))))

(ert-deftest emacs-todoist-integration/capture-dispatch-defers-in-interactive ()
  "Capture dispatch defers work until command-loop continuation."
  (with-org-buffer "* TODO Captured\n"
    (let ((noninteractive nil)
          (processed-marker nil))
      (setq emacs-todoist--capture-deferred-thunks nil)
      (remove-hook 'post-command-hook #'emacs-todoist--capture-flush-deferred)
      (unwind-protect
          (cl-letf (((symbol-function 'emacs-todoist--capture-process-or-push)
                     (lambda (marker)
                       (setq processed-marker marker))))
            (emacs-todoist--capture-dispatch-finalize (point-marker))
            (should-not processed-marker)
            (emacs-todoist--capture-flush-deferred)
            (should (markerp processed-marker)))
        (setq emacs-todoist--capture-deferred-thunks nil)
        (remove-hook 'post-command-hook #'emacs-todoist--capture-flush-deferred)))))

(ert-deftest emacs-todoist-integration/capture-without-open-frontend-stays-local ()
  "When frontend was never opened, capture should be pushed in-place."
  (with-org-buffer
      "* TODO Captured\n:PROPERTIES:\n:TODOIST_PROJECT: proj-1\n:END:\nBody.\n"
    (let ((org-capture-last-stored-marker (point-marker))
          (emacs-todoist-capture-to-frontend t)
          (insert-called nil)
          (push-called nil))
      (cl-letf (((symbol-function 'emacs-todoist-frontend-insert-captured-subtree)
                 (lambda (&rest _args)
                   (setq insert-called t)
                   (error "Should not relocate capture without frontend buffer")))
                ((symbol-function 'emacs-todoist-push-heading)
                 (lambda ()
                   (setq push-called t))))
        (emacs-todoist--capture-after-finalize))
      (should push-called)
      (should-not insert-called)
      (goto-char (point-min))
      (should (re-search-forward "^\\* TODO Captured$" nil t)))))

(ert-deftest emacs-todoist-integration/capture-relocation-failure-keeps-local ()
  "Failed frontend insertion keeps the local heading and falls back to push."
  (with-org-buffer
      "* TODO Captured\n:PROPERTIES:\n:TODOIST_PROJECT: proj-1\n:END:\nBody.\n"
    (let ((org-capture-last-stored-marker (point-marker))
          (emacs-todoist-capture-to-frontend t)
          (insert-called nil)
          (push-called nil)
          (opened-frontend (generate-new-buffer emacs-todoist-frontend-buffer-name)))
      (unwind-protect
          (cl-letf (((symbol-function 'emacs-todoist-frontend-insert-captured-subtree)
                     (lambda (&rest _args)
                       (setq insert-called t)
                       nil))
                    ((symbol-function 'emacs-todoist-push-heading)
                     (lambda ()
                       (setq push-called t))))
            (emacs-todoist--capture-after-finalize))
        (when (buffer-live-p opened-frontend)
          (kill-buffer opened-frontend)))
      (should insert-called)
      (should push-called)
      (goto-char (point-min))
      (should (re-search-forward "^\\* TODO Captured$" nil t)))))

;;; test-integration.el ends here
