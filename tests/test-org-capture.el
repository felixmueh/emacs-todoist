;;; test-org-capture.el --- Org capture tests for emacs-todoist -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'org)
(require 'org-capture)
(require 'emacs-todoist-org-capture)

(ert-deftest emacs-todoist-org-capture/template-builds-hooks-and-frontend-target ()
  "Template builder returns expected hook wiring and frontend target."
  (let* ((org-directory "/tmp/emacs-todoist-tests")
         (emacs-todoist-frontend-file-name "todoist.org")
         (tpl (emacs-todoist-org-capture-template))
         (target (nth 3 tpl))
         (props (nthcdr 5 tpl)))
    (should (equal 'entry (nth 2 tpl)))
    (should (equal 'file+function (nth 0 target)))
    (should (equal (expand-file-name "todoist.org" org-directory)
                   (nth 1 target)))
    (should (eq #'emacs-todoist-org-capture--goto-target-headline
                (nth 2 target)))
    (should (eq #'emacs-todoist-org-capture-before-finalize
                (plist-get props :before-finalize)))
    (should (eq #'emacs-todoist-org-capture-after-finalize
                (plist-get props :after-finalize)))))

(ert-deftest emacs-todoist-org-capture/install-template-idempotent ()
  "Installing template twice should not duplicate the key."
  (let ((org-capture-templates nil)
        (emacs-todoist-org-capture-template-key "T"))
    (emacs-todoist-org-capture-install-template)
    (should (= 1 (length org-capture-templates)))
    (emacs-todoist-org-capture-install-template)
    (should (= 1 (length org-capture-templates)))))

(ert-deftest emacs-todoist-org-capture/after-finalize-pushes-marker-directly ()
  "Finalize hook pushes the captured heading in place."
  (with-temp-buffer
    (org-mode)
    (insert "* Inbox\n:PROPERTIES:\n:TODOIST_PROJECT: proj-1\n:END:\n** TODO Task\n")
    (goto-char (point-min))
    (re-search-forward "^\\*\\* TODO Task$")
    (beginning-of-line)
    (let ((emacs-todoist-org-capture--marker (point-marker))
          (org-note-abort nil)
          (push-called nil))
      (cl-letf (((symbol-function 'emacs-todoist-push-heading)
                 (lambda ()
                   (setq push-called t))))
        (emacs-todoist-org-capture-after-finalize))
      (should push-called)
      (should (equal "proj-1" (org-entry-get (point) "TODOIST_PROJECT")))
      (should-not emacs-todoist-org-capture--marker))))

(ert-deftest emacs-todoist-org-capture/before-finalize-tracks-capture-root ()
  "Before-finalize stores root marker even when point is on a child."
  (with-temp-buffer
    (org-mode)
    (insert "* Inbox\n** TODO Parent\n*** TODO Child\n")
    (goto-char (point-min))
    (re-search-forward "^\\*\\*\\* TODO Child$")
    (beginning-of-line)
    (let ((begin-marker (save-excursion
                          (re-search-backward "^\\*\\* TODO Parent$")
                          (point-marker)))
          (end-marker (copy-marker (point-max) t)))
      (cl-letf (((symbol-function 'org-capture-get)
                 (lambda (property &optional _local)
                   (pcase property
                     (:begin-marker begin-marker)
                     (:end-marker end-marker)
                     (_ nil)))))
        (setq emacs-todoist-org-capture--marker nil)
        (emacs-todoist-org-capture-before-finalize)
        (should (markerp emacs-todoist-org-capture--marker))
        (save-excursion
          (goto-char emacs-todoist-org-capture--marker)
          (should (equal "Parent" (org-get-heading t t t t))))))))

(ert-deftest emacs-todoist-org-capture/after-finalize-ignores-aborted-capture ()
  "Finalize hook does nothing when capture was aborted."
  (with-temp-buffer
    (org-mode)
    (insert "* TODO Task\n")
    (goto-char (point-min))
    (let ((emacs-todoist-org-capture--marker (point-marker))
          (org-note-abort t)
          (push-called nil))
      (cl-letf (((symbol-function 'emacs-todoist-push-heading)
                 (lambda ()
                   (setq push-called t))))
        (emacs-todoist-org-capture-after-finalize))
      (should-not push-called)
      (should-not emacs-todoist-org-capture--marker))))

(ert-deftest emacs-todoist-org-capture/goto-target-headline-creates-container ()
  "Target locator creates the frontend container heading when missing."
  (with-temp-buffer
    (org-mode)
    (let ((emacs-todoist-org-capture-project "proj-1"))
      (emacs-todoist-org-capture--goto-target-headline)
      (should (equal "proj-1" (org-get-heading t t t t)))
      (should (equal "proj-1" (org-entry-get (point) "TODOIST_PROJECT"))))))

(ert-deftest emacs-todoist-org-capture/no-global-after-finalize-hook ()
  "Capture module should not globally hook capture finalize behavior."
  (should-not (memq #'emacs-todoist-org-capture-after-finalize
                    org-capture-after-finalize-hook)))

(ert-deftest emacs-todoist-org-capture/org-last-stored-marker-is-marker ()
  "Org's capture marker variable must stay a marker object."
  (should (markerp org-capture-last-stored-marker)))

;;; test-org-capture.el ends here
