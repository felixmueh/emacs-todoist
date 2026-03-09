;;; test-org-capture.el --- Org capture tests for emacs-todoist -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'org)
(require 'org-capture)
(require 'emacs-todoist-org-capture)

(ert-deftest emacs-todoist-org-capture/template-builds-hooks ()
  "Template builder returns expected hook wiring."
  (let* ((emacs-todoist-org-capture-template-key "T")
         (tpl (emacs-todoist-org-capture-template))
         (props (nthcdr 5 tpl)))
    (should (equal "T" (nth 0 tpl)))
    (should (equal 'entry (nth 2 tpl)))
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

(ert-deftest emacs-todoist-org-capture/after-finalize-dispatches-marker ()
  "Finalize hook dispatches stored marker ownership within capture module."
  (with-temp-buffer
    (org-mode)
    (insert "* TODO Task\n")
    (goto-char (point-min))
    (let ((emacs-todoist-org-capture--marker (point-marker))
          (org-note-abort nil)
          (seen-marker nil))
      (cl-letf (((symbol-function 'emacs-todoist-org-capture--dispatch-finalize)
                 (lambda (marker)
                   (setq seen-marker marker)
                   t)))
        (emacs-todoist-org-capture-after-finalize))
      (should (markerp seen-marker))
      (should-not emacs-todoist-org-capture--marker))))

(ert-deftest emacs-todoist-org-capture/process-or-push-falls-back-to-push ()
  "Capture processing pushes in place when frontend relocation does not apply."
  (with-temp-buffer
    (org-mode)
    (insert "* TODO Task\n")
    (goto-char (point-min))
    (let ((push-called nil))
      (cl-letf (((symbol-function 'emacs-todoist-org-capture--process-marker)
                 (lambda (_marker) nil))
                ((symbol-function 'emacs-todoist-push-heading)
                 (lambda ()
                   (setq push-called t))))
        (emacs-todoist-org-capture--process-or-push (point-marker)))
      (should push-called))))

(ert-deftest emacs-todoist-org-capture/dispatch-finalize-defers-in-interactive ()
  "Interactive finalize dispatch defers processing until command-loop continuation."
  (with-temp-buffer
    (org-mode)
    (insert "* TODO Task\n")
    (goto-char (point-min))
    (let ((noninteractive nil)
          (processed-marker nil))
      (setq emacs-todoist-org-capture--deferred-thunks nil)
      (remove-hook 'post-command-hook #'emacs-todoist-org-capture--flush-deferred)
      (unwind-protect
          (cl-letf (((symbol-function 'emacs-todoist-org-capture--process-or-push)
                     (lambda (marker)
                       (setq processed-marker marker))))
            (emacs-todoist-org-capture--dispatch-finalize (point-marker))
            (should-not processed-marker)
            (emacs-todoist-org-capture--flush-deferred)
            (should (markerp processed-marker)))
        (setq emacs-todoist-org-capture--deferred-thunks nil)
        (remove-hook 'post-command-hook #'emacs-todoist-org-capture--flush-deferred)))))

(ert-deftest emacs-todoist-org-capture/no-global-after-finalize-hook ()
  "Capture module should not globally hook capture finalize behavior."
  (should-not (memq #'emacs-todoist-org-capture-after-finalize
                    org-capture-after-finalize-hook)))

(ert-deftest emacs-todoist-org-capture/org-last-stored-marker-is-marker ()
  "Org's capture marker variable must stay a marker object."
  (should (markerp org-capture-last-stored-marker)))

;;; test-org-capture.el ends here
