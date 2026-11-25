;;; test-frontend.el --- Frontend tests for emacs-todoist  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Felix Mühlenberend
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'ert)
(require 'cl-lib)
(require 'emacs-todoist)
(require 'emacs-todoist-frontend)

;; Keep frontend buffer state isolated across tests.
(defmacro emacs-todoist-test-with-clean-frontend (&rest body)
  "Run BODY and always kill the frontend buffer afterwards."
  (declare (indent 0))
  `(let* ((org-directory (make-temp-file "et-org-" t))
          (frontend-file (expand-file-name emacs-todoist-frontend-file-name
                                           org-directory)))
     (unwind-protect
         (progn ,@body)
       (when-let* ((buf (get-file-buffer frontend-file)))
         (kill-buffer buf))
       (when (file-exists-p frontend-file)
         (delete-file frontend-file))
       (when (file-directory-p org-directory)
         (delete-directory org-directory t)))))

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

(defun emacs-todoist-test--top-level-headings ()
  "Return top-level heading titles from current Org buffer."
  (let ((titles '()))
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward org-heading-regexp nil t)
        (beginning-of-line)
        (when (= (org-current-level) 1)
          (push (emacs-todoist-org-heading-title) titles))
        (end-of-line)))
    (nreverse titles)))

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

(ert-deftest emacs-todoist-frontend/file-path-tracks-file-name ()
  "Frontend file path is derived from `emacs-todoist-frontend-file-name'."
  (let ((org-directory "/tmp/emacs-todoist-tests")
        (emacs-todoist-frontend-file-name "tasks.org"))
    (should (equal "/tmp/emacs-todoist-tests/tasks.org"
                   (emacs-todoist-frontend-file-path)))))

(ert-deftest emacs-todoist-frontend/default-project-order-inbox-then-alpha ()
  "Default project order keeps Inbox first, then sorts by name."
  (let* ((projects '(((id . "proj-3") (name . "Work"))
                     ((id . "proj-2") (name . "life"))
                     ((id . "proj-1") (name . "Inbox"))))
         (ordered (emacs-todoist-frontend-default-project-order projects)))
    (should (equal '("Inbox" "life" "Work")
                   (mapcar (lambda (project)
                             (alist-get 'name project))
                           ordered)))))

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
;; single-heading sync descendant behavior
;; ============================================================================== 

(ert-deftest emacs-todoist-frontend/sync-single-heading-does-not-insert-missing-children ()
  "Single-heading sync does not insert missing remote descendants."
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
        (emacs-todoist-sync-single-heading))
      (goto-char (point-min))
      (should-not (re-search-forward "^\\*\\* DONE Child$" nil t))
      (should-not (re-search-forward "^\\*\\* TODO Sibling In Other Project$" nil t)))))

(ert-deftest emacs-todoist-frontend/sync-single-heading-does-not-update-existing-children ()
  "Single-heading sync leaves existing child headings untouched."
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
        (emacs-todoist-sync-single-heading)))
    (goto-char (point-min))
    (should (re-search-forward "^\\*\\* TODO Child$" nil t))
    (should-not (re-search-forward "^\\*\\* DONE Child Updated$" nil t))))

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

(defun emacs-todoist-test--frontend-open-response-multi-project ()
  "Response payload with intentionally unsorted projects/items."
  '((sync_token . "tok-open")
    (projects . (((id . "proj-3") (name . "Work"))
                 ((id . "proj-2") (name . "Life"))
                 ((id . "proj-1") (name . "Inbox"))))
    (items . (((id . "top-3")
               (content . "Task Work")
               (description . "")
               (project_id . "proj-3")
               (due . nil)
               (checked . 0))
              ((id . "top-2")
               (content . "Task Life")
               (description . "")
               (project_id . "proj-2")
               (due . nil)
               (checked . 0))
              ((id . "top-1")
               (content . "Task Inbox")
               (description . "")
               (project_id . "proj-1")
               (due . nil)
               (checked . 0))))))

