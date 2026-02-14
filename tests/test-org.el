;;; test-org.el --- Tests for emacs-todoist-org  -*- lexical-binding: t; -*-

(require 'ert)
(require 'emacs-todoist-org)

;; ==============================================================================
;; Test helpers
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
;; Smoke test
;; ==============================================================================

(ert-deftest emacs-todoist-org-smoke-test ()
  "Trivial smoke test to verify test infrastructure works."
  (should (featurep 'emacs-todoist-org)))

;; ==============================================================================
;; Title extraction
;; ==============================================================================

(ert-deftest emacs-todoist-org-title-plain ()
  "Plain heading returns just the title text."
  (with-org-buffer "* Buy groceries"
    (should (equal (emacs-todoist-org-heading-title) "Buy groceries"))))

(ert-deftest emacs-todoist-org-title-strips-todo ()
  "TODO keyword is excluded from the title."
  (with-org-buffer "* TODO Buy groceries"
    (should (equal (emacs-todoist-org-heading-title) "Buy groceries"))))

(ert-deftest emacs-todoist-org-title-strips-priority ()
  "Priority cookie is excluded from the title."
  (with-org-buffer "* TODO [#A] Buy groceries"
    (should (equal (emacs-todoist-org-heading-title) "Buy groceries"))))

(ert-deftest emacs-todoist-org-title-strips-tags ()
  "Tags are excluded from the title."
  (with-org-buffer "* TODO Buy groceries :errands:food:"
    (should (equal (emacs-todoist-org-heading-title) "Buy groceries"))))

;; ==============================================================================
;; Deadline extraction
;; ==============================================================================

(ert-deftest emacs-todoist-org-deadline-present ()
  "Deadline is returned as a YYYY-MM-DD string."
  (with-org-buffer "* TODO Buy groceries\nDEADLINE: <2026-01-15 Thu>\n"
    (should (equal (emacs-todoist-org-heading-deadline) "2026-01-15"))))

(ert-deftest emacs-todoist-org-deadline-absent ()
  "Returns nil when no deadline is set."
  (with-org-buffer "* TODO Buy groceries\n"
    (should (null (emacs-todoist-org-heading-deadline)))))

;; ==============================================================================
;; Description extraction
;; ==============================================================================

(ert-deftest emacs-todoist-org-description-no-body ()
  "Heading with no body returns empty string."
  (with-org-buffer "* A heading\n"
    (should (equal (emacs-todoist-org-heading-description) ""))))

(ert-deftest emacs-todoist-org-description-only-property-drawer ()
  "Heading with only a property drawer returns empty string."
  (with-org-buffer
      "* A heading\n:PROPERTIES:\n:TODOIST_ID: 123\n:END:\n"
    (should (equal (emacs-todoist-org-heading-description) ""))))

(ert-deftest emacs-todoist-org-description-body-text ()
  "Returns the body text of a heading."
  (with-org-buffer
      "* A heading\nSome body text here.\n"
    (should (equal (emacs-todoist-org-heading-description)
                   "Some body text here."))))

(ert-deftest emacs-todoist-org-description-excludes-subheadings ()
  "Description does not include sub-heading content."
  (with-org-buffer
      "* Parent\nParent body.\n** Child\nChild body.\n"
    (should (equal (emacs-todoist-org-heading-description)
                   "Parent body."))))

(ert-deftest emacs-todoist-org-description-excludes-planning-lines ()
  "DEADLINE and SCHEDULED lines are excluded from the description."
  (with-org-buffer
      "* TODO A heading\nDEADLINE: <2026-01-15 Thu> SCHEDULED: <2026-01-10 Sat>\nThe actual description.\n"
    (should (equal (emacs-todoist-org-heading-description)
                   "The actual description."))))

(ert-deftest emacs-todoist-org-description-preserves-code-blocks ()
  "Code blocks in the body are preserved in the description."
  (with-org-buffer
      "* A heading\nBefore code.\n#+begin_src python\nprint(\"hello\")\n#+end_src\nAfter code.\n"
    (let ((desc (emacs-todoist-org-heading-description)))
      (should (string-match-p "begin_src python" desc))
      (should (string-match-p "print" desc))
      (should (string-match-p "Before code" desc))
      (should (string-match-p "After code" desc)))))

(ert-deftest emacs-todoist-org-description-with-drawer-and-planning ()
  "Description is extracted correctly when both drawer and planning are present."
  (with-org-buffer
      "* TODO Task\nDEADLINE: <2026-02-01 Sun>\n:PROPERTIES:\n:TODOIST_ID: abc\n:END:\nActual body text.\n"
    (should (equal (emacs-todoist-org-heading-description)
                   "Actual body text."))))

;; ==============================================================================
;; TODO state
;; ==============================================================================

(ert-deftest emacs-todoist-org-todo-state-present ()
  "Returns the TODO state string."
  (with-org-buffer "* TODO Buy groceries\n"
    (should (equal (emacs-todoist-org-heading-todo-state) "TODO"))))

(ert-deftest emacs-todoist-org-todo-state-done ()
  "Returns DONE state."
  (with-org-buffer "* DONE Buy groceries\n"
    (should (equal (emacs-todoist-org-heading-todo-state) "DONE"))))

(ert-deftest emacs-todoist-org-todo-state-absent ()
  "Returns nil when no TODO state."
  (with-org-buffer "* Buy groceries\n"
    (should (null (emacs-todoist-org-heading-todo-state)))))

;; ==============================================================================
;; Properties
;; ==============================================================================

(ert-deftest emacs-todoist-org-props-round-trip ()
  "set-props then heading-props round-trips correctly."
  (with-org-buffer "* A heading\n"
    (emacs-todoist-org-set-props
     '(("TODOIST_ID" . "12345") ("TODOIST_PROJECT" . "Inbox")))
    (let ((props (emacs-todoist-org-heading-props)))
      (should (equal (alist-get "TODOIST_ID" props nil nil #'equal) "12345"))
      (should (equal (alist-get "TODOIST_PROJECT" props nil nil #'equal) "Inbox")))))

(ert-deftest emacs-todoist-org-props-only-todoist ()
  "Only TODOIST_* properties are returned, not other custom properties."
  (with-org-buffer
      "* A heading\n:PROPERTIES:\n:CATEGORY: work\n:TODOIST_ID: 99\n:END:\n"
    (let ((props (emacs-todoist-org-heading-props)))
      (should (= (length props) 1))
      (should (equal (caar props) "TODOIST_ID")))))

;; ==============================================================================
;; Hash
;; ==============================================================================

(ert-deftest emacs-todoist-org-hash-stability ()
  "Same input produces the same hash (deterministic)."
  (with-org-buffer "* TODO Buy groceries\nDEADLINE: <2026-01-15 Thu>\nSome notes.\n"
    (let ((h1 (emacs-todoist-org-heading-local-hash))
          (h2 (emacs-todoist-org-heading-local-hash)))
      (should (equal h1 h2)))))

(ert-deftest emacs-todoist-org-hash-changes-with-title ()
  "Changing the title produces a different hash."
  (let (h1 h2)
    (with-org-buffer "* TODO Buy groceries\n"
      (setq h1 (emacs-todoist-org-heading-local-hash)))
    (with-org-buffer "* TODO Sell groceries\n"
      (setq h2 (emacs-todoist-org-heading-local-hash)))
    (should-not (equal h1 h2))))

(ert-deftest emacs-todoist-org-hash-changes-with-deadline ()
  "Changing the deadline produces a different hash."
  (let (h1 h2)
    (with-org-buffer "* TODO Task\nDEADLINE: <2026-01-15 Thu>\n"
      (setq h1 (emacs-todoist-org-heading-local-hash)))
    (with-org-buffer "* TODO Task\nDEADLINE: <2026-02-20 Fri>\n"
      (setq h2 (emacs-todoist-org-heading-local-hash)))
    (should-not (equal h1 h2))))

(ert-deftest emacs-todoist-org-hash-changes-with-description ()
  "Changing the description produces a different hash."
  (let (h1 h2)
    (with-org-buffer "* TODO Task\nBody A.\n"
      (setq h1 (emacs-todoist-org-heading-local-hash)))
    (with-org-buffer "* TODO Task\nBody B.\n"
      (setq h2 (emacs-todoist-org-heading-local-hash)))
    (should-not (equal h1 h2))))

(ert-deftest emacs-todoist-org-hash-changes-with-todo-state ()
  "Changing the TODO state produces a different hash."
  (let (h1 h2)
    (with-org-buffer "* TODO Task\n"
      (setq h1 (emacs-todoist-org-heading-local-hash)))
    (with-org-buffer "* DONE Task\n"
      (setq h2 (emacs-todoist-org-heading-local-hash)))
    (should-not (equal h1 h2))))

;; ==============================================================================
;; heading-local-changed-p
;; ==============================================================================

(ert-deftest emacs-todoist-org-changed-p-no-stored-hash ()
  "Returns t when no stored hash exists."
  (with-org-buffer "* TODO Task\n"
    (should (eq t (emacs-todoist-org-heading-local-changed-p)))))

(ert-deftest emacs-todoist-org-changed-p-matching-hash ()
  "Returns nil when stored hash matches current."
  (with-org-buffer "* TODO Task\n"
    (let ((hash (emacs-todoist-org-heading-local-hash)))
      (org-entry-put (point) "TODOIST_LOCAL_HASH" hash)
      (should-not (emacs-todoist-org-heading-local-changed-p)))))

;; ==============================================================================
;; Children
;; ==============================================================================

(ert-deftest emacs-todoist-org-children-direct-only ()
  "Returns markers for direct children only, not grandchildren."
  (with-org-buffer
      "* Parent\n** Child 1\n*** Grandchild\n** Child 2\n"
    (let ((children (emacs-todoist-org-heading-children)))
      (should (= (length children) 2)))))

(ert-deftest emacs-todoist-org-children-none ()
  "Returns empty list when heading has no children."
  (with-org-buffer "* Leaf heading\n"
    (should (null (emacs-todoist-org-heading-children)))))

;; ==============================================================================
;; apply-remote
;; ==============================================================================

(ert-deftest emacs-todoist-org-apply-remote-updates-all ()
  "apply-remote correctly updates title, body, deadline, and TODO state."
  (with-org-buffer "* TODO Old title\nOld body.\n"
    (emacs-todoist-org-apply-remote
     '((content . "New title")
       (description . "New body text.")
       (due . ((date . "2026-03-01")))
       (checked . 1)))
    ;; Verify updates
    (should (equal (emacs-todoist-org-heading-title) "New title"))
    (should (equal (emacs-todoist-org-heading-description) "New body text."))
    (should (equal (emacs-todoist-org-heading-deadline) "2026-03-01"))
    (should (equal (emacs-todoist-org-heading-todo-state) "DONE"))))

(ert-deftest emacs-todoist-org-apply-remote-removes-deadline ()
  "apply-remote removes deadline when remote has no due date."
  (with-org-buffer "* TODO Task\nDEADLINE: <2026-01-15 Thu>\n"
    (emacs-todoist-org-apply-remote
     '((content . "Task")
       (description . "")
       (due)
       (checked . 0)))
    (should (null (emacs-todoist-org-heading-deadline)))))

(ert-deftest emacs-todoist-org-apply-remote-unchecked ()
  "apply-remote sets TODO state when checked is 0."
  (with-org-buffer "* DONE Task\n"
    (emacs-todoist-org-apply-remote
     '((content . "Task")
       (description . "")
       (due)
       (checked . 0)))
    (should (equal (emacs-todoist-org-heading-todo-state) "TODO"))))

;; ==============================================================================
;; resolve-project
;; ==============================================================================

(ert-deftest emacs-todoist-org-resolve-project-heading-property ()
  "Heading TODOIST_PROJECT property takes priority."
  (with-org-buffer
      "#+TODOIST_PROJECT: FileProject\n* A heading\n:PROPERTIES:\n:TODOIST_PROJECT: HeadingProject\n:END:\n"
    ;; Navigate to the heading (after the keyword line).
    (goto-char (point-min))
    (re-search-forward "^\\*")
    (beginning-of-line)
    (let ((emacs-todoist-default-project "DefaultProject"))
      (should (equal (emacs-todoist-org-resolve-project) "HeadingProject")))))

(ert-deftest emacs-todoist-org-resolve-project-file-keyword ()
  "File keyword is used when no heading property exists."
  (with-org-buffer
      "#+TODOIST_PROJECT: FileProject\n* A heading\n"
    (goto-char (point-min))
    (re-search-forward "^\\*")
    (beginning-of-line)
    (let ((emacs-todoist-default-project "DefaultProject"))
      (should (equal (emacs-todoist-org-resolve-project) "FileProject")))))

(ert-deftest emacs-todoist-org-resolve-project-default ()
  "Global default is used when no other source is available."
  (with-org-buffer "* A heading\n"
    (let ((emacs-todoist-default-project "DefaultProject"))
      (should (equal (emacs-todoist-org-resolve-project) "DefaultProject")))))

(ert-deftest emacs-todoist-org-resolve-project-nil ()
  "Returns nil when no source provides a project."
  (with-org-buffer "* A heading\n"
    (let ((emacs-todoist-default-project nil))
      (should (null (emacs-todoist-org-resolve-project))))))

;; ==============================================================================
;; synced-entries
;; ==============================================================================

(ert-deftest emacs-todoist-org-synced-entries-returns-only-synced ()
  "Returns markers only for headings with TODOIST_ID."
  (with-org-buffer
      "* Unsynced heading\n* Synced heading\n:PROPERTIES:\n:TODOIST_ID: 42\n:END:\n* Another unsynced\n"
    (let ((entries (emacs-todoist-org-synced-entries)))
      (should (= (length entries) 1))
      ;; Verify the marker points to the synced heading.
      (goto-char (car entries))
      (should (equal (emacs-todoist-org-heading-title) "Synced heading")))))

(ert-deftest emacs-todoist-org-synced-entries-multiple ()
  "Returns multiple markers when several headings are synced."
  (with-org-buffer
      (concat "* H1\n:PROPERTIES:\n:TODOIST_ID: 1\n:END:\n"
              "* H2\n"
              "* H3\n:PROPERTIES:\n:TODOIST_ID: 3\n:END:\n")
    (let ((entries (emacs-todoist-org-synced-entries)))
      (should (= (length entries) 2)))))

(ert-deftest emacs-todoist-org-synced-entries-none ()
  "Returns empty list when no headings are synced."
  (with-org-buffer "* H1\n* H2\n"
    (should (null (emacs-todoist-org-synced-entries)))))

;; ==============================================================================
;; heading-to-alist
;; ==============================================================================

(ert-deftest emacs-todoist-org-heading-to-alist-complete ()
  "Returns correct alist with all fields."
  (with-org-buffer
      "#+TODOIST_PROJECT: TestProj\n* TODO Buy groceries\nDEADLINE: <2026-01-15 Thu>\nShopping list.\n** Milk\n** Eggs\n"
    ;; Navigate to the top-level heading.
    (goto-char (point-min))
    (re-search-forward "^\\*[^*]")
    (beginning-of-line)
    (let* ((emacs-todoist-default-project nil)
           (alist (emacs-todoist-org-heading-to-alist)))
      (should (equal (alist-get 'title alist) "Buy groceries"))
      (should (equal (alist-get 'description alist) "Shopping list."))
      (should (equal (alist-get 'deadline alist) "2026-01-15"))
      (should (equal (alist-get 'todo-state alist) "TODO"))
      (should (= (length (alist-get 'children alist)) 2))
      (should (equal (alist-get 'project alist) "TestProj")))))

;; ==============================================================================
;; todo-entries
;; ==============================================================================

(ert-deftest emacs-todoist-org-todo-entries-finds-all ()
  "Returns markers for all TODO/DONE headings, skipping plain headings."
  (with-org-buffer
      (concat "* TODO Task A\n"
              "* Plain heading\n"
              "* DONE Task B\n"
              "* TODO Task C\n")
    (let ((entries (emacs-todoist-org-todo-entries)))
      (should (= 3 (length entries))))))

(ert-deftest emacs-todoist-org-todo-entries-empty-buffer ()
  "Returns nil when buffer has no TODO headings."
  (with-org-buffer "* Just a heading\n* Another one\n"
    (should (null (emacs-todoist-org-todo-entries)))))

;; ==============================================================================
;; todo-entries-in-region
;; ==============================================================================

(ert-deftest emacs-todoist-org-todo-entries-in-region-limits-scope ()
  "Returns only TODO headings within the specified region."
  (with-org-buffer
      (concat "* TODO Outside before\n"
              "* TODO Inside A\n"
              "* TODO Inside B\n"
              "* Plain inside\n"
              "* TODO Outside after\n")
    ;; Find the region boundaries around "Inside A" and "Inside B".
    (goto-char (point-min))
    (re-search-forward "^\\* TODO Inside A")
    (beginning-of-line)
    (let ((beg (point)))
      (re-search-forward "^\\* TODO Outside after")
      (beginning-of-line)
      (let* ((end (point))
             (entries (emacs-todoist-org-todo-entries-in-region beg end)))
        (should (= 2 (length entries)))))))

;; ==============================================================================
;; todo-entries-in-subtree
;; ==============================================================================

(ert-deftest emacs-todoist-org-todo-entries-in-subtree-nested ()
  "Returns TODO headings in the subtree at point, including the root."
  (with-org-buffer
      (concat "* TODO Parent\n"
              "** TODO Child A\n"
              "** Plain child\n"
              "** TODO Child B\n"
              "* TODO Sibling (outside)\n")
    (let ((entries (emacs-todoist-org-todo-entries-in-subtree)))
      (should (= 3 (length entries))))))

;; ==============================================================================
;; synced-entries-in-region
;; ==============================================================================

(ert-deftest emacs-todoist-org-synced-entries-in-region-limits-scope ()
  "Returns only TODOIST_ID headings within the specified region."
  (with-org-buffer
      (concat "* H1\n:PROPERTIES:\n:TODOIST_ID: 1\n:END:\n"
              "* H2\n:PROPERTIES:\n:TODOIST_ID: 2\n:END:\n"
              "* H3\n"
              "* H4\n:PROPERTIES:\n:TODOIST_ID: 4\n:END:\n")
    ;; Region covers H2 and H3 only.
    (goto-char (point-min))
    (re-search-forward "^\\* H2")
    (beginning-of-line)
    (let ((beg (point)))
      (re-search-forward "^\\* H4")
      (beginning-of-line)
      (let* ((end (point))
             (entries (emacs-todoist-org-synced-entries-in-region beg end)))
        (should (= 1 (length entries)))))))

;; ==============================================================================
;; synced-entries-in-subtree
;; ==============================================================================

(ert-deftest emacs-todoist-org-synced-entries-in-subtree-nested ()
  "Returns synced headings within the subtree at point."
  (with-org-buffer
      (concat "* Parent\n:PROPERTIES:\n:TODOIST_ID: 1\n:END:\n"
              "** Child synced\n:PROPERTIES:\n:TODOIST_ID: 2\n:END:\n"
              "** Child plain\n"
              "* Sibling\n:PROPERTIES:\n:TODOIST_ID: 3\n:END:\n")
    (let ((entries (emacs-todoist-org-synced-entries-in-subtree)))
      (should (= 2 (length entries))))))

;;; test-org.el ends here
