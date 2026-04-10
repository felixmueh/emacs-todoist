;;; sample_doom_config.el --- Example Doom Emacs config for emacs-todoist -*- lexical-binding: t; -*-
;;; Commentary:
;;
;; Drop this into ~/.doom.d/config.el (or load it from there) and adapt paths.
;;
;; Add package declaration in ~/.doom.d/packages.el:
;;   (package! emacs-todoist
;;     :recipe (:host github :repo "felix/emacs-todoist"))
;;
;; For local development instead:
;;   (package! emacs-todoist
;;     :recipe (:local-repo "/path/to/emacs-todoist"))
;;
;;; Code:

;; -----------------------------------------------------------------------------
;; Core Org defaults
;; -----------------------------------------------------------------------------

(after! org
  (setq org-directory (expand-file-name "~/org")
        org-default-notes-file (expand-file-name "inbox.org" org-directory)
        org-agenda-files (list org-directory)
        org-log-done 'time
        org-startup-indented t
        org-hide-emphasis-markers t
        org-ellipsis " ▼ "))

;; -----------------------------------------------------------------------------
;; Todoist token loading
;; -----------------------------------------------------------------------------

(defvar +todoist-api-token-file
  (or (getenv "TODOIST_API_TOKEN_FILE")
      (expand-file-name ".todoist_api_token" doom-user-dir))
  "Path to the file containing the Todoist API token.")

(defun +todoist-api-token-from-file ()
  "Read and return Todoist API token from `+todoist-api-token-file'."
  (unless (file-readable-p +todoist-api-token-file)
    (user-error "Todoist token file not readable: %s" +todoist-api-token-file))
  (let ((token (string-trim
                (with-temp-buffer
                  (insert-file-contents +todoist-api-token-file)
                  (buffer-string)))))
    (when (string-empty-p token)
      (user-error "Todoist token file is empty: %s" +todoist-api-token-file))
    token))

;; -----------------------------------------------------------------------------
;; emacs-todoist setup
;; -----------------------------------------------------------------------------

(use-package! emacs-todoist
  :after org
  :commands (emacs-todoist-open
             emacs-todoist-frontend-sync
             emacs-todoist-sync-single-heading
             emacs-todoist-sync-buffer
             emacs-todoist-sync-subtree
             emacs-todoist-sync-region)
  :init
  (setq emacs-todoist-api-token #'+todoist-api-token-from-file
        ;; Can be a name (resolved via API) or numeric project ID string.
        emacs-todoist-default-project "Inbox"
        ;; Helpful defaults for day-to-day usage.
        emacs-todoist-auto-sync-on-todo-change t
        emacs-todoist-on-done-action nil
        ;; In frontend buffers, remove completed headings immediately.
        emacs-todoist-frontend-on-done-action 'delete-heading
        emacs-todoist-log-level 'info)
  :config
  ;; Enable auto-sync behavior in all org buffers.
  (add-hook 'org-mode-hook #'emacs-todoist-mode)

  ;; Handy leader-key bindings.
  (map! :leader
        (:prefix ("n t" . "todoist")
         :desc "Open Todoist frontend" "o" #'emacs-todoist-open
         :desc "Refresh Todoist frontend" "g" #'emacs-todoist-frontend-sync
         :desc "Sync subtree" "s" #'emacs-todoist-sync-subtree
         :desc "Sync heading only" "h" #'emacs-todoist-sync-single-heading
         :desc "Sync buffer" "b" #'emacs-todoist-sync-buffer
         :desc "Sync region" "r" #'emacs-todoist-sync-region)))

(use-package! emacs-todoist-org-capture
  :after (org-capture emacs-todoist)
  :commands (emacs-todoist-org-capture
             emacs-todoist-org-capture-install-template)
  :init
  (setq emacs-todoist-org-capture-project "Inbox")
  :config
  (emacs-todoist-org-capture-install-template t)
  (map! :leader
        (:prefix ("n t" . "todoist")
         :desc "Todoist capture" "c" #'emacs-todoist-org-capture)))

;; -----------------------------------------------------------------------------
;; Frontend buffer quality-of-life
;; -----------------------------------------------------------------------------

(with-eval-after-load 'emacs-todoist-frontend
  ;; Example: on initial frontend creation, collapse all projects and
  ;; expand only the first child level under Inbox.
  (defun +todoist-frontend-focus-inbox ()
    "Fold all projects and show only Inbox first-level tasks."
    (when (derived-mode-p 'org-mode)
      (save-excursion
        (org-overview)
        (goto-char (point-min))
        (when (re-search-forward "^\\* Inbox\\(?:[[:space:]:].*\\)?$" nil t)
          (beginning-of-line)
          (org-show-children 1)))))
  (add-hook 'emacs-todoist-frontend-after-creation-hook
            #'+todoist-frontend-focus-inbox)

  (add-hook 'emacs-todoist-frontend-mode-hook
            (lambda ()
              (visual-line-mode 1)
              (setq-local line-spacing 0.1)
              (display-line-numbers-mode -1))))

(defun +todoist-agenda-save-frontend-file ()
  "Save the Todoist frontend file that backs the current agenda and reload it."
  (interactive)
  (let ((todoist-file (emacs-todoist-frontend-file-path)))
    (with-current-buffer (find-file-noselect todoist-file)
      (save-buffer))
    (org-agenda-redo)
    ;; `org-agenda-redo' rebuilds the agenda keymap, so reapply this
    ;; one-off binding here. If this grows, use a dedicated minor mode.
    (let ((map (copy-keymap (current-local-map))))
      (define-key map (kbd "C-c C-c")
                  #'+todoist-agenda-save-frontend-file)
      (use-local-map map))
    (message "Saved and reloaded Todoist agenda: %s" todoist-file)))

;; Runs in agenda buffers opened by `emacs-todoist-frontend-agenda'.
(add-hook 'emacs-todoist-frontend-agenda-hook
          (lambda ()
            (let ((map (copy-keymap (current-local-map))))
              (define-key map (kbd "C-c C-c")
                          #'+todoist-agenda-save-frontend-file)
              (use-local-map map))))

(provide 'sample_doom_config)
;;; sample_doom_config.el ends here