(ert-deftest emacs-todoist-frontend/buffer-is-created ()
  "emacs-todoist-open creates an org-mode frontend buffer."
  (emacs-todoist-test-with-clean-frontend
    (cl-letf (((symbol-function 'emacs-todoist-api-sync)
               (lambda (_sync-token _resource-types _commands callback)
                 (funcall callback (emacs-todoist-test--frontend-open-response)))))
      (emacs-todoist-open)
      (let ((buf (get-buffer emacs-todoist-frontend-file-name)))
        (should buf)
        (with-current-buffer buf
          (should (derived-mode-p 'org-mode))
          (should (equal (expand-file-name emacs-todoist-frontend-file-name
                                           org-directory)
                         buffer-file-name))
          (should-not (buffer-modified-p))
          (should emacs-todoist-frontend-mode)
          (should emacs-todoist-mode))))))

(ert-deftest emacs-todoist-frontend/open-delays-switch-until-initial-render-finishes ()
  "Initial `emacs-todoist-open' switches only after async render callback."
  (emacs-todoist-test-with-clean-frontend
    (let (captured-callback switched-to)
      (cl-letf (((symbol-function 'emacs-todoist-api-sync)
                 (lambda (_sync-token _resource-types _commands callback)
                   (setq captured-callback callback)))
                ((symbol-function 'switch-to-buffer)
                 (lambda (buffer-or-name &rest _args)
                   (setq switched-to buffer-or-name))))
        (emacs-todoist-open)
        (should captured-callback)
        (should-not switched-to)
        (funcall captured-callback (emacs-todoist-test--frontend-open-response))
        (let ((frontend-buf (get-buffer emacs-todoist-frontend-file-name))
              (switched-buf (if (bufferp switched-to)
                                switched-to
                              (get-buffer switched-to))))
          (should frontend-buf)
          (should (eq frontend-buf switched-buf)))))))

(ert-deftest emacs-todoist-frontend/after-creation-hook-runs-on-initial-render ()
  "Frontend creation hook runs once after initial full render."
  (emacs-todoist-test-with-clean-frontend
    (let ((runs 0)
          hook-fn)
      (setq hook-fn
            (lambda ()
              (cl-incf runs)
              (should (derived-mode-p 'org-mode))
              (should emacs-todoist-frontend-mode)))
      (unwind-protect
          (progn
            (add-hook 'emacs-todoist-frontend-after-creation-hook hook-fn)
            (cl-letf (((symbol-function 'emacs-todoist-api-sync)
                       (lambda (_sync-token _resource-types _commands callback)
                         (funcall callback (emacs-todoist-test--frontend-open-response)))))
              (emacs-todoist-open))
            (should (= 1 runs)))
        (remove-hook 'emacs-todoist-frontend-after-creation-hook hook-fn)))))

(ert-deftest emacs-todoist-frontend/after-creation-hook-not-run-on-reopen-sync ()
  "Frontend creation hook is not run for reopen incremental sync path."
  (emacs-todoist-test-with-clean-frontend
    (let ((runs 0)
          hook-fn)
      (setq hook-fn (lambda () (cl-incf runs)))
      (unwind-protect
          (progn
            (add-hook 'emacs-todoist-frontend-after-creation-hook hook-fn)
            (cl-letf (((symbol-function 'emacs-todoist-api-sync)
                       (lambda (_sync-token resource-types commands callback)
                         (cond
                          ((equal resource-types '("items" "projects"))
                           (funcall callback
                                    (emacs-todoist-test--frontend-open-response)))
                          ((null commands)
                           (funcall callback '((sync_token . "tok-reopen")
                                               (items . nil))))
                          (t
                           (funcall callback '((sync_token . "tok-reopen-2")
                                               (items . nil))))))))
              (emacs-todoist-open)
              (emacs-todoist-open))
            (should (= 1 runs)))
        (remove-hook 'emacs-todoist-frontend-after-creation-hook hook-fn)))))

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
        (let ((first (get-buffer emacs-todoist-frontend-file-name)))
          (emacs-todoist-open)
          (let ((second (get-buffer emacs-todoist-frontend-file-name)))
            (should first)
            (should second)
            (should (eq first second))))
        (with-current-buffer emacs-todoist-frontend-file-name
          (goto-char (point-min))
          (should (re-search-forward "^\\*\\* TODO From Second Open$" nil t)))
        (should (>= calls 2))))))

(ert-deftest emacs-todoist-frontend/open-delays-switch-until-incremental-sync-finishes ()
  "Re-opened frontend switches only after incremental sync completion callback."
  (emacs-todoist-test-with-clean-frontend
    (let ((todoist-buf (emacs-todoist-frontend-ensure-buffer))
          done-fn
          switched-to)
      (cl-letf (((symbol-function 'emacs-todoist-frontend-sync)
                 (lambda (&optional fn)
                   (setq done-fn fn)))
                ((symbol-function 'switch-to-buffer)
                 (lambda (buffer-or-name &rest _args)
                   (setq switched-to buffer-or-name))))
        (emacs-todoist-open)
        (should done-fn)
        (should-not switched-to)
        (funcall done-fn '(:status ok))
        (let ((switched-buf (if (bufferp switched-to)
                                switched-to
                              (get-buffer switched-to))))
          (should (eq todoist-buf switched-buf)))))))

(ert-deftest emacs-todoist-frontend/open-recreate-delegates-to-open ()
  "open-recreate is a thin wrapper that delegates to `emacs-todoist-open'."
  (let ((open-calls 0))
    (cl-letf (((symbol-function 'emacs-todoist-open)
               (lambda ()
                 (cl-incf open-calls))))
      (emacs-todoist-open-recreate))
    (should (= 1 open-calls))))

(ert-deftest emacs-todoist-frontend/open-recreate-forces-full-open-path ()
  "open-recreate kills existing frontend buffer so open path is full render."
  (emacs-todoist-test-with-clean-frontend
    (let ((items-projects-fetches 0)
          (frontend-sync-calls 0))
      (cl-letf (((symbol-function 'emacs-todoist-api-sync)
                 (lambda (_sync-token resource-types _commands callback)
                   (when (equal resource-types '("items" "projects"))
                     (cl-incf items-projects-fetches))
                   (funcall callback (emacs-todoist-test--frontend-open-response))))
                ((symbol-function 'emacs-todoist-frontend-sync)
                 (lambda (&optional _done-fn)
                   (cl-incf frontend-sync-calls))))
        (emacs-todoist-open)
        (emacs-todoist-open-recreate))
      (should (= 2 items-projects-fetches))
      (should (= 0 frontend-sync-calls)))))

(ert-deftest emacs-todoist-frontend/sync-on-save-triggers-sync ()
  "Saving frontend buffer triggers incremental sync when configured."
  (emacs-todoist-test-with-clean-frontend
    (let ((sync-calls 0))
      (with-current-buffer (emacs-todoist-frontend-ensure-buffer)
        (erase-buffer)
        (setq-local emacs-todoist-frontend-sync-on-save t)
        (cl-letf (((symbol-function 'emacs-todoist-frontend-sync)
                   (lambda (&optional _done-fn)
                     (cl-incf sync-calls))))
          (insert "* TODO Saved task\n")
          (save-buffer)))
      (should (= 1 sync-calls)))))

(ert-deftest emacs-todoist-frontend/sync-on-save-suppressed-for-internal-save ()
  "Programmatic frontend save helper should not trigger save-based sync."
  (emacs-todoist-test-with-clean-frontend
    (let ((sync-calls 0))
      (with-current-buffer (emacs-todoist-frontend-ensure-buffer)
        (erase-buffer)
        (setq-local emacs-todoist-frontend-sync-on-save t)
        (cl-letf (((symbol-function 'emacs-todoist-frontend-sync)
                   (lambda (&optional _done-fn)
                     (cl-incf sync-calls))))
          (insert "* TODO Internal save\n")
          (emacs-todoist--frontend-save-buffer)))
      (should (= 0 sync-calls)))))

(ert-deftest emacs-todoist-frontend/renders-project-and-task-data ()
  "Frontend render writes project containers, task fields, and properties."
  (emacs-todoist-test-with-clean-frontend
    (cl-letf (((symbol-function 'emacs-todoist-api-sync)
               (lambda (_sync-token _resource-types _commands callback)
                 (funcall callback (emacs-todoist-test--frontend-open-response)))))
      (emacs-todoist-open)
      (with-current-buffer emacs-todoist-frontend-file-name
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

(ert-deftest emacs-todoist-frontend/renders-projects-with-default-order ()
  "Frontend render orders projects as Inbox first, then alphabetically."
  (emacs-todoist-test-with-clean-frontend
    (cl-letf (((symbol-function 'emacs-todoist-api-sync)
               (lambda (_sync-token _resource-types _commands callback)
                 (funcall callback
                          (emacs-todoist-test--frontend-open-response-multi-project)))))
      (emacs-todoist-open)
      (with-current-buffer emacs-todoist-frontend-file-name
        (should (equal '("Inbox" "Life" "Work")
                       (emacs-todoist-test--top-level-headings)))))))

(ert-deftest emacs-todoist-frontend/renders-projects-with-custom-order-function ()
  "Frontend render respects custom project order function."
  (emacs-todoist-test-with-clean-frontend
    (let ((emacs-todoist-frontend-project-order-function
           (lambda (projects)
             (sort projects
                   (lambda (a b)
                     (string-lessp
                      (downcase (format "%s" (or (alist-get 'name b) "")))
                      (downcase (format "%s" (or (alist-get 'name a) "")))))))))
      (cl-letf (((symbol-function 'emacs-todoist-api-sync)
                 (lambda (_sync-token _resource-types _commands callback)
                   (funcall callback
                            (emacs-todoist-test--frontend-open-response-multi-project)))))
        (emacs-todoist-open)
        (with-current-buffer emacs-todoist-frontend-file-name
          (should (equal '("Work" "Life" "Inbox")
                         (emacs-todoist-test--top-level-headings))))))))

(ert-deftest emacs-todoist-frontend/new-project-on-sync-appends-at-end ()
  "Incremental sync appends newly seen project containers at buffer end."
  (emacs-todoist-test-with-clean-frontend
    (cl-letf (((symbol-function 'emacs-todoist-api-sync)
               (lambda (_sync-token resource-types commands callback)
                 (if (equal resource-types '("items" "projects"))
                     (funcall callback
                              (emacs-todoist-test--frontend-open-response-multi-project))
                   (if (null commands)
                       (funcall callback
                                '((sync_token . "tok-sync")
                                  (items . (((id . "top-aaa")
                                             (content . "Task AAA")
                                             (description . "")
                                             (project_id . "proj-aaa")
                                             (due . nil)
                                             (checked . 0))))))
                     (funcall callback '((sync_token . "tok-sync-2")
                                         (items . nil))))))))
      (emacs-todoist-open)
      (with-current-buffer emacs-todoist-frontend-file-name
        (puthash "proj-aaa" "AAA" emacs-todoist--frontend-id-to-name)
        (emacs-todoist-frontend-sync)
        (should (equal '("Inbox" "Life" "Work" "AAA")
                       (emacs-todoist-test--top-level-headings)))))))

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
      (with-current-buffer emacs-todoist-frontend-file-name
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
        (with-current-buffer emacs-todoist-frontend-file-name
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
      (with-current-buffer emacs-todoist-frontend-file-name
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
      (with-current-buffer emacs-todoist-frontend-file-name
        (emacs-todoist-frontend-sync)
        (goto-char (point-min))
        (should (re-search-forward "^\\*\\* TODO Remote New From Callback$" nil t))))))

(ert-deftest emacs-todoist-frontend/frontend-sync-bootstrap-forces-full-fetch ()
  "The first frontend sync always uses `*' to bootstrap complete state."
  (emacs-todoist-test-with-clean-frontend
    (let ((seen-fetch-token nil)
          (seed-item '((id . "seed-1")
                       (content . "Seeded Capture")
                       (description . "")
                       (project_id . "proj-1")
                       (due . nil)
                       (checked . 0)))
          (older-item '((id . "older-1")
                        (content . "Older Remote")
                        (description . "")
                        (project_id . "proj-1")
                        (due . nil)
                        (checked . 0))))
      (with-current-buffer (emacs-todoist-frontend-ensure-buffer)
        (erase-buffer)
        (insert "* Inbox\n:PROPERTIES:\n:TODOIST_PROJECT: proj-1\n:END:\n"
                "** TODO Seeded Capture\n:PROPERTIES:\n:TODOIST_ID: seed-1\n:END:\n")
        (goto-char (point-min))
        (re-search-forward "^\\*\\* TODO Seeded Capture$")
        (beginning-of-line)
        (emacs-todoist-org-set-props
         `(("TODOIST_LOCAL_HASH" . ,(emacs-todoist-org-heading-local-hash))
           ("TODOIST_REMOTE_HASH" . ,(emacs-todoist-api-hash-item seed-item))
           ("TODOIST_SYNC_TOKEN" . "tok-seeded")))
        (setq-local emacs-todoist--frontend-bootstrap-complete nil)
        (setq-local emacs-todoist--frontend-id-to-name
                    (let ((table (make-hash-table :test #'equal)))
                      (puthash "proj-1" "Inbox" table)
                      table)))
      (cl-letf (((symbol-function 'emacs-todoist-api-sync)
                 (lambda (sync-token _resource-types commands callback)
                   (if (null commands)
                       (progn
                         (setq seen-fetch-token sync-token)
                         (funcall callback
                                  `((sync_token . "tok-bootstrap")
                                    (items . (,seed-item ,older-item)))))
                     (funcall callback '((sync_token . "tok-push") (items . nil)))))))
        (with-current-buffer emacs-todoist-frontend-file-name
          (emacs-todoist-frontend-sync)
          (should (equal "*" seen-fetch-token))
          (goto-char (point-min))
          (should (re-search-forward "^\\*\\* TODO Older Remote$" nil t))
          (should emacs-todoist--frontend-bootstrap-complete))))))

(ert-deftest emacs-todoist-frontend/sync-single-heading-works ()
  "After frontend render, single-heading sync on unchanged entry does not push."
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
        (with-current-buffer emacs-todoist-frontend-file-name
          (goto-char (point-min))
          (re-search-forward "^\\*\\* TODO Top TODO$")
          (beginning-of-line)
          (setq sync-calls nil)
          (emacs-todoist-sync-single-heading)
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
        (with-current-buffer emacs-todoist-frontend-file-name
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
  "Frontend agenda command syncs first, then opens agenda from frontend file."
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
          (should (equal (expand-file-name emacs-todoist-frontend-file-name
                                           org-directory)
                         agenda-file))
          (with-temp-buffer
            (insert-file-contents agenda-file)
            (goto-char (point-min))
            (should (re-search-forward "^\\*\\* TODO Agenda Item$" nil t))))))))

(ert-deftest emacs-todoist-frontend/agenda-delays-open-until-sync-finishes ()
  "Agenda command waits for sync completion and does not switch to frontend."
  (emacs-todoist-test-with-clean-frontend
    (let (done-fn switched-to agenda-opened)
      (cl-letf (((symbol-function 'emacs-todoist-frontend-sync)
                 (lambda (&optional fn)
                   (setq done-fn fn)))
                ((symbol-function 'switch-to-buffer)
                 (lambda (buffer-or-name &rest _args)
                   (setq switched-to buffer-or-name)))
                ((symbol-function 'emacs-todoist--frontend-open-agenda-from-buffer)
                 (lambda ()
                   (setq agenda-opened t))))
        (emacs-todoist-frontend-agenda)
        (should done-fn)
        (should-not switched-to)
        (should-not agenda-opened)
        (funcall done-fn '(:status ok))
        (should-not switched-to)
        (should agenda-opened)))))

(ert-deftest emacs-todoist-frontend/agenda-hook-runs-in-agenda-buffer ()
  "Frontend agenda hook runs in the agenda buffer after opening."
  (emacs-todoist-test-with-clean-frontend
    (let ((runs 0)
          hook-fn
          hook-buffer)
      (setq hook-fn
            (lambda ()
              (cl-incf runs)
              (setq hook-buffer (current-buffer))))
      (unwind-protect
          (progn
            (add-hook 'emacs-todoist-frontend-agenda-hook hook-fn)
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
                                      (items . nil)))))))
              (emacs-todoist-frontend-agenda))
            (should (= 1 runs))
            (should (buffer-live-p hook-buffer))
            (with-current-buffer hook-buffer
              (should (derived-mode-p 'org-agenda-mode))))
        (remove-hook 'emacs-todoist-frontend-agenda-hook hook-fn)))))

(ert-deftest emacs-todoist-frontend/agenda-hook-runs-for-mocked-agenda-buffer ()
  "Frontend agenda hook runs when `org-agenda-list' creates the agenda buffer."
  (emacs-todoist-test-with-clean-frontend
    (let ((runs 0)
          hook-fn)
      (setq hook-fn
            (lambda ()
              (cl-incf runs)))
      (unwind-protect
          (progn
            (add-hook 'emacs-todoist-frontend-agenda-hook hook-fn)
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
                         (with-current-buffer (get-buffer-create org-agenda-buffer-name)
                           (org-agenda-mode)))))
              (emacs-todoist-frontend-agenda))
            (should (= 1 runs)))
        (remove-hook 'emacs-todoist-frontend-agenda-hook hook-fn)))))

(ert-deftest emacs-todoist-frontend/autoload-open-command ()
  "Main package exposes frontend open command through autoload."
  (fmakunbound 'emacs-todoist-open)
  (autoload 'emacs-todoist-open "emacs-todoist-frontend" nil t)
  (should (autoloadp (symbol-function 'emacs-todoist-open))))

(ert-deftest emacs-todoist-frontend/autoload-open-recreate-command ()
  "Main package exposes frontend open-recreate command through autoload."
  (fmakunbound 'emacs-todoist-open-recreate)
  (autoload 'emacs-todoist-open-recreate "emacs-todoist-frontend" nil t)
  (should (autoloadp (symbol-function 'emacs-todoist-open-recreate))))

(ert-deftest emacs-todoist-frontend/autoload-agenda-command ()
  "Main package exposes frontend agenda command through autoload."
  (fmakunbound 'emacs-todoist-frontend-agenda)
  (autoload 'emacs-todoist-frontend-agenda "emacs-todoist-frontend" nil t)
  (should (autoloadp (symbol-function 'emacs-todoist-frontend-agenda))))

(ert-deftest emacs-todoist-frontend/autoload-view-canonical-heading-command ()
  "Main package exposes canonical heading view command through autoload."
  (fmakunbound 'emacs-todoist-view-canonical-heading)
  (autoload 'emacs-todoist-view-canonical-heading "emacs-todoist-frontend" nil t)
  (should (autoloadp (symbol-function 'emacs-todoist-view-canonical-heading))))

(ert-deftest emacs-todoist-frontend/keymaps-exposed-for-user-bindings ()
  "Frontend and agenda keymaps are exposed without package-level leader keys."
  (should (keymapp emacs-todoist-frontend-keymap))
  (should (keymapp emacs-todoist-agenda-keymap))
  (should-not (eq #'emacs-todoist-view-canonical-heading
                  (lookup-key emacs-todoist-frontend-keymap (kbd "SPC m v"))))
  (should-not (eq #'emacs-todoist-view-canonical-heading
                  (lookup-key emacs-todoist-agenda-keymap (kbd "SPC m v")))))

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
      (with-current-buffer emacs-todoist-frontend-file-name
        (goto-char marker)
        (should (equal "Captured Task" (emacs-todoist-org-heading-title)))
        (should (equal "proj-1" (org-entry-get (point) "TODOIST_PROJECT")))
        (should (null (org-entry-get (point) "TODOIST_ID")))
        (should (equal "Inbox"
                       (save-excursion
                         (org-up-heading-safe)
                         (emacs-todoist-org-heading-title))))))))

;; ==============================================================================
;; Canonical heading navigation
;; ==============================================================================

(ert-deftest emacs-todoist-frontend/view-canonical-heading-opens-other-window ()
  "Viewing a canonical heading opens the source while keeping frontend focus."
  (emacs-todoist-test-with-clean-frontend
    (let* ((source-file (expand-file-name "source.org" org-directory))
           (cache-file (expand-file-name "find-cache.el" org-directory))
           (frontend-buf (emacs-todoist-frontend-ensure-buffer))
           (org-refile-targets `((,source-file :maxlevel . 5)))
           (emacs-todoist-find-heading-cache-file cache-file))
      (with-temp-file source-file
        (insert "* TODO Source\n:PROPERTIES:\n:TODOIST_ID: t1\n:END:\n"))
      (with-current-buffer frontend-buf
        (erase-buffer)
        (org-mode)
        (emacs-todoist-frontend-mode 1)
        (insert "* TODO Frontend\n:PROPERTIES:\n:TODOIST_ID: t1\n:END:\n")
        (goto-char (point-min)))
      (unwind-protect
          (progn
            (delete-other-windows)
            (switch-to-buffer frontend-buf)
            (let ((selected (selected-window))
                  (frontend-point (point)))
              (emacs-todoist-view-canonical-heading)
              (should (eq selected (selected-window)))
              (should (eq frontend-buf (current-buffer)))
              (should (= frontend-point (point)))
              (let ((source-buf (get-file-buffer source-file)))
                (should source-buf)
                (should (get-buffer-window source-buf t))
                (with-current-buffer source-buf
                  (goto-char (point-min))
                  (should (equal "Source"
                                 (emacs-todoist-org-heading-title)))))))
        (when-let* ((source-buf (get-file-buffer source-file)))
          (kill-buffer source-buf))))))

(ert-deftest emacs-todoist-frontend/view-canonical-heading-pulses-source-line ()
  "Viewing a canonical heading highlights the source line when pulse is available."
  (emacs-todoist-test-with-clean-frontend
    (let* ((source-file (expand-file-name "source.org" org-directory))
           (cache-file (expand-file-name "find-cache.el" org-directory))
           (frontend-buf (emacs-todoist-frontend-ensure-buffer))
           (org-refile-targets `((,source-file :maxlevel . 5)))
           (emacs-todoist-find-heading-cache-file cache-file)
           pulse-point)
      (with-temp-file source-file
        (insert "* TODO Source\n:PROPERTIES:\n:TODOIST_ID: t1\n:END:\n"))
      (with-current-buffer frontend-buf
        (erase-buffer)
        (org-mode)
        (emacs-todoist-frontend-mode 1)
        (insert "* TODO Frontend\n:PROPERTIES:\n:TODOIST_ID: t1\n:END:\n")
        (goto-char (point-min)))
      (unwind-protect
          (progn
            (delete-other-windows)
            (switch-to-buffer frontend-buf)
            (cl-letf (((symbol-function 'pulse-momentary-highlight-one-line)
                       (lambda (point &rest _args)
                         (setq pulse-point point))))
              (emacs-todoist-view-canonical-heading))
            (should pulse-point))
        (when-let* ((source-buf (get-file-buffer source-file)))
          (kill-buffer source-buf))))))

(ert-deftest emacs-todoist-frontend/view-canonical-heading-works-from-agenda ()
  "Canonical heading navigation works from Todoist agenda entries."
  (emacs-todoist-test-with-clean-frontend
    (let* ((source-file (expand-file-name "source.org" org-directory))
           (cache-file (expand-file-name "find-cache.el" org-directory))
           (frontend-buf (emacs-todoist-frontend-ensure-buffer))
           (agenda-buf (get-buffer-create "*Todoist Agenda Test*"))
           (org-refile-targets `((,source-file :maxlevel . 5)))
           (emacs-todoist-find-heading-cache-file cache-file)
           frontend-marker)
      (with-temp-file source-file
        (insert "* TODO Source\n:PROPERTIES:\n:TODOIST_ID: t1\n:END:\n"))
      (with-current-buffer frontend-buf
        (erase-buffer)
        (org-mode)
        (emacs-todoist-frontend-mode 1)
        (insert "* TODO Frontend\n:PROPERTIES:\n:TODOIST_ID: t1\n:END:\n")
        (goto-char (point-min))
        (setq frontend-marker (copy-marker (point) t)))
      (with-current-buffer agenda-buf
        (erase-buffer)
        (org-agenda-mode)
        (emacs-todoist-agenda-mode 1)
        (insert "  TODO Frontend\n")
        (add-text-properties (point-min) (point-max)
                             `(org-hd-marker ,frontend-marker))
        (goto-char (point-min)))
      (unwind-protect
          (progn
            (delete-other-windows)
            (switch-to-buffer agenda-buf)
            (let ((selected (selected-window))
                  (agenda-point (point)))
              (emacs-todoist-view-canonical-heading)
              (should (eq selected (selected-window)))
              (should (eq agenda-buf (current-buffer)))
              (should (= agenda-point (point)))
              (should (get-buffer-window (get-file-buffer source-file) t))))
        (when (buffer-live-p agenda-buf)
          (kill-buffer agenda-buf))
        (when-let* ((source-buf (get-file-buffer source-file)))
          (kill-buffer source-buf))))))

(ert-deftest emacs-todoist-frontend/view-canonical-heading-requires-todoist-id ()
  "Viewing a canonical heading requires a TODOIST_ID at point."
  (emacs-todoist-test-with-clean-frontend
    (let ((frontend-buf (emacs-todoist-frontend-ensure-buffer)))
      (with-current-buffer frontend-buf
        (erase-buffer)
        (org-mode)
        (emacs-todoist-frontend-mode 1)
        (insert "* TODO Frontend\n")
        (goto-char (point-min))
        (should-error (emacs-todoist-view-canonical-heading)
                      :type 'user-error)))))

(ert-deftest emacs-todoist-frontend/view-canonical-heading-errors-when-missing ()
  "Viewing a canonical heading reports when no source heading is found."
  (emacs-todoist-test-with-clean-frontend
    (let ((frontend-buf (emacs-todoist-frontend-ensure-buffer))
          (org-refile-targets nil)
          (emacs-todoist-find-heading-cache-file
           (expand-file-name "find-cache.el" org-directory)))
      (with-current-buffer frontend-buf
        (erase-buffer)
        (org-mode)
        (emacs-todoist-frontend-mode 1)
        (insert "* TODO Frontend\n:PROPERTIES:\n:TODOIST_ID: t1\n:END:\n")
        (goto-char (point-min))
        (should-error (emacs-todoist-view-canonical-heading)
                      :type 'user-error)))))

;;; test-frontend.el ends here
