;;; emacs-todoist-org-capture.el --- Org capture templates for emacs-todoist -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Felix Mühlenberend

;; Author: Felix Mühlenberend <felix.muehlenberend@mailbox.org>
;; Keywords: outlines, convenience, comm
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Provides a dedicated Org capture template for Todoist workflows.
;;
;; Only captures using this template trigger automatic push to Todoist.
;; The template writes directly into the frontend file so no post-capture
;; relocation step is needed.

;;; Code:

(require 'cl-lib)
(require 'org-capture)
(require 'emacs-todoist)
(require 'emacs-todoist-frontend)

;; Defined in org.el; declared here so it is bound dynamically.
(defvar org-note-abort)

(defgroup emacs-todoist-org-capture nil
  "Org capture integration for emacs-todoist." 
  :group 'emacs-todoist)

(defcustom emacs-todoist-org-capture-template-key "T"
  "Capture template key for Todoist captures."
  :type 'string
  :group 'emacs-todoist-org-capture)

(defcustom emacs-todoist-org-capture-template-name "Todoist todo"
  "Display name for the Todoist capture template."
  :type 'string
  :group 'emacs-todoist-org-capture)

(defcustom emacs-todoist-org-capture-target-headline "Inbox"
  "Fallback headline where Todoist captures are stored in the frontend file."
  :type 'string
  :group 'emacs-todoist-org-capture)

(defcustom emacs-todoist-org-capture-project nil
  "Optional project name or numeric ID written as TODOIST_PROJECT.
When nil, project resolution uses normal heading/file/default fallback."
  :type '(choice (const nil) string)
  :group 'emacs-todoist-org-capture)

(defcustom emacs-todoist-org-capture-notify-send t
  "When non-nil, notify Todoist capture push results with notify-send."
  :type 'boolean
  :group 'emacs-todoist-org-capture)

(defcustom emacs-todoist-org-capture-notify-send-command "notify-send"
  "Command used to send desktop notifications for Todoist capture results."
  :type 'string
  :group 'emacs-todoist-org-capture)

(defvar emacs-todoist-org-capture--marker nil
  "Marker for the heading currently being finalized by Todoist capture.")

(defun emacs-todoist-org-capture--target-project ()
  "Return the configured Todoist project string for capture, or nil."
  (or emacs-todoist-org-capture-project
      emacs-todoist-default-project))

(defun emacs-todoist-org-capture--target-headline ()
  "Return the frontend headline used for Todoist capture."
  (or (emacs-todoist-org-capture--target-project)
      emacs-todoist-org-capture-target-headline))

(defun emacs-todoist-org-capture--goto-target-headline ()
  "Move point to the frontend capture container, creating it if needed."
  (emacs-todoist--frontend-setup-buffer t)
  (let ((headline (emacs-todoist-org-capture--target-headline))
        (project (emacs-todoist-org-capture--target-project)))
    (goto-char (point-min))
    (if (re-search-forward (format org-complex-heading-regexp-format
                                   (regexp-quote headline))
                           nil t)
        (forward-line 0)
      (goto-char (point-max))
      (unless (bolp)
        (insert "\n"))
      (insert "* " headline "\n")
      (forward-line -1))
    (when project
      (org-entry-put (point) "TODOIST_PROJECT" (format "%s" project)))))

(defun emacs-todoist-org-capture--template-body ()
  "Return template body string for Todoist captures."
  (if-let* ((project (emacs-todoist-org-capture--target-project)))
      (format "* TODO %%?\nDEADLINE: <%%<%%Y-%%m-%%d %%a>>\n:PROPERTIES:\n:TODOIST_PROJECT: %s\n:END:\n%%i\n%%a"
              project)
    "* TODO %?\nDEADLINE: <%<%Y-%m-%d %a>>\n%i\n%a"))

(defun emacs-todoist-org-capture-before-finalize ()
  "Capture marker-saving hook for the Todoist capture template.
Stores the captured root heading marker in the base buffer.

The marker uses the capture region's begin marker so finalization still
pushes the whole captured heading (and children) when point is on a
child heading."
  (save-excursion
    (let* ((base-buf (or (buffer-base-buffer) (current-buffer)))
           (begin (org-capture-get :begin-marker 'local))
           (end (org-capture-get :end-marker 'local))
           (pos
            (cond
             ((and (markerp begin) (marker-buffer begin))
              (goto-char begin)
              (unless (org-at-heading-p)
                (let ((end-pos (when (and (markerp end) (marker-buffer end))
                                 (marker-position end))))
                  (when (re-search-forward org-heading-regexp end-pos t)
                    (goto-char (match-beginning 0)))))
              (if (org-at-heading-p)
                  (point)
                (progn
                  (org-back-to-heading t)
                  (point))))
             (t
              (org-back-to-heading t)
              (point)))))
      (setq emacs-todoist-org-capture--marker
            (with-current-buffer base-buf
              (copy-marker pos t))))))

(defun emacs-todoist-org-capture--ensure-heading-project ()
  "Copy project information onto the captured heading when available."
  (unless (org-entry-get (point) "TODOIST_PROJECT")
    (let ((parent-project
           (save-excursion
             (when (org-up-heading-safe)
               (org-entry-get (point) "TODOIST_PROJECT")))))
      (when-let* ((project (or parent-project
                               (emacs-todoist-org-capture--target-project))))
        (org-entry-put (point) "TODOIST_PROJECT" (format "%s" project))))))

(defun emacs-todoist-org-capture--push-in-place (marker)
  "Push captured heading at MARKER directly to Todoist."
  (when (and (markerp marker) (marker-buffer marker))
    (with-current-buffer (marker-buffer marker)
      (save-excursion
        (goto-char marker)
        (when (org-get-todo-state)
          (emacs-todoist-org-capture--ensure-heading-project)
          (emacs-todoist-push-heading
           #'emacs-todoist-org-capture--notify-push-result))))))

(defun emacs-todoist-org-capture--notify-send (urgency title body)
  "Send a notify-send notification with URGENCY, TITLE, and BODY."
  (when (and emacs-todoist-org-capture-notify-send
             (executable-find emacs-todoist-org-capture-notify-send-command))
    (let ((process-connection-type nil))
      (ignore-errors
        (start-process
         "emacs-todoist-notify" nil
         emacs-todoist-org-capture-notify-send-command
         "-a" "emacs-todoist"
         "-u" urgency
         title body)))))

(defun emacs-todoist-org-capture--notify-push-result (status title detail)
  "Notify the user about a Todoist capture push result.
STATUS is `success' or `failure'.  TITLE is the captured task title.
DETAIL is a short result string."
  (pcase status
    ('success
     (emacs-todoist-org-capture--notify-send
      "normal"
      "Todoist capture synced"
      (format "%s\n%s" title detail)))
    ('failure
     (emacs-todoist-org-capture--notify-send
      "critical"
      "Todoist capture failed"
      (format "%s\n%s" title detail)))))

(defun emacs-todoist-org-capture-after-finalize ()
  "Finalize hook for Todoist capture template.
Only entries captured with this template trigger this hook behavior."
  (let ((marker emacs-todoist-org-capture--marker))
    (setq emacs-todoist-org-capture--marker nil)
    (when (and marker (not org-note-abort) (marker-buffer marker))
      (emacs-todoist-org-capture--push-in-place marker))))

(defun emacs-todoist-org-capture-template ()
  "Return the capture template definition for Todoist captures."
  (list emacs-todoist-org-capture-template-key
        emacs-todoist-org-capture-template-name
        'entry
        (list 'file+function
              (emacs-todoist-frontend-file-path)
              #'emacs-todoist-org-capture--goto-target-headline)
        (emacs-todoist-org-capture--template-body)
        :prepend t
        :before-finalize #'emacs-todoist-org-capture-before-finalize
        :after-finalize #'emacs-todoist-org-capture-after-finalize))

(defun emacs-todoist-org-capture--template-installed-p ()
  "Return non-nil if the Todoist capture template key is already in use."
  (cl-some (lambda (tpl)
             (and (consp tpl)
                  (equal emacs-todoist-org-capture-template-key (car tpl))))
           org-capture-templates))

;;;###autoload
(defun emacs-todoist-org-capture-install-template (&optional append)
  "Install the Todoist capture template into `org-capture-templates'.
With APPEND non-nil, append template to the list instead of prepending."
  (interactive "P")
  (unless (emacs-todoist-org-capture--template-installed-p)
    (add-to-list 'org-capture-templates
                 (emacs-todoist-org-capture-template)
                 append)))

;;;###autoload
(defun emacs-todoist-org-capture ()
  "Invoke org-capture with the Todoist template key."
  (interactive)
  (unless (emacs-todoist-org-capture--template-installed-p)
    (emacs-todoist-org-capture-install-template t))
  (emacs-todoist-frontend-ensure-buffer)
  (org-capture nil emacs-todoist-org-capture-template-key))

(provide 'emacs-todoist-org-capture)
;;; emacs-todoist-org-capture.el ends here
