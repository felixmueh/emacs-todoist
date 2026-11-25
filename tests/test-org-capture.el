;;; test-org-capture.el --- Org capture tests for emacs-todoist -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Felix Mühlenberend
;; SPDX-License-Identifier: GPL-3.0-or-later

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

(ert-deftest emacs-todoist-org-capture/template-defaults-deadline-to-today ()
  "Capture template should default captured tasks to today's deadline."
  (let ((emacs-todoist-org-capture-project nil))
    (should (equal "* TODO %?\nDEADLINE: <%<%Y-%m-%d %a>>\n%i\n%a"
                   (emacs-todoist-org-capture--template-body))))
  (let ((emacs-todoist-org-capture-project "proj-1"))
    (should
     (equal
      "* TODO %?\nDEADLINE: <%<%Y-%m-%d %a>>\n:PROPERTIES:\n:TODOIST_PROJECT: proj-1\n:END:\n%i\n%a"
      (emacs-todoist-org-capture--template-body)))))

(ert-deftest emacs-todoist-org-capture/install-template-idempotent ()
  "Installing template twice should not duplicate the key."
  (let ((org-capture-templates nil)
        (emacs-todoist-org-capture-template-key "T"))
    (emacs-todoist-org-capture-install-template)
    (should (= 1 (length org-capture-templates)))
    (emacs-todoist-org-capture-install-template)
    (should (= 1 (length org-capture-templates)))))

(ert-deftest emacs-todoist-org-capture/command-ensures-frontend-buffer-before-capture ()
  "Capture command keeps the frontend file buffer alive before Org capture."
  (let ((org-capture-templates '(("T" "Todoist todo" entry nil "")))
        (emacs-todoist-org-capture-template-key "T")
        calls)
    (cl-letf (((symbol-function 'emacs-todoist-frontend-ensure-buffer)
               (lambda ()
                 (push 'ensure-buffer calls)
                 (current-buffer)))
              ((symbol-function 'org-capture)
               (lambda (&rest _args)
                 (push 'org-capture calls))))
      (emacs-todoist-org-capture))
    (should (equal '(ensure-buffer org-capture) (nreverse calls)))))

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
                 (lambda (&optional _callback)
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
                 (lambda (&optional _callback)
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

(ert-deftest emacs-todoist-org-capture/after-finalize-notifies-push-success ()
  "Finalize hook notifies when the asynchronous push succeeds."
  (with-temp-buffer
    (org-mode)
    (insert "* TODO Captured\n")
    (goto-char (point-min))
    (let ((emacs-todoist-org-capture--marker (point-marker))
          (org-note-abort nil)
          calls)
      (cl-letf (((symbol-function 'emacs-todoist-push-heading)
                 (lambda (&optional callback)
                   (funcall callback 'success "Captured"
                            "Task pushed to Todoist")))
                ((symbol-function 'emacs-todoist-org-capture--notify-send)
                 (lambda (&rest args)
                   (push args calls))))
        (emacs-todoist-org-capture-after-finalize))
      (should (equal '(("normal"
                        "Todoist capture synced"
                        "Captured\nTask pushed to Todoist"))
                     (nreverse calls))))))

(ert-deftest emacs-todoist-org-capture/after-finalize-notifies-push-failure ()
  "Finalize hook notifies when the asynchronous push fails."
  (with-temp-buffer
    (org-mode)
    (insert "* TODO Captured\n")
    (goto-char (point-min))
    (let ((emacs-todoist-org-capture--marker (point-marker))
          (org-note-abort nil)
          calls)
      (cl-letf (((symbol-function 'emacs-todoist-push-heading)
                 (lambda (&optional callback)
                   (funcall callback 'failure "Captured"
                            "Invalid argument value (code 20)")))
                ((symbol-function 'emacs-todoist-org-capture--notify-send)
                 (lambda (&rest args)
                   (push args calls))))
        (emacs-todoist-org-capture-after-finalize))
      (should (equal '(("critical"
                        "Todoist capture failed"
                        "Captured\nInvalid argument value (code 20)"))
                     (nreverse calls))))))

(ert-deftest emacs-todoist-org-capture/notify-send-starts-process ()
  "Notification helper shells out to notify-send when available."
  (let ((emacs-todoist-org-capture-notify-send t)
        (emacs-todoist-org-capture-notify-send-command "notify-send")
        calls)
    (cl-letf (((symbol-function 'executable-find)
               (lambda (command)
                 (and (equal command "notify-send") "/usr/bin/notify-send")))
              ((symbol-function 'start-process)
               (lambda (&rest args)
                 (push args calls)
                 :process)))
      (emacs-todoist-org-capture--notify-send
       "normal" "Todoist capture synced" "Captured"))
    (should
     (equal '(("emacs-todoist-notify" nil "notify-send"
               "-a" "emacs-todoist"
               "-u" "normal"
               "Todoist capture synced" "Captured"))
            (nreverse calls)))))

(ert-deftest emacs-todoist-org-capture/org-last-stored-marker-is-marker ()
  "Org's capture marker variable must stay a marker object."
  (should (markerp org-capture-last-stored-marker)))

;;; test-org-capture.el ends here
