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

(ert-deftest emacs-todoist-org-capture/after-finalize-routes-to-frontend ()
  "Finalize hook routes capture via frontend processor when enabled."
  (with-temp-buffer
    (org-mode)
    (insert "* TODO Task\n")
    (goto-char (point-min))
    (let ((emacs-todoist-org-capture--marker (point-marker))
          (emacs-todoist-org-capture-route-to-frontend t)
          (org-note-abort nil)
          (seen-marker nil))
      (cl-letf (((symbol-function 'emacs-todoist--capture-process-marker)
                 (lambda (marker)
                   (setq seen-marker marker)
                   t))
                ((symbol-function 'emacs-todoist-push-heading)
                 (lambda ()
                   (error "Should not push directly when routing succeeds"))))
        (emacs-todoist-org-capture-after-finalize))
      (should (markerp seen-marker))
      (should-not emacs-todoist-org-capture--marker))))

(ert-deftest emacs-todoist-org-capture/after-finalize-falls-back-to-push ()
  "Finalize hook falls back to direct push when routing does not apply."
  (with-temp-buffer
    (org-mode)
    (insert "* TODO Task\n")
    (goto-char (point-min))
    (let ((emacs-todoist-org-capture--marker (point-marker))
          (emacs-todoist-org-capture-route-to-frontend t)
          (org-note-abort nil)
          (push-called nil))
      (cl-letf (((symbol-function 'emacs-todoist--capture-process-marker)
                 (lambda (_marker) nil))
                ((symbol-function 'emacs-todoist-push-heading)
                 (lambda ()
                   (setq push-called t))))
        (emacs-todoist-org-capture-after-finalize))
      (should push-called))))

(ert-deftest emacs-todoist-org-capture/no-global-after-finalize-hook ()
  "Core package should not globally hook capture finalize behavior."
  (should-not (memq #'emacs-todoist--capture-after-finalize
                    org-capture-after-finalize-hook)))

(ert-deftest emacs-todoist-org-capture/org-last-stored-marker-is-marker ()
  "Org's capture marker variable must stay a marker object."
  (should (markerp org-capture-last-stored-marker)))

;;; test-org-capture.el ends here
