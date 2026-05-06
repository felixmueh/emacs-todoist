;;; emacs-todoist-find-heading.el --- Find canonical Todoist Org headings -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Felix

;; Author: Felix
;; Keywords: outlines, convenience

;;; Commentary:

;; Lookup helpers for finding the canonical, non-frontend Org heading for
;; a Todoist task.  TODOIST_ID is the authoritative identity; org-id and
;; file locations are cache hints that must be verified before use.

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'org-id)
(require 'org-refile)
(require 'subr-x)

(defvar emacs-todoist-frontend-file-name "todoist.org"
  "File name for the file-backed Todoist frontend Org buffer.")

(defgroup emacs-todoist-find-heading nil
  "Canonical heading lookup for emacs-todoist."
  :group 'emacs-todoist)

(defcustom emacs-todoist-find-heading-cache-file
  (locate-user-emacs-file "emacs-todoist-find-heading-cache.el")
  "File storing canonical Todoist heading lookup hints.
The cache is an Elisp sexp alist keyed by TODOIST_ID.  Values are
plists with keys such as `:org-id', `:file', `:position', and `:title'."
  :type 'file
  :group 'emacs-todoist-find-heading)

(defun emacs-todoist-find-heading--frontend-file-path ()
  "Return the absolute path of the Todoist frontend file."
  (let ((dir (if (and (boundp 'org-directory)
                      (stringp org-directory)
                      (> (length org-directory) 0))
                 org-directory
               (expand-file-name "~/org"))))
    (expand-file-name emacs-todoist-frontend-file-name dir)))

(defun emacs-todoist-find-heading--normalize-file (file)
  "Return expanded FILE, or nil when FILE is nil."
  (when (and (stringp file) (not (string-empty-p file)))
    (expand-file-name file)))

(defun emacs-todoist-find-heading--same-file-p (a b)
  "Return non-nil when A and B name the same file."
  (let ((a (emacs-todoist-find-heading--normalize-file a))
        (b (emacs-todoist-find-heading--normalize-file b)))
    (and a b (equal a b))))

(defun emacs-todoist-find-heading--frontend-file-p (file)
  "Return non-nil when FILE is the Todoist frontend file."
  (emacs-todoist-find-heading--same-file-p
   file (emacs-todoist-find-heading--frontend-file-path)))

(defun emacs-todoist-find-heading--source-file-p (file)
  "Return non-nil when FILE can be searched as a canonical source file."
  (let ((file (emacs-todoist-find-heading--normalize-file file)))
    (and file
         (not (emacs-todoist-find-heading--frontend-file-p file))
         (file-readable-p file))))

(defun emacs-todoist-find-heading--buffer-source-p (buffer)
  "Return non-nil when BUFFER visits a searchable non-frontend Org file."
  (and (buffer-live-p buffer)
       (with-current-buffer buffer
         (and buffer-file-name
              (derived-mode-p 'org-mode)
              (not (emacs-todoist-find-heading--frontend-file-p
                    buffer-file-name))))))

(defun emacs-todoist-find-heading--load-cache ()
  "Return the heading lookup cache alist."
  (when (file-readable-p emacs-todoist-find-heading-cache-file)
    (with-temp-buffer
      (insert-file-contents emacs-todoist-find-heading-cache-file)
      (goto-char (point-min))
      (condition-case nil
          (let ((data (read (current-buffer))))
            (when (listp data) data))
        (error nil)))))

(defun emacs-todoist-find-heading--save-cache (cache)
  "Write CACHE alist to `emacs-todoist-find-heading-cache-file'."
  (let ((dir (file-name-directory emacs-todoist-find-heading-cache-file)))
    (when dir
      (make-directory dir t)))
  (with-temp-file emacs-todoist-find-heading-cache-file
    (let ((print-length nil)
          (print-level nil))
      (prin1 cache (current-buffer))
      (insert "\n"))))

(defun emacs-todoist-find-heading--cache-get (todoist-id)
  "Return cached plist for TODOIST-ID, or nil."
  (cdr (assoc-string todoist-id
                     (emacs-todoist-find-heading--load-cache)
                     t)))

(defun emacs-todoist-find-heading--cache-put (todoist-id marker)
  "Store lookup hints for TODOIST-ID from MARKER."
  (when (and (markerp marker) (marker-buffer marker))
    (with-current-buffer (marker-buffer marker)
      (save-excursion
        (goto-char marker)
        (org-back-to-heading t)
        (let* ((org-id (org-entry-get (point) "ID"))
               (file (buffer-file-name))
               (title (org-get-heading t t t t))
               (entry (list :org-id org-id
                            :file (and file (expand-file-name file))
                            :position (point)
                            :title title))
               (cache (emacs-todoist-find-heading--load-cache))
               (cell (assoc-string todoist-id cache t)))
          (if cell
              (setcdr cell entry)
            (push (cons todoist-id entry) cache))
          (emacs-todoist-find-heading--save-cache cache))))))

(defun emacs-todoist-find-heading--valid-marker-p (marker todoist-id)
  "Return non-nil when MARKER points to a heading with TODOIST-ID."
  (and (markerp marker)
       (marker-buffer marker)
       (emacs-todoist-find-heading--buffer-source-p (marker-buffer marker))
       (with-current-buffer (marker-buffer marker)
         (save-excursion
           (goto-char marker)
           (ignore-errors
             (org-back-to-heading t)
             (equal todoist-id (org-entry-get (point) "TODOIST_ID")))))))

(defun emacs-todoist-find-heading--find-in-buffer (todoist-id buffer)
  "Return marker for TODOIST-ID in BUFFER, or nil."
  (when (emacs-todoist-find-heading--buffer-source-p buffer)
    (with-current-buffer buffer
      (save-excursion
        (org-with-wide-buffer
         (goto-char (point-min))
         (let ((found nil))
           (while (and (null found)
                       (re-search-forward "^[ \t]*:TODOIST_ID:[ \t]*\\(.+\\)$"
                                          nil t))
             (when (equal todoist-id (string-trim (match-string-no-properties 1)))
               (org-back-to-heading t)
               (setq found (copy-marker (point) t))))
           found))))))

(defun emacs-todoist-find-heading--find-in-file (todoist-id file)
  "Return marker for TODOIST-ID in FILE, or nil."
  (when (emacs-todoist-find-heading--source-file-p file)
    (let ((buffer (find-file-noselect file)))
      (emacs-todoist-find-heading--find-in-buffer todoist-id buffer))))

(defun emacs-todoist-find-heading--find-by-org-id (todoist-id org-id)
  "Return marker for ORG-ID when it verifies against TODOIST-ID."
  (when (and (stringp org-id) (not (string-empty-p org-id)))
    (let ((marker (ignore-errors (org-id-find org-id t))))
      (when (emacs-todoist-find-heading--valid-marker-p marker todoist-id)
        marker))))

(defun emacs-todoist-find-heading--target-files-from-source (source)
  "Return refile target files named by SOURCE."
  (cond
   ((null source)
    (when (and (derived-mode-p 'org-mode) buffer-file-name)
      (list buffer-file-name)))
   ((eq source 'org-agenda-files)
    (org-agenda-files 'unrestricted))
   ((and (symbolp source) (fboundp source))
    (funcall source))
   ((functionp source)
    (funcall source))
   ((and (symbolp source) (boundp source))
    (symbol-value source))
   ((stringp source)
    (list source))
   ((listp source)
    source)))

(defun emacs-todoist-find-heading--org-refile-files ()
  "Return searchable files implied by `org-refile-targets'."
  (let ((files
         (mapcan (lambda (target)
                   (emacs-todoist-find-heading--target-files-from-source
                    (car target)))
                 org-refile-targets)))
    (delete-dups
     (cl-remove-if-not
      #'emacs-todoist-find-heading--source-file-p
      (mapcar #'expand-file-name
              (cl-remove-if-not #'stringp files))))))

(defun emacs-todoist-find-heading--current-buffer (current)
  "Return a buffer from CURRENT, or nil.
CURRENT may be nil, a buffer, or a file name."
  (cond
   ((bufferp current) current)
   ((null current) (current-buffer))
   ((stringp current) (get-file-buffer (expand-file-name current)))))

(defun emacs-todoist-find-heading--current-file (current)
  "Return a file name from CURRENT, or nil.
CURRENT may be nil, a buffer, or a file name."
  (cond
   ((stringp current) (expand-file-name current))
   ((bufferp current)
    (with-current-buffer current
      (when buffer-file-name
        (expand-file-name buffer-file-name))))
   ((and (null current) buffer-file-name)
    (expand-file-name buffer-file-name))))

;;;###autoload
(defun emacs-todoist-find-heading (todoist-id &optional current)
  "Return a marker for the canonical heading with TODOIST-ID, or nil.
CURRENT may be nil, a buffer, or a file name and is used for the first
lookup step.  The Todoist frontend file is excluded from every step."
  (unless (and (stringp todoist-id) (not (string-empty-p todoist-id)))
    (user-error "TODOIST_ID must be a non-empty string"))
  (let* ((current-buffer (emacs-todoist-find-heading--current-buffer current))
         (current-file (emacs-todoist-find-heading--current-file current))
         (cache (emacs-todoist-find-heading--cache-get todoist-id))
         (files (delete-dups
                 (append
                  (when-let* ((cached-file (plist-get cache :file)))
                    (list cached-file))
                  (emacs-todoist-find-heading--org-refile-files))))
         found)
    (setq found
          (or
           (and current-buffer
                (emacs-todoist-find-heading--find-in-buffer
                 todoist-id current-buffer))
           (and (not current-buffer)
                current-file
                (emacs-todoist-find-heading--find-in-file
                 todoist-id current-file))
           (emacs-todoist-find-heading--find-by-org-id
            todoist-id (plist-get cache :org-id))
           (cl-loop for file in files
                    thereis (emacs-todoist-find-heading--find-in-file
                             todoist-id file))))
    (when found
      (emacs-todoist-find-heading--cache-put todoist-id found))
    found))

(provide 'emacs-todoist-find-heading)
;;; emacs-todoist-find-heading.el ends here
