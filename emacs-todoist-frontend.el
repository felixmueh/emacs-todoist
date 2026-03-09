;;; emacs-todoist-frontend.el --- Frontend buffer for emacs-todoist  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Felix

;; Author: Felix
;; Keywords: outlines, convenience, comm

;;; Commentary:

;; Frontend rendering layer for emacs-todoist.
;;
;; Provides `emacs-todoist-open' to render Todoist tasks into an
;; file-backed org-mode buffer grouped by project, plus
;; `emacs-todoist-frontend-sync' for incremental refresh.  A frontend file
;; seeded by direct capture always performs one full bootstrap sync before
;; switching to incremental tokens so older remote tasks are not missed.

;;; Code:

(require 'org)
(require 'org-agenda)
(require 'cl-lib)
(require 'emacs-todoist)

(defcustom emacs-todoist-frontend-file-name "todoist.org"
  "File name for the file-backed Todoist frontend Org buffer."
  :type 'string
  :group 'emacs-todoist)

(defvar-local emacs-todoist--frontend-project-map nil
  "Hash table: project-id string to project heading marker in frontend buffer.")

(defvar-local emacs-todoist--frontend-id-to-name nil
  "Hash table: project-id string to display name in frontend buffer.")

(defvar-local emacs-todoist--frontend-sync-after-save-running nil
  "Internal recursion guard for frontend sync-on-save.")

(defvar-local emacs-todoist--frontend-suppress-sync-after-save nil
  "Internal guard to suppress sync-on-save for programmatic saves.")

(defvar-local emacs-todoist--frontend-bootstrap-complete nil
  "Non-nil after this frontend buffer has completed its initial full sync.")

(defun emacs-todoist--frontend-file-path ()
  "Return the absolute path for the frontend file-backed Org buffer."
  (let ((dir (if (and (stringp org-directory)
                      (> (length org-directory) 0))
                 org-directory
               (expand-file-name "~/org"))))
    (expand-file-name emacs-todoist-frontend-file-name dir)))

(defun emacs-todoist--frontend-clear-transient-overlays ()
  "Remove transient snippet overlays that can leak into frontend rendering."
  (when (fboundp 'yas-exit-all-snippets)
    (ignore-errors (yas-exit-all-snippets)))
  (dolist (ov (overlays-in (point-min) (point-max)))
    (let ((face (overlay-get ov 'face)))
      (when (or (eq face 'yas-field-highlight-face)
                (and (listp face) (memq 'yas-field-highlight-face face))
                (overlay-get ov 'yas--field-overlay)
                (overlay-get ov 'yas--snippet))
        (delete-overlay ov)))))

(defun emacs-todoist--frontend-save-buffer ()
  "Save current frontend buffer without triggering sync-on-save recursion."
  (when buffer-file-name
    (let ((emacs-todoist--frontend-suppress-sync-after-save t))
      (save-buffer))))

(defun emacs-todoist--frontend-maybe-sync-after-save ()
  "Trigger frontend sync when save-based syncing is enabled."
  (when (and emacs-todoist-frontend-mode
             emacs-todoist-frontend-sync-on-save
             (not emacs-todoist--frontend-suppress-sync-after-save)
             (not emacs-todoist--frontend-sync-after-save-running))
    (let ((emacs-todoist--frontend-sync-after-save-running t))
      (emacs-todoist-frontend-sync))))

(defun emacs-todoist--frontend-setup-buffer (&optional preserve-maps)
  "Initialize current buffer as a Todoist frontend buffer.
When PRESERVE-MAPS is non-nil, keep existing project/id maps."
  (org-mode)
  (emacs-todoist--frontend-clear-transient-overlays)
  (emacs-todoist-frontend-mode 1)
  (emacs-todoist-mode 1)
  ;; Create a real buffer-local override from the customizable default.
  (setq-local emacs-todoist-frontend-on-done-action
              emacs-todoist-frontend-on-done-action)
  (unless preserve-maps
    (setq-local emacs-todoist--frontend-project-map
                (make-hash-table :test #'equal))
    (setq-local emacs-todoist--frontend-id-to-name
                (make-hash-table :test #'equal))))

(defun emacs-todoist-frontend-ensure-buffer ()
  "Return the Todoist frontend buffer, creating and initializing it."
  (let* ((frontend-file (emacs-todoist--frontend-file-path))
         (frontend-dir (file-name-directory frontend-file)))
    (when (and frontend-dir (not (file-directory-p frontend-dir)))
      (make-directory frontend-dir t))
    (let ((buf (find-file-noselect frontend-file)))
      (with-current-buffer buf
        (emacs-todoist--frontend-setup-buffer t)
        (unless (hash-table-p emacs-todoist--frontend-project-map)
          (setq-local emacs-todoist--frontend-project-map
                      (emacs-todoist--frontend-build-project-map)))
        (unless (hash-table-p emacs-todoist--frontend-id-to-name)
          (setq-local emacs-todoist--frontend-id-to-name
                      (emacs-todoist--frontend-seed-id-to-name-from-cache))))
      buf)))

(defun emacs-todoist-frontend-insert-captured-subtree (subtree-text project-id
                                                                     &optional project-name)
  "Insert captured SUBTREE-TEXT into frontend buffer under PROJECT-ID.
PROJECT-NAME is used as a display-name fallback when project metadata
is not in cache.  Returns a marker for the inserted heading."
  (let* ((frontend-buf (emacs-todoist-frontend-ensure-buffer))
         new-marker)
    (with-current-buffer frontend-buf
      (when (and project-id project-name
                 (hash-table-p emacs-todoist--frontend-id-to-name)
                 (not (gethash project-id emacs-todoist--frontend-id-to-name)))
        (puthash project-id project-name emacs-todoist--frontend-id-to-name))
      (let* ((anchor (emacs-todoist--frontend-project-fn
                      `((project_id . ,project-id))))
             (project-marker
              (cond
               ((and (markerp anchor) (marker-buffer anchor)) anchor)
               ((integerp anchor)
                (save-excursion
                  (goto-char anchor)
                  (org-back-to-heading t)
                  (copy-marker (point) t)))
               (t nil))))
        (when (and project-marker (marker-buffer project-marker))
          (goto-char project-marker)
          (org-back-to-heading t)
          (let ((target-level (1+ (org-current-level))))
            (org-end-of-subtree t t)
            (unless (bolp)
              (insert "\n"))
            (let ((insert-pos (point)))
              (org-paste-subtree target-level subtree-text)
              (goto-char insert-pos)
              (when (re-search-forward org-heading-regexp nil t)
                (beginning-of-line)
                (setq new-marker (copy-marker (point) t))
                (emacs-todoist--delete-sync-state-properties)
                (when project-id
                  (emacs-todoist-org-set-props
                   `(("TODOIST_PROJECT" . ,project-id))))))))))
    new-marker))

(defun emacs-todoist--frontend-id-name-map-from-projects (projects)
  "Build project-id to display-name map from PROJECTS response data."
  (let ((table (make-hash-table :test #'equal)))
    (dolist (project projects table)
      (when-let* ((project-id (alist-get 'id project))
                  (name (alist-get 'name project)))
        (puthash (format "%s" project-id) (format "%s" name) table)))))

(defun emacs-todoist--frontend-seed-id-to-name-from-cache ()
  "Build a best-effort id->name map from `emacs-todoist--project-cache'."
  (let ((table (make-hash-table :test #'equal)))
    (when (listp emacs-todoist--project-cache)
      (dolist (entry emacs-todoist--project-cache)
        (let ((name (car entry))
              (project-id (cdr entry)))
          (when (and name project-id)
            (puthash (format "%s" project-id) (format "%s" name) table)))))
    table))

(defun emacs-todoist--frontend-build-project-map ()
  "Scan current buffer and build project-id -> marker map for containers."
  (let ((table (make-hash-table :test #'equal)))
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward org-heading-regexp nil t)
        (beginning-of-line)
        (when (= (org-current-level) 1)
          (let ((project-id (org-entry-get (point) "TODOIST_PROJECT"))
                (todoist-id (org-entry-get (point) "TODOIST_ID")))
            ;; Project container headings have project id but no task id.
            (when (and project-id (null todoist-id))
              (puthash (format "%s" project-id)
                       (copy-marker (point) t)
                       table))))
        (end-of-line)))
    table))

(defun emacs-todoist--frontend-partition-items (items)
  "Partition ITEMS into (TOP-LEVEL . NESTED).
TOP-LEVEL includes items with no parent_id or a parent_id outside ITEMS."
  (let ((id-set (make-hash-table :test #'equal))
        (top-level '())
        (nested '()))
    (dolist (item items)
      (when-let* ((item-id (emacs-todoist--item-id item)))
        (puthash item-id t id-set)))
    (dolist (item items)
      (let ((parent-id (emacs-todoist--item-parent-id item)))
        (if (or (null parent-id) (not (gethash parent-id id-set)))
            (push item top-level)
          (push item nested))))
    (cons (nreverse top-level) (nreverse nested))))

(defun emacs-todoist--frontend-project-fn (item)
  "Return project container marker for ITEM, creating it if missing."
  (unless (hash-table-p emacs-todoist--frontend-project-map)
    (setq-local emacs-todoist--frontend-project-map
                (make-hash-table :test #'equal)))
  (let* ((project-id (emacs-todoist--item-project-id item))
         (project-key (or project-id "unknown"))
         (existing (gethash project-key emacs-todoist--frontend-project-map)))
    (if (and (markerp existing) (marker-buffer existing))
        existing
      (let* ((name (or (and project-id
                            (hash-table-p emacs-todoist--frontend-id-to-name)
                            (gethash project-id emacs-todoist--frontend-id-to-name))
                       "Unknown Project"))
             marker)
        (goto-char (point-max))
        (unless (bolp)
          (insert "\n"))
        (let ((start (point)))
          (insert "* " name "\n")
          (goto-char start)
          (org-back-to-heading t)
          (when project-id
            (emacs-todoist-org-set-props
             `(("TODOIST_PROJECT" . ,project-id))))
          (setq marker (copy-marker (point) t)))
        (puthash project-key marker emacs-todoist--frontend-project-map)
        marker))))

(defun emacs-todoist--frontend-sync-post-classify (ctx)
  "Frontend post-classify callback for shared bulk sync pipeline.
CTX is a plist containing :new-remote-items, :new-sync-token, and :id-map."
  (let* ((new-remote-items (or (plist-get ctx :new-remote-items) '()))
         (new-sync-token (plist-get ctx :new-sync-token))
         (id-map (plist-get ctx :id-map))
         (sorted-items (emacs-todoist--topological-sort-items new-remote-items))
         (inserted-top-level
          (emacs-todoist--apply-top-level-items
           sorted-items new-sync-token id-map
           #'emacs-todoist--frontend-project-fn))
         ;; Re-run generic child insertion so descendants of newly-created
         ;; top-level tasks are attached in the same sync pass.
         (inserted-nested
          (emacs-todoist--apply-items sorted-items new-sync-token id-map)))
    (+ inserted-top-level inserted-nested)))

(defvar emacs-todoist-frontend-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "g") #'emacs-todoist-frontend-sync)
    (define-key map (kbd "A") #'emacs-todoist-frontend-agenda)
    map)
  "Keymap for `emacs-todoist-frontend-mode'.")

(define-minor-mode emacs-todoist-frontend-mode
  "Minor mode for the file-backed frontend Todoist buffer."
  :lighter " Todoist"
  :keymap emacs-todoist-frontend-mode-map
  (if emacs-todoist-frontend-mode
      (add-hook 'after-save-hook #'emacs-todoist--frontend-maybe-sync-after-save
                nil t)
    (remove-hook 'after-save-hook #'emacs-todoist--frontend-maybe-sync-after-save
                 t)))

;;;###autoload
(defun emacs-todoist-open ()
  "Open and render Todoist tasks in the frontend Org buffer."
  (interactive)
  (let* ((frontend-file (emacs-todoist--frontend-file-path))
         (already-open (get-file-buffer frontend-file)))
    (if-let* ((todoist-buf (and already-open
                                (emacs-todoist-frontend-ensure-buffer))))
      (progn
        (switch-to-buffer todoist-buf)
        (with-current-buffer todoist-buf
          (emacs-todoist--frontend-setup-buffer t))
        (emacs-todoist-frontend-sync))
      (let ((todoist-buf (emacs-todoist-frontend-ensure-buffer)))
        (switch-to-buffer todoist-buf)
        (with-current-buffer todoist-buf
          (emacs-todoist--frontend-setup-buffer))
        (emacs-todoist-api-sync
         "*" '("items" "projects") nil
         (lambda (response)
           (if (alist-get 'error response)
               (progn
                 (emacs-todoist-log 'error "Frontend open failed: %s"
                                    (alist-get 'error response))
                 (message "emacs-todoist: frontend open failed"))
             (when (buffer-live-p todoist-buf)
               (with-current-buffer todoist-buf
                 (let* ((items (or (alist-get 'items response) '()))
                        (projects (or (alist-get 'projects response) '()))
                        (sync-token (alist-get 'sync_token response))
                        (sorted-items (emacs-todoist--topological-sort-items items))
                        (partitioned (emacs-todoist--frontend-partition-items sorted-items))
                        (top-level-items (car partitioned))
                        (nested-items (cdr partitioned))
                        (id-map (make-hash-table :test #'equal)))
                   (erase-buffer)
                   (emacs-todoist--frontend-setup-buffer)
                   (emacs-todoist--project-cache-populate projects)
                   (setq-local emacs-todoist--frontend-id-to-name
                               (emacs-todoist--frontend-id-name-map-from-projects projects))
                   (setq-local emacs-todoist--frontend-project-map
                               (make-hash-table :test #'equal))
                   (emacs-todoist--apply-top-level-items
                    top-level-items sync-token id-map
                    #'emacs-todoist--frontend-project-fn)
                   (emacs-todoist--apply-items nested-items sync-token id-map)
                   (goto-char (point-min))
                   (setq-local emacs-todoist--frontend-bootstrap-complete t)
                   (emacs-todoist--frontend-save-buffer)
                   (message "emacs-todoist: rendered %d tasks" (length items))))))))))))

;;;###autoload
(defun emacs-todoist-frontend-sync (&optional done-fn)
  "Incrementally sync the current frontend buffer from Todoist.
When DONE-FN is non-nil, call it with a sync summary plist after
successful sync completion.

The first sync in a frontend buffer always uses a full `*' fetch so a
capture-seeded file cannot get stuck with only the most recently synced
heading visible."
  (interactive)
  (unless emacs-todoist-frontend-mode
    (user-error "Not in an emacs-todoist frontend buffer"))
  (setq-local emacs-todoist--frontend-project-map
              (emacs-todoist--frontend-build-project-map))
  (unless (hash-table-p emacs-todoist--frontend-id-to-name)
    (setq-local emacs-todoist--frontend-id-to-name
                (emacs-todoist--frontend-seed-id-to-name-from-cache)))
  (let ((linked-markers (emacs-todoist-org-synced-entries))
        ;; A frontend file can be seeded by direct capture, which may leave
        ;; one freshly-synced heading with a recent token but no older remote
        ;; tasks.  Force the first frontend refresh to use "*" so the file is
        ;; bootstrapped from complete remote state before incremental syncs.
        (force-full-fetch (not emacs-todoist--frontend-bootstrap-complete))
        (frontend-buf (current-buffer)))
    (emacs-todoist--sync-entries
     linked-markers nil
     :fetch-token-override (when force-full-fetch "*")
     :post-classify-fn #'emacs-todoist--frontend-sync-post-classify
     :done-fn (lambda (summary)
                (when (buffer-live-p frontend-buf)
                  (with-current-buffer frontend-buf
                    (setq-local emacs-todoist--frontend-bootstrap-complete t)
                    (when buffer-file-name
                      (emacs-todoist--frontend-save-buffer))))
                (when done-fn
                  (funcall done-fn summary))))))

(defun emacs-todoist--frontend-open-agenda-from-buffer ()
  "Open Org date agenda view sourced only from the current frontend file."
  (unless (and (stringp buffer-file-name)
               (file-exists-p buffer-file-name))
    (user-error "Frontend buffer is not visiting a file"))
  (emacs-todoist--frontend-save-buffer)
  (let ((org-agenda-files (list buffer-file-name)))
    (org-agenda-list)))

;;;###autoload
(defun emacs-todoist-frontend-agenda ()
  "Sync the frontend buffer, then open a date agenda for frontend items."
  (interactive)
  (let ((todoist-buf (emacs-todoist-frontend-ensure-buffer)))
    (switch-to-buffer todoist-buf)
    (with-current-buffer todoist-buf
      (emacs-todoist-frontend-sync
       (lambda (_summary)
         (when (buffer-live-p todoist-buf)
           (with-current-buffer todoist-buf
             (emacs-todoist--frontend-open-agenda-from-buffer))))))))

(provide 'emacs-todoist-frontend)
;;; emacs-todoist-frontend.el ends here
