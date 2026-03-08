;;; test-frontend.el --- Frontend tests for emacs-todoist  -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'emacs-todoist)
(require 'emacs-todoist-frontend)

;; Keep frontend buffer state isolated across tests.
(defmacro emacs-todoist-test-with-clean-frontend (&rest body)
  "Run BODY and always kill the frontend buffer afterwards."
  (declare (indent 0))
  `(unwind-protect
       (progn ,@body)
     (when-let* ((buf (get-buffer emacs-todoist-frontend-buffer-name)))
       (kill-buffer buf))))

(defmacro emacs-todoist-test-with-org-buffer (text &rest body)
  "Execute BODY in a temp org buffer initialized with TEXT."
  (declare (indent 1))
  `(with-temp-buffer
     (org-mode)
     (insert ,text)
     (goto-char (point-min))
     (when (re-search-forward "^\\*" nil t)
       (beginning-of-line))
     ,@body))

(defun emacs-todoist-test--basic-item (id content &optional parent-id checked)
  "Build a minimal Todoist ITEM test alist."
  (append `((id . ,id)
            (content . ,content)
            (description . "")
            (due . nil)
            (project_id . "proj-1")
            (checked . ,(or checked 0)))
          (when parent-id `((parent_id . ,parent-id)))))

;; ==============================================================================
;; Upsert primitives
;; ============================================================================== 

