;;; emacs-todoist-org-capture.el --- Org capture templates for emacs-todoist -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Felix

;; Author: Felix
;; Keywords: outlines, convenience, comm

;;; Commentary:

;; Provides a dedicated Org capture template for Todoist workflows.
;;
;; Only captures using this template trigger automatic push/relocation to
;; Todoist.  Generic captures remain untouched.

;;; Code:

(require 'cl-lib)
(require 'org-capture)
(require 'emacs-todoist)

(declare-function emacs-todoist--frontend-file-path "emacs-todoist-frontend")
(declare-function emacs-todoist-frontend-insert-captured-subtree
                  "emacs-todoist-frontend"
                  (subtree-text project-id &optional project-name))

(defvar +org-capture-todo-file nil
  "Doom variable for default TODO capture file.")

(defvar org-note-abort nil
  "Non-nil when the current Org capture session is aborted.")

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
  "Headline where the Todoist capture template stores entries."
  :type 'string
  :group 'emacs-todoist-org-capture)

(defcustom emacs-todoist-org-capture-project nil
  "Optional project name or numeric ID written as TODOIST_PROJECT.
When nil, project resolution uses normal heading/file/default fallback."
  :type '(choice (const nil) string)
  :group 'emacs-todoist-org-capture)

(defvar emacs-todoist-org-capture--marker nil
  "Marker for the heading currently being finalized by Todoist capture.")

(defvar emacs-todoist-org-capture--relocation-in-progress nil
  "Internal guard to prevent nested capture relocation.")

(defvar emacs-todoist-org-capture--deferred-thunks nil
  "Queue of capture thunks scheduled to run after the current command.")

(defun emacs-todoist-org-capture--target-file ()
  "Return the target file for Todoist capture template."
  (cond
   ((and (boundp '+org-capture-todo-file)
         +org-capture-todo-file)
    +org-capture-todo-file)
   ((and (boundp 'org-default-notes-file)
         org-default-notes-file)
    org-default-notes-file)
   ((and (boundp 'org-directory)
         org-directory)
    (expand-file-name "todo.org" org-directory))
   (t
    (expand-file-name "~/org/todo.org"))))

(defun emacs-todoist-org-capture--template-body ()
  "Return template body string for Todoist captures."
  (if emacs-todoist-org-capture-project
      (format "* TODO %%?\n:PROPERTIES:\n:TODOIST_PROJECT: %s\n:END:\n%%i\n%%a"
              emacs-todoist-org-capture-project)
    "* TODO %?\n%i\n%a"))

(defun emacs-todoist-org-capture-before-finalize ()
  "Capture marker-saving hook for the Todoist capture template.
Stores marker in the base buffer so it survives indirect capture buffers."
  (save-excursion
    (org-back-to-heading t)
    (let* ((pos (point))
           (base-buf (or (buffer-base-buffer) (current-buffer))))
      (setq emacs-todoist-org-capture--marker
            (with-current-buffer base-buf
              (copy-marker pos t))))))

(defun emacs-todoist-org-capture--push-in-place (marker)
  "Push heading at MARKER directly to Todoist."
  (when (and (markerp marker) (marker-buffer marker))
    (with-current-buffer (marker-buffer marker)
      (save-excursion
        (goto-char marker)
        (emacs-todoist-push-heading)))))

(defun emacs-todoist-org-capture--flush-deferred ()
  "Run queued capture thunks and clear the queue."
  (remove-hook 'post-command-hook #'emacs-todoist-org-capture--flush-deferred)
  (let ((thunks (nreverse emacs-todoist-org-capture--deferred-thunks)))
    (setq emacs-todoist-org-capture--deferred-thunks nil)
    (dolist (thunk thunks)
      (condition-case err
          (funcall thunk)
        (error
         (emacs-todoist-log 'error "Deferred capture action failed: %S" err))))))

(defun emacs-todoist-org-capture--defer (thunk)
  "Run THUNK after the current command in interactive sessions."
  (if noninteractive
      (funcall thunk)
    (push thunk emacs-todoist-org-capture--deferred-thunks)
    (add-hook 'post-command-hook #'emacs-todoist-org-capture--flush-deferred)))

(defun emacs-todoist-org-capture--frontend-open-p ()
  "Return non-nil when the file-backed frontend buffer is open."
  (and (require 'emacs-todoist-frontend nil t)
       (get-file-buffer (emacs-todoist--frontend-file-path))))

(defun emacs-todoist-org-capture--process-marker (marker)
  "Move capture entry at MARKER into the frontend and sync it.
Returns non-nil when relocation+sync was performed."
  (when (and (markerp marker)
             (marker-buffer marker)
             (emacs-todoist-org-capture--frontend-open-p)
             (not emacs-todoist-org-capture--relocation-in-progress))
    (with-current-buffer (marker-buffer marker)
      (save-excursion
        (goto-char marker)
        (when (and (org-at-heading-p)
                   (org-get-todo-state)
                   (not (bound-and-true-p emacs-todoist-frontend-mode)))
          (when-let* ((project (emacs-todoist-org-resolve-project)))
            (let* ((beg (point))
                   (end (save-excursion (org-end-of-subtree t t) (point)))
                   (subtree (buffer-substring-no-properties beg end))
                   (project-id (emacs-todoist--resolve-project-id project))
                   (emacs-todoist-org-capture--relocation-in-progress t)
                   (frontend-marker
                    (emacs-todoist-frontend-insert-captured-subtree
                     subtree project-id project)))
              (when frontend-marker
                ;; Delete local only after frontend insert succeeded to avoid
                ;; dropping captured tasks on insertion failures.
                (delete-region beg end)
                (with-current-buffer (marker-buffer frontend-marker)
                  (save-excursion
                    (goto-char frontend-marker)
                    (emacs-todoist-sync-heading)))
                t))))))))

(defun emacs-todoist-org-capture--process-or-push (marker)
  "Route capture at MARKER to the frontend, or push it in place."
  (when (and (markerp marker) (marker-buffer marker))
    (unless (emacs-todoist-org-capture--process-marker marker)
      (emacs-todoist-org-capture--push-in-place marker))))

(defun emacs-todoist-org-capture--dispatch-finalize (marker)
  "Dispatch finalize work for MARKER.
In interactive sessions this is deferred to the next command loop to avoid
mutating Org buffers while `org-capture-finalize' is still running."
  (when (and (markerp marker) (marker-buffer marker))
    (let ((marker-copy (copy-marker marker t)))
      (emacs-todoist-org-capture--defer
       (lambda ()
         (when (and (markerp marker-copy) (marker-buffer marker-copy))
           (emacs-todoist-org-capture--process-or-push marker-copy)))))))

(defun emacs-todoist-org-capture-after-finalize ()
  "Finalize hook for Todoist capture template.
Only entries captured with this template trigger this hook behavior."
  (let ((marker emacs-todoist-org-capture--marker))
    (setq emacs-todoist-org-capture--marker nil)
    (when (and marker (not org-note-abort) (marker-buffer marker))
      (emacs-todoist-org-capture--dispatch-finalize marker))))

(defun emacs-todoist-org-capture-template ()
  "Return the capture template definition for Todoist captures."
  (list emacs-todoist-org-capture-template-key
        emacs-todoist-org-capture-template-name
        'entry
        (list 'file+headline
              (emacs-todoist-org-capture--target-file)
              emacs-todoist-org-capture-target-headline)
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
  (org-capture nil emacs-todoist-org-capture-template-key))

(provide 'emacs-todoist-org-capture)
;;; emacs-todoist-org-capture.el ends here
