;;; examples.el --- Example configurations for emacs-todoist  -*- lexical-binding: t; -*-

;;; Commentary:

;; Ready-to-use configuration snippets for emacs-todoist.  Copy the
;; relevant sections into your Emacs config, adjusting file paths and
;; project names to suit your setup.
;;
;; Sections:
;;   1. Capture template: personal todo → pushed immediately to Todoist

;;; Code:

(require 'emacs-todoist)
(require 'org-capture)

;; ==============================================================================
;; Capture template: personal todo → pushed immediately to Todoist
;; ==============================================================================

;; This adds a "Todoist todo" capture template (key "T") that works exactly
;; like the standard "Personal todo" template but also pushes the new heading
;; to Todoist as soon as you finalize the capture (C-c C-c).
;;
;; Usage:
;;   M-x org-capture  (or SPC X in Doom)
;;   Press T, type your task, press C-c C-c
;;   → Heading is written to your todo file AND pushed to Todoist
;;
;; The push is skipped when you abort with C-c C-k.

;; Temporary storage for the marker of the heading being captured.
;; A global variable is safe here because org-capture is sequential —
;; only one capture session can be in progress at a time.
(defvar emacs-todoist--capture-marker nil
  "Position of the heading currently being finalized for Todoist push.
Set by `emacs-todoist-capture-save-marker', consumed by
`emacs-todoist-capture-push'.")

(defun emacs-todoist-capture-save-marker ()
  "Record a marker to the heading that is about to be stored.
Intended for use as an org-capture `:before-finalize' hook.  The
captured position is consumed by `emacs-todoist-capture-push'.

Technical note: org-capture uses an indirect buffer over the target
file.  `point-marker' in an indirect buffer creates a marker owned by
the indirect buffer object — which becomes invalid when that buffer is
killed.  We therefore resolve the base buffer with `buffer-base-buffer'
and create the marker there.  Indirect and base buffers share the same
character positions, so the number transfers directly."
  (save-excursion
    (org-back-to-heading t)
    (let* ((pos (point))
           ;; The capture buffer may be an indirect buffer.  Markers in
           ;; indirect buffers become invalid when they are killed, so we
           ;; must anchor the marker in the base buffer (the actual org
           ;; file), which remains open after capture finishes.
           (base-buf (or (buffer-base-buffer) (current-buffer))))
      (setq emacs-todoist--capture-marker
            (with-current-buffer base-buf
              (copy-marker pos))))))

(defun emacs-todoist-capture-push ()
  "Push the heading saved by `emacs-todoist-capture-save-marker' to Todoist.
Intended for use as an org-capture `:after-finalize' hook.  Does
nothing when capture was aborted (C-c C-k), because `org-note-abort'
is bound to t by `org-capture-kill' for the duration of finalization."
  (let ((marker emacs-todoist--capture-marker))
    ;; Always clear the marker, whether we push or not, to avoid stale
    ;; state if the next capture does not use this hook.
    (setq emacs-todoist--capture-marker nil)
    (when (and marker
               (not org-note-abort)
               (marker-buffer marker))
      (with-current-buffer (marker-buffer marker)
        (save-excursion
          (goto-char marker)
          ;; `emacs-todoist-push-heading' calls `org-back-to-heading'
          ;; internally, so we just need point somewhere in the entry.
          (emacs-todoist-push-heading))))))

;; Register the capture template.  `add-to-list' with APPEND=t puts it
;; last, so existing templates defined elsewhere (e.g. Doom defaults) are
;; not disturbed.
;;
;; Doom Emacs variant — uses the +org-capture-todo-file variable:
(add-to-list 'org-capture-templates
             '("T" "Todoist todo" entry
               (file+headline +org-capture-todo-file "Inbox")
               "* TODO %?\n%i\n%a"
               :prepend t
               :before-finalize emacs-todoist-capture-save-marker
               :after-finalize  emacs-todoist-capture-push)
             t)

;; Standard Emacs variant — replace the file path with your own:
;;
;; (add-to-list 'org-capture-templates
;;              '("T" "Todoist todo" entry
;;                (file+headline "~/org/todo.org" "Inbox")
;;                "* TODO %?\n%i\n%a"
;;                :prepend t
;;                :before-finalize emacs-todoist-capture-save-marker
;;                :after-finalize  emacs-todoist-capture-push)
;;              t)

(provide 'examples)
;;; examples.el ends here