(ert-deftest emacs-todoist-frontend/topo-sort-parents-before-children ()
  "Topological sort emits parent before child."
  (let* ((parent (emacs-todoist-test--basic-item "p" "Parent"))
         (child (emacs-todoist-test--basic-item "c" "Child" "p"))
         (sorted (emacs-todoist--topological-sort-items (list child parent))))
    (should (equal '("p" "c")
                   (mapcar #'emacs-todoist--item-id sorted)))))

(ert-deftest emacs-todoist-frontend/topo-sort-handles-depth-3 ()
  "Topological sort preserves grandparent -> parent -> child order."
  (let* ((g (emacs-todoist-test--basic-item "g" "G"))
         (p (emacs-todoist-test--basic-item "p" "P" "g"))
         (c (emacs-todoist-test--basic-item "c" "C" "p"))
         (sorted (emacs-todoist--topological-sort-items (list c p g))))
    (should (equal '("g" "p" "c")
                   (mapcar #'emacs-todoist--item-id sorted)))))

(ert-deftest emacs-todoist-frontend/apply-items-updates-existing ()
  "apply-items updates an existing heading in place."
  (emacs-todoist-test-with-org-buffer
      "* TODO Old\n:PROPERTIES:\n:TODOIST_ID: t1\n:END:\n"
    (let* ((id-map (emacs-todoist--build-id-map))
           (item '((id . "t1")
                   (content . "Updated")
                   (description . "Body")
                   (project_id . "proj-1")
                   (due . ((date . "2026-04-10")))
                   (checked . 1))))
      (should (= 0 (emacs-todoist--apply-items (list item) "tok-2" id-map)))
      (should (equal "Updated" (emacs-todoist-org-heading-title)))
      (should (equal "DONE" (org-get-todo-state)))
      (should (equal "2026-04-10" (emacs-todoist-org-heading-deadline)))
      (should (equal "tok-2" (org-entry-get (point) "TODOIST_SYNC_TOKEN"))))))

(ert-deftest emacs-todoist-frontend/apply-items-inserts-new-child ()
  "apply-items inserts a missing child when its parent exists in ID map."
  (emacs-todoist-test-with-org-buffer
      "* TODO Parent\n:PROPERTIES:\n:TODOIST_ID: p1\n:END:\n"
    (let* ((id-map (emacs-todoist--build-id-map))
           (child '((id . "c1")
                    (parent_id . "p1")
                    (content . "Child")
                    (description . "")
                    (project_id . "proj-1")
                    (due . nil)
                    (checked . 0))))
      (should (= 1 (emacs-todoist--apply-items (list child) "tok-x" id-map)))
      (goto-char (point-min))
      (should (re-search-forward "^\\*\\* TODO Child$" nil t))
      (beginning-of-line)
      (should (equal "c1" (org-entry-get (point) "TODOIST_ID"))))))

(ert-deftest emacs-todoist-frontend/apply-items-skips-completed-child ()
  "apply-items does not insert a missing child that is already completed."
  (emacs-todoist-test-with-org-buffer
      "* TODO Parent\n:PROPERTIES:\n:TODOIST_ID: p1\n:END:\n"
    (let* ((before (buffer-string))
           (id-map (emacs-todoist--build-id-map))
           (child '((id . "c-done")
                    (parent_id . "p1")
                    (content . "Done child")
                    (description . "")
                    (project_id . "proj-1")
                    (due . nil)
                    (checked . 1))))
      (should (= 0 (emacs-todoist--apply-items (list child) "tok-x" id-map)))
      (should (equal before (buffer-string)))
      (should-not (gethash "c-done" id-map)))))

(ert-deftest emacs-todoist-frontend/apply-items-skips-top-level ()
  "apply-items skips top-level items when no parent is available."
  (emacs-todoist-test-with-org-buffer "* TODO Existing\n"
    (let* ((before (buffer-string))
           (id-map (make-hash-table :test #'equal))
           (top '((id . "t-top")
                  (content . "Remote Top")
                  (description . "")
                  (project_id . "proj-1")
                  (due . nil)
                  (checked . 0))))
      (should (= 0 (emacs-todoist--apply-items (list top) "tok" id-map)))
      (should (equal before (buffer-string))))))

(ert-deftest emacs-todoist-frontend/apply-items-skips-orphan ()
  "apply-items skips a child whose parent is missing from id-map."
  (emacs-todoist-test-with-org-buffer "* TODO Existing\n"
    (let ((id-map (make-hash-table :test #'equal))
          (orphan '((id . "orphan-1")
                    (parent_id . "missing-parent")
                    (content . "Orphan")
                    (description . "")
                    (project_id . "proj-1")
                    (due . nil)
                    (checked . 0))))
      (should (= 0 (emacs-todoist--apply-items (list orphan) "tok" id-map)))
      (should-not (string-match-p "Orphan" (buffer-string))))))

(ert-deftest emacs-todoist-frontend/apply-top-level-calls-project-fn ()
  "apply-top-level-items invokes project-fn for insert placement."
  (emacs-todoist-test-with-org-buffer "* Inbox\n"
    (let ((called nil)
          (id-map (make-hash-table :test #'equal))
          (item '((id . "new-top")
                  (content . "Top Task")
                  (description . "")
                  (project_id . "proj-1")
                  (due . nil)
                  (checked . 0))))
      (should (= 1
                 (emacs-todoist--apply-top-level-items
                  (list item) "tok" id-map
                 (lambda (_)
                    (setq called t)
                    (goto-char (point-min))
                    (point-marker)))))
      (should called))))

(ert-deftest emacs-todoist-frontend/apply-top-level-skips-completed-item ()
  "apply-top-level-items does not insert completed top-level tasks."
  (emacs-todoist-test-with-org-buffer "* Inbox\n"
    (let ((called nil)
          (id-map (make-hash-table :test #'equal))
          (item '((id . "done-top")
                  (content . "Already Done")
                  (description . "")
                  (project_id . "proj-1")
                  (due . nil)
                  (checked . 1))))
      (should (= 0
                 (emacs-todoist--apply-top-level-items
                  (list item) "tok" id-map
                  (lambda (_)
                    (setq called t)
                    (point-marker)))))
      (should-not called)
      (should-not (gethash "done-top" id-map))
      (should-not (string-match-p "Already Done" (buffer-string))))))

(ert-deftest emacs-todoist-frontend/apply-top-level-preserves-project-markers ()
  "Interleaved top-level inserts stay under the correct project container."
  (emacs-todoist-test-with-org-buffer
      "* Inbox\n:PROPERTIES:\n:TODOIST_PROJECT: proj-inbox\n:END:\n* Life\n:PROPERTIES:\n:TODOIST_PROJECT: proj-life\n:END:\n"
    (setq-local emacs-todoist--frontend-project-map
                (emacs-todoist--frontend-build-project-map))
    (setq-local emacs-todoist--frontend-id-to-name
                (let ((table (make-hash-table :test #'equal)))
                  (puthash "proj-inbox" "Inbox" table)
                  (puthash "proj-life" "Life" table)
                  table))
    (let ((id-map (make-hash-table :test #'equal))
          (items (list
                  '((id . "in-1")
                    (content . "Inbox Task 1")
                    (description . "")
                    (project_id . "proj-inbox")
                    (due . nil)
                    (checked . 0))
                  '((id . "life-1")
                    (content . "Paintball")
                    (description . "")
                    (project_id . "proj-life")
                    (due . nil)
                    (checked . 0))
                  '((id . "in-2")
                    (content . "Anki")
                    (description . "")
                    (project_id . "proj-inbox")
                    (due . nil)
                    (checked . 0)))))
      (should (= 3
                 (emacs-todoist--apply-top-level-items
                  items "tok" id-map
                  #'emacs-todoist--frontend-project-fn)))
      (goto-char (point-min))
      (should (re-search-forward "^\\*\\* TODO Paintball$" nil t))
      (beginning-of-line)
      (should (equal "Life"
                     (save-excursion
                       (org-up-heading-safe)
                       (emacs-todoist-org-heading-title))))
      (goto-char (point-min))
      (should (re-search-forward "^\\*\\* TODO Anki$" nil t))
      (beginning-of-line)
      (should (equal "Inbox"
                     (save-excursion
                       (org-up-heading-safe)
                       (emacs-todoist-org-heading-title)))))))

(ert-deftest emacs-todoist-frontend/hashes-stable-after-insert ()
  "Freshly inserted heading stores a stable local hash value."
  (emacs-todoist-test-with-org-buffer
      "* TODO Parent\n:PROPERTIES:\n:TODOIST_ID: p1\n:END:\n"
    (let* ((id-map (emacs-todoist--build-id-map))
           (child '((id . "c1")
                    (parent_id . "p1")
                    (content . "Child")
                    (description . "Desc")
                    (project_id . "proj-1")
                    (due . nil)
                    (checked . 0))))
      (emacs-todoist--apply-items (list child) "tok" id-map)
      (goto-char (point-min))
      (re-search-forward "^\\*\\* TODO Child$")
      (beginning-of-line)
      (should (equal (org-entry-get (point) "TODOIST_LOCAL_HASH")
                     (emacs-todoist-org-heading-local-hash))))))

;; ==============================================================================
;; sync-heading child insertion
;; ============================================================================== 

(ert-deftest emacs-todoist-frontend/sync-children-does-not-insert-missing ()
  "sync-heading does not insert missing remote items into local subtree."
  (emacs-todoist-test-with-org-buffer "* TODO Parent\n"
    (let* ((local-hash (emacs-todoist-org-heading-local-hash))
           (base-remote
            '((content . "Parent") (description . "") (due . nil) (checked . 0)))
           (base-remote-hash (emacs-todoist-api-hash-item base-remote))
           (response
            '((sync_token . "tok-1")
              (items . (((id . "p1")
                         (content . "Parent")
                         (description . "")
                         (project_id . "proj-1")
                         (due . nil)
                         (checked . 1))
                        ((id . "c1")
                         (parent_id . "p1")
                         (content . "Child")
                         (description . "")
                         (project_id . "proj-1")
                         (due . nil)
                         (checked . 1))
                        ((id . "s1")
                         (content . "Sibling In Other Project")
                         (description . "")
                         (project_id . "proj-2")
                         (due . nil)
                         (checked . 0)))))))
      (emacs-todoist-org-set-props
       `(("TODOIST_ID" . "p1")
         ("TODOIST_LOCAL_HASH" . ,local-hash)
         ("TODOIST_REMOTE_HASH" . ,base-remote-hash)
         ("TODOIST_SYNC_TOKEN" . "tok-0")))
      (cl-letf (((symbol-function 'emacs-todoist-api-sync)
                 (lambda (_sync-token _resource-types _commands callback)
                   (funcall callback response))))
        (emacs-todoist-sync-heading))
      (goto-char (point-min))
      (should-not (re-search-forward "^\\*\\* DONE Child$" nil t))
      (should-not (re-search-forward "^\\*\\* TODO Sibling In Other Project$" nil t)))))

(ert-deftest emacs-todoist-frontend/sync-children-updates-existing ()
  "sync-heading still updates existing child headings."
  (emacs-todoist-test-with-org-buffer
      "* TODO Parent\n:PROPERTIES:\n:TODOIST_ID: p1\n:TODOIST_SYNC_TOKEN: tok-0\n:END:\n** TODO Child\n:PROPERTIES:\n:TODOIST_ID: c1\n:TODOIST_REMOTE_HASH: stale\n:TODOIST_SYNC_TOKEN: tok-0\n:END:\n"
    (goto-char (point-min))
    (org-entry-put (point) "TODOIST_LOCAL_HASH"
                   (emacs-todoist-org-heading-local-hash))
    (save-excursion
      (org-goto-first-child)
      (org-entry-put (point) "TODOIST_LOCAL_HASH"
                     (emacs-todoist-org-heading-local-hash)))
    (let* ((base-remote
            '((content . "Parent") (description . "") (due . nil) (checked . 0)))
           (base-remote-hash (emacs-todoist-api-hash-item base-remote))
           (response
            `((sync_token . "tok-1")
              (items . (,(emacs-todoist-test--basic-item "p1" "Parent" nil 1)
                        ,(emacs-todoist-test--basic-item "c1" "Child Updated" "p1" 1))))))
      (goto-char (point-min))
      (org-entry-put (point) "TODOIST_REMOTE_HASH" base-remote-hash)
      (cl-letf (((symbol-function 'emacs-todoist-api-sync)
                 (lambda (_sync-token _resource-types _commands callback)
                   (funcall callback response))))
        (goto-char (point-min))
        (emacs-todoist-sync-heading)))
    (goto-char (point-min))
    (should (re-search-forward "^\\*\\* DONE Child Updated$" nil t))))

;; ==============================================================================
;; Frontend buffer
;; ============================================================================== 

(defun emacs-todoist-test--frontend-open-response ()
  "Response payload used by frontend render tests."
  '((sync_token . "tok-open")
    (projects . (((id . "proj-1") (name . "Inbox"))))
    (items . (((id . "top-1")
               (content . "Top TODO")
               (description . "Top body")
               (project_id . "proj-1")
               (due . ((date . "2026-05-01")))
               (checked . 0))
              ((id . "child-1")
               (parent_id . "top-1")
               (content . "Nested DONE")
               (description . "")
               (project_id . "proj-1")
               (due . nil)
               (checked . 1))))))

(ert-deftest emacs-todoist-frontend/buffer-is-created ()
  "emacs-todoist-open creates an org-mode frontend buffer."
  (emacs-todoist-test-with-clean-frontend
    (cl-letf (((symbol-function 'emacs-todoist-api-sync)
               (lambda (_sync-token _resource-types _commands callback)
                 (funcall callback (emacs-todoist-test--frontend-open-response)))))
      (emacs-todoist-open)
      (let ((buf (get-buffer emacs-todoist-frontend-buffer-name)))
        (should buf)
        (with-current-buffer buf
          (should (derived-mode-p 'org-mode))
          (should (null buffer-file-name))
          (should-not (buffer-modified-p))
          (should emacs-todoist-frontend-mode)
          (should emacs-todoist-mode))))))

(ert-deftest emacs-todoist-frontend/buffer-reused-and-synced-on-second-call ()
  "Second open call reuses existing buffer and runs incremental sync."
  (emacs-todoist-test-with-clean-frontend
    (let ((calls 0))
      (cl-letf (((symbol-function 'emacs-todoist-api-sync)
                 (lambda (_sync-token resource-types commands callback)
                   (cl-incf calls)
                   (cond
                    ((equal resource-types '("items" "projects"))
                     (funcall callback (emacs-todoist-test--frontend-open-response)))
                    ((null commands)
                     (funcall callback
                              '((sync_token . "tok-second-open")
                                (items . (((id . "top-1")
                                           (content . "Top TODO")
                                           (description . "Top body")
                                           (project_id . "proj-1")
                                           (due . ((date . "2026-05-01")))
                                           (checked . 0))
                                          ((id . "top-2")
                                           (content . "From Second Open")
                                           (description . "")
                                           (project_id . "proj-1")
                                           (due . nil)
                                           (checked . 0)))))))
                    (t
                      (funcall callback
                               '((sync_token . "tok-second-open-2")
                                 (items . nil))))))))
        (emacs-todoist-open)
        (let ((first (get-buffer emacs-todoist-frontend-buffer-name)))
          (emacs-todoist-open)
          (let ((second (get-buffer emacs-todoist-frontend-buffer-name)))
            (should first)
            (should second)
            (should (eq first second))))
        (with-current-buffer emacs-todoist-frontend-buffer-name
          (goto-char (point-min))
          (should (re-search-forward "^\\*\\* TODO From Second Open$" nil t)))
        (should (>= calls 2))))))

(ert-deftest emacs-todoist-frontend/renders-project-and-task-data ()
  "Frontend render writes project containers, task fields, and properties."
  (emacs-todoist-test-with-clean-frontend
    (cl-letf (((symbol-function 'emacs-todoist-api-sync)
               (lambda (_sync-token _resource-types _commands callback)
                 (funcall callback (emacs-todoist-test--frontend-open-response)))))
      (emacs-todoist-open)
      (with-current-buffer emacs-todoist-frontend-buffer-name
        (goto-char (point-min))
        (should (re-search-forward "^\\* Inbox$" nil t))
        (beginning-of-line)
        (should (null (org-entry-get (point) "TODOIST_ID")))
        (should (equal "proj-1" (org-entry-get (point) "TODOIST_PROJECT")))

        (should (re-search-forward "^\\*\\* TODO Top TODO$" nil t))
        (beginning-of-line)
        (should (equal "2026-05-01" (emacs-todoist-org-heading-deadline)))
        (should (equal "Top body" (emacs-todoist-org-heading-description)))
        (should (equal "top-1" (org-entry-get (point) "TODOIST_ID")))
        (should (org-entry-get (point) "TODOIST_LOCAL_HASH"))
        (should (org-entry-get (point) "TODOIST_REMOTE_HASH"))
        (should-not (re-search-forward "^\\*\\*\\* DONE Nested DONE$" nil t))))))

(ert-deftest emacs-todoist-frontend/unknown-project-renders ()
  "Unknown project IDs render under an 'Unknown Project' container."
  (emacs-todoist-test-with-clean-frontend
    (cl-letf (((symbol-function 'emacs-todoist-api-sync)
               (lambda (_sync-token _resource-types _commands callback)
                 (funcall callback
                          '((sync_token . "tok")
                            (projects . nil)
                            (items . (((id . "x1")
                                       (content . "Loose")
                                       (description . "")
                                       (project_id . "proj-x")
                                       (due . nil)
                                       (checked . 0)))))))))
      (emacs-todoist-open)
      (with-current-buffer emacs-todoist-frontend-buffer-name
        (goto-char (point-min))
        (should (re-search-forward "^\\* Unknown Project$" nil t))
        (should (re-search-forward "^\\*\\* TODO Loose$" nil t))))))

(ert-deftest emacs-todoist-frontend/frontend-sync-inserts-new-remote-item ()
  "Frontend sync inserts new remote top-level tasks under project headings."
  (emacs-todoist-test-with-clean-frontend
    (let ((call-count 0))
      (cl-letf (((symbol-function 'emacs-todoist-api-sync)
                 (lambda (_sync-token resource-types commands callback)
                   (cl-incf call-count)
                   (if (equal resource-types '("items" "projects"))
                       (funcall callback (emacs-todoist-test--frontend-open-response))
                     (if (null commands)
                         (funcall callback
                                  '((sync_token . "tok-sync")
                                    (items . (((id . "top-1")
                                               (content . "Top TODO")
                                               (description . "Top body")
                                               (project_id . "proj-1")
                                               (due . ((date . "2026-05-01")))
                                               (checked . 0))
                                              ((id . "top-2")
                                               (content . "Remote New")
                                               (description . "")
                                               (project_id . "proj-1")
                                               (due . nil)
                                               (checked . 0))))))
                       (funcall callback '((sync_token . "tok-sync-2") (items . nil))))))))
        (emacs-todoist-open)
        (with-current-buffer emacs-todoist-frontend-buffer-name
          (emacs-todoist-frontend-sync)
          (goto-char (point-min))
          (should (re-search-forward "^\\*\\* TODO Remote New$" nil t))))
      (should (>= call-count 2)))))

(ert-deftest emacs-todoist-frontend/frontend-sync-skips-new-completed-item ()
  "Frontend sync does not reinsert new remote items that are already DONE."
  (emacs-todoist-test-with-clean-frontend
    (cl-letf (((symbol-function 'emacs-todoist-api-sync)
               (lambda (_sync-token resource-types commands callback)
                 (if (equal resource-types '("items" "projects"))
                     (funcall callback (emacs-todoist-test--frontend-open-response))
                   (if (null commands)
                       (funcall callback
                                '((sync_token . "tok-sync")
                                  (items . (((id . "top-1")
                                             (content . "Top TODO")
                                             (description . "Top body")
                                             (project_id . "proj-1")
                                             (due . ((date . "2026-05-01")))
                                             (checked . 0))
                                            ((id . "top-done")
                                             (content . "Completed remotely")
                                             (description . "")
                                             (project_id . "proj-1")
                                             (due . nil)
                                             (checked . 1))))))
                     (funcall callback '((sync_token . "tok-sync-2") (items . nil))))))))
      (emacs-todoist-open)
      (with-current-buffer emacs-todoist-frontend-buffer-name
        (emacs-todoist-frontend-sync)
        (goto-char (point-min))
        (should-not (re-search-forward "^\\*\\* DONE Completed remotely$" nil t))
        (should-not (re-search-forward "^\\*\\* TODO Completed remotely$" nil t))))))

(ert-deftest emacs-todoist-frontend/frontend-sync-hook-runs-in-frontend-buffer ()
  "Frontend post-classify hook runs in frontend buffer for async callbacks."
  (emacs-todoist-test-with-clean-frontend
    (cl-letf (((symbol-function 'emacs-todoist-api-sync)
               (lambda (_sync-token resource-types commands callback)
                 (if (equal resource-types '("items" "projects"))
                     (funcall callback (emacs-todoist-test--frontend-open-response))
                   (if (null commands)
                       ;; Simulate `url-retrieve' callback context.
                       (with-temp-buffer
                         (funcall callback
                                  '((sync_token . "tok-sync")
                                    (items . (((id . "top-1")
                                               (content . "Top TODO")
                                               (description . "Top body")
                                               (project_id . "proj-1")
                                               (due . ((date . "2026-05-01")))
                                               (checked . 0))
                                              ((id . "top-2")
                                               (content . "Remote New From Callback")
                                               (description . "")
                                               (project_id . "proj-1")
                                               (due . nil)
                                               (checked . 0)))))))
                      (funcall callback
                               '((sync_token . "tok-sync-2")
                                 (items . nil))))))))
      (emacs-todoist-open)
      (with-current-buffer emacs-todoist-frontend-buffer-name
        (emacs-todoist-frontend-sync)
        (goto-char (point-min))
        (should (re-search-forward "^\\*\\* TODO Remote New From Callback$" nil t))))))

(ert-deftest emacs-todoist-frontend/sync-heading-works ()
  "After frontend render, sync-heading on unchanged entry does not push."
  (emacs-todoist-test-with-clean-frontend
    (let ((sync-calls nil))
      (cl-letf (((symbol-function 'emacs-todoist-api-sync)
                 (lambda (_sync-token resource-types commands callback)
                   (push (list (cons 'resource-types resource-types)
                               (cons 'commands commands))
                         sync-calls)
                   (if (equal resource-types '("items" "projects"))
                       (funcall callback (emacs-todoist-test--frontend-open-response))
                     (funcall callback
                              '((sync_token . "tok-next")
                                (items . (((id . "top-1")
                                           (content . "Top TODO")
                                           (description . "Top body")
                                           (project_id . "proj-1")
                                           (due . ((date . "2026-05-01")))
                                           (checked . 0))))))))))
        (emacs-todoist-open)
        (with-current-buffer emacs-todoist-frontend-buffer-name
          (goto-char (point-min))
          (re-search-forward "^\\*\\* TODO Top TODO$")
          (beginning-of-line)
          (setq sync-calls nil)
          (emacs-todoist-sync-heading)
          (should (= 1 (length sync-calls)))
          (should (null (alist-get 'commands (car sync-calls)))))))))

(ert-deftest emacs-todoist-frontend/sync-commands-work-in-frontend-buffer ()
  "sync-buffer, sync-subtree, and sync-region run successfully in frontend."
  (emacs-todoist-test-with-clean-frontend
    (let ((calls 0))
      (cl-letf (((symbol-function 'emacs-todoist-api-sync)
                 (lambda (_sync-token resource-types commands callback)
                   (cl-incf calls)
                   (if (equal resource-types '("items" "projects"))
                       (funcall callback (emacs-todoist-test--frontend-open-response))
                     (if (null commands)
                         (funcall callback
                                  '((sync_token . "tok-next")
                                    (items . (((id . "top-1")
                                               (content . "Top TODO")
                                               (description . "Top body")
                                               (project_id . "proj-1")
                                               (due . ((date . "2026-05-01")))
                                               (checked . 0))
                                              ((id . "child-1")
                                               (parent_id . "top-1")
                                               (content . "Nested DONE")
                                               (description . "")
                                               (project_id . "proj-1")
                                               (due . nil)
                                               (checked . 1))))))
                       (funcall callback '((sync_token . "tok-push") (items . nil))))))))
        (emacs-todoist-open)
        (with-current-buffer emacs-todoist-frontend-buffer-name
          (emacs-todoist-sync-buffer)
          (goto-char (point-min))
          (re-search-forward "^\\* Inbox$")
          (beginning-of-line)
          (emacs-todoist-sync-subtree)
          (goto-char (point-min))
          (re-search-forward "^\\*\\* TODO Top TODO$")
          (beginning-of-line)
          (push-mark (line-end-position) t t)
          (goto-char (line-beginning-position))
          (activate-mark)
          (emacs-todoist-sync-region)
          (deactivate-mark)))
      (should (>= calls 3)))))

(ert-deftest emacs-todoist-frontend/agenda-command-syncs-then-opens-restricted-view ()
  "Frontend agenda command syncs first, then opens agenda from frontend snapshot."
  (emacs-todoist-test-with-clean-frontend
    (let (seen-agenda-files)
      (cl-letf (((symbol-function 'emacs-todoist-api-sync)
                 (lambda (_sync-token resource-types commands callback)
                   (if (and (equal resource-types '("items"))
                            (null commands))
                       (funcall callback
                                '((sync_token . "tok-agenda")
                                  (items . (((id . "a1")
                                             (content . "Agenda Item")
                                             (description . "")
                                             (project_id . "proj-1")
                                             (due . nil)
                                             (checked . 0))))))
                      (funcall callback
                               '((sync_token . "tok-agenda-push")
                                 (items . nil))))))
                ((symbol-function 'org-agenda-list)
                 (lambda (&rest _args)
                   (setq seen-agenda-files org-agenda-files))))
        (emacs-todoist-frontend-agenda)
        (should (= 1 (length seen-agenda-files)))
        (let ((agenda-file (car seen-agenda-files)))
          (should (stringp agenda-file))
          (should (file-exists-p agenda-file))
          (with-temp-buffer
            (insert-file-contents agenda-file)
            (goto-char (point-min))
            (should (re-search-forward "^\\*\\* TODO Agenda Item$" nil t))))))))

(ert-deftest emacs-todoist-frontend/autoload-open-command ()
  "Main package exposes frontend open command through autoload."
  (fmakunbound 'emacs-todoist-open)
  (autoload 'emacs-todoist-open "emacs-todoist-frontend" nil t)
  (should (autoloadp (symbol-function 'emacs-todoist-open))))

(ert-deftest emacs-todoist-frontend/autoload-agenda-command ()
  "Main package exposes frontend agenda command through autoload."
  (fmakunbound 'emacs-todoist-frontend-agenda)
  (autoload 'emacs-todoist-frontend-agenda "emacs-todoist-frontend" nil t)
  (should (autoloadp (symbol-function 'emacs-todoist-frontend-agenda))))

(ert-deftest emacs-todoist-frontend/insert-captured-subtree-under-project ()
  "Captured subtree insertion places heading under the target project."
  (emacs-todoist-test-with-clean-frontend
    (cl-letf (((symbol-function 'emacs-todoist-api-sync)
               (lambda (_sync-token _resource-types _commands callback)
                 (funcall callback (emacs-todoist-test--frontend-open-response)))))
      (emacs-todoist-open))
    (let ((marker (emacs-todoist-frontend-insert-captured-subtree
                   "* TODO Captured Task\nCaptured body.\n"
                   "proj-1" "Inbox")))
      (should (markerp marker))
      (with-current-buffer emacs-todoist-frontend-buffer-name
        (goto-char marker)
        (should (equal "Captured Task" (emacs-todoist-org-heading-title)))
        (should (equal "proj-1" (org-entry-get (point) "TODOIST_PROJECT")))
        (should (null (org-entry-get (point) "TODOIST_ID")))
        (should (equal "Inbox"
                       (save-excursion
                         (org-up-heading-safe)
                         (emacs-todoist-org-heading-title))))))))

;;; test-frontend.el ends here
