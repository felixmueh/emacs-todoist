;;; emacs-todoist-org.el --- Org-mode operations for emacs-todoist  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Felix

;; Author: Felix
;; Keywords: outlines, convenience

;;; Commentary:

;; Pure org-mode parsing and manipulation functions for syncing with Todoist.
;; No API calls — easily testable in isolation.
;;
;; All functions assume point is on an org heading unless noted otherwise.
;;
;; Public API groups:
;;   Field extraction:  -heading-title, -heading-deadline, -heading-description,
;;                      -heading-todo-state, -heading-to-alist
;;   Property I/O:      -heading-props, -set-props
;;   Change detection:  -heading-local-hash, -heading-local-changed-p
;;   Tree traversal:    -heading-children, -synced-entries, -todo-entries
;;                      (+ -in-region / -in-subtree variants)
;;   Remote application: -apply-remote, --replace-body
;;   Project resolution: -resolve-project (heading prop → file keyword → default)

;;; Code:

(require 'org)
(require 'org-element)
(require 'sha1)
(require 'subr-x)

;; The real `defcustom' lives in emacs-todoist.el; we declare it here so
;; this module can reference it without pulling in the full package and
;; without byte-compiler warnings.
(defvar emacs-todoist-default-project nil
  "Fallback Todoist project name when no heading or file property is set.")

;; ==============================================================================
;; Heading field extraction
;; ==============================================================================

(defun emacs-todoist-org-heading-title ()
  "Return the heading title at point, without TODO keyword, priority, or tags."
  (org-get-heading t t t t))

(defun emacs-todoist-org-heading-deadline ()
  "Return the DEADLINE at point as a \"YYYY-MM-DD\" string, or nil."
  ;; `org-entry-get' with "DEADLINE" returns the full timestamp string
  ;; (e.g. "<2026-01-15 Thu>"), so we extract just the date portion.
  (when-let* ((raw (org-entry-get (point) "DEADLINE")))
    (when (string-match "\\([0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\)" raw)
      (match-string 1 raw))))

(defun emacs-todoist-org-heading-description ()
  "Return body text of the heading at point, excluding property drawers,
planning lines, and sub-headings.  Returns \"\" when there is no body."
  (save-excursion
    (org-back-to-heading t)
    (let* ((level (org-current-level))
           (element (org-element-at-point))
           ;; `contents-begin' is where the heading's body starts (after
           ;; the headline itself).  `contents-end' is where it ends
           ;; (before the next heading at the same or higher level).
           (contents-begin (org-element-property :contents-begin element))
           (contents-end   (org-element-property :contents-end element)))
      (if (or (null contents-begin) (null contents-end))
          ""
        ;; We need to skip past planning lines and property drawers,
        ;; then stop before the first child heading.
        (goto-char contents-begin)
        ;; Skip planning line (DEADLINE, SCHEDULED, CLOSED).
        (when (looking-at org-planning-line-re)
          (forward-line 1))
        ;; Skip property drawer.
        (when (looking-at org-property-drawer-re)
          (goto-char (match-end 0))
          ;; Move past any trailing newline after :END:.
          (when (looking-at "\n")
            (forward-char 1)))
        (let ((body-begin (point))
              ;; Find where the first child heading starts, if any.
              ;; We use the level captured while point was on the heading
              ;; line — after skipping the property drawer, point may have
              ;; landed on a child heading, which would give the wrong level.
              (first-child-pos
               (save-excursion
                 (if (re-search-forward
                      (format "^\\*\\{%d,\\} " (1+ level))
                      contents-end t)
                     (match-beginning 0)
                   nil))))
          (let* ((body-end (or first-child-pos contents-end))
                 (text (string-trim
                        (buffer-substring-no-properties body-begin body-end))))
            text))))))

(defun emacs-todoist-org-heading-todo-state ()
  "Return the TODO state string at point, or nil if none."
  (org-get-todo-state))

;; ==============================================================================
;; Todoist property management
;; ==============================================================================

(defun emacs-todoist-org-heading-props ()
  "Return an alist of all TODOIST_* properties at point."
  (let ((all-props (org-entry-properties (point) 'standard)))
    (seq-filter (lambda (pair)
                  (string-prefix-p "TODOIST_" (car pair)))
                all-props)))

(defun emacs-todoist-org-set-props (alist)
  "Write ALIST of TODOIST_* properties at point.
Each element is (KEY . VALUE) where KEY is like \"TODOIST_ID\"."
  (dolist (pair alist)
    (org-entry-put (point) (car pair) (cdr pair))))

;; ==============================================================================
;; Change detection via hashing
;; ==============================================================================

(defun emacs-todoist-org--normalize-hash-string (value)
  "Return VALUE trimmed for stable hash comparisons."
  (cond
   ((null value) "")
   ((stringp value)
    (string-trim (substring-no-properties value)))
   (t
    (string-trim (format "%s" value)))))

(defun emacs-todoist-org-heading-local-hash ()
  "Compute a SHA-1 hash of the heading's sync-relevant fields.
The hash covers title, deadline, description, and TODO state so we can
detect local edits that need to be pushed to Todoist."
  (let ((title    (emacs-todoist-org--normalize-hash-string
                   (emacs-todoist-org-heading-title)))
        (deadline (emacs-todoist-org--normalize-hash-string
                   (emacs-todoist-org-heading-deadline)))
        (desc     (emacs-todoist-org--normalize-hash-string
                   (emacs-todoist-org-heading-description)))
        (state    (emacs-todoist-org--normalize-hash-string
                   (emacs-todoist-org-heading-todo-state))))
    (sha1 (format "%S" (list title deadline desc state)))))

(defun emacs-todoist-org-heading-local-changed-p ()
  "Return t if the heading at point has changed since last sync.
Compares the current local hash against the stored TODOIST_LOCAL_HASH
property.  Returns t when no stored hash exists (new/unsynced heading)."
  (let ((stored  (org-entry-get (point) "TODOIST_LOCAL_HASH"))
        (current (emacs-todoist-org-heading-local-hash)))
    (or (null stored)
        (not (string= stored current)))))

;; ==============================================================================
;; Tree traversal
;; ==============================================================================

(defun emacs-todoist-org-heading-children ()
  "Return a list of markers for direct child headings at point.
Does not include grandchildren or deeper descendants."
  (save-excursion
    (org-back-to-heading t)
    (let (children)
      (when (org-goto-first-child)
        (push (point-marker) children)
        (while (org-get-next-sibling)
          (push (point-marker) children)))
      (nreverse children))))

(defun emacs-todoist-org-synced-entries ()
  "Return a list of markers for all headings in the buffer with a TODOIST_ID.
Searches the entire current buffer."
  (let (markers)
    (org-with-wide-buffer
     (goto-char (point-min))
     (while (re-search-forward "^[ \t]*:TODOIST_ID:" nil t)
       (save-excursion
         (org-back-to-heading t)
         (push (point-marker) markers))))
    (nreverse markers)))

(defun emacs-todoist-org-synced-entries-in-region (beg end)
  "Return markers for headings with a TODOIST_ID between BEG and END."
  (let (markers)
    (save-excursion
      (goto-char beg)
      (while (re-search-forward "^[ \t]*:TODOIST_ID:" end t)
        (save-excursion
          (org-back-to-heading t)
          (when (>= (point) beg)
            (push (point-marker) markers)))))
    (nreverse markers)))

(defun emacs-todoist-org-synced-entries-in-subtree ()
  "Return markers for headings with a TODOIST_ID in the subtree at point."
  (save-excursion
    (org-back-to-heading t)
    (let ((beg (point))
          (end (save-excursion (org-end-of-subtree t) (point))))
      (emacs-todoist-org-synced-entries-in-region beg end))))

(defun emacs-todoist-org-todo-entries ()
  "Return markers for all TODO headings in the buffer (any TODO keyword)."
  (let (markers)
    (org-with-wide-buffer
     (goto-char (point-min))
     (while (re-search-forward org-heading-regexp nil t)
       (beginning-of-line)
       (when (org-get-todo-state)
         (push (point-marker) markers))
       (end-of-line)))
    (nreverse markers)))

(defun emacs-todoist-org-todo-entries-in-region (beg end)
  "Return markers for TODO headings between BEG and END."
  (let (markers)
    (save-excursion
      (goto-char beg)
      (while (re-search-forward org-heading-regexp end t)
        (beginning-of-line)
        (when (and (>= (point) beg) (org-get-todo-state))
          (push (point-marker) markers))
        (end-of-line)))
    (nreverse markers)))

(defun emacs-todoist-org-todo-entries-in-subtree ()
  "Return markers for TODO headings in the subtree at point."
  (save-excursion
    (org-back-to-heading t)
    (let ((beg (point))
          (end (save-excursion (org-end-of-subtree t) (point))))
      (emacs-todoist-org-todo-entries-in-region beg end))))

;; ==============================================================================
;; Remote data application
;; ==============================================================================

(defun emacs-todoist-org-apply-remote (data)
  "Update the heading at point from a Todoist task alist DATA.
DATA keys:
  `content'     — task title string
  `description' — body text string
  `due'         — alist with `date' key (\"YYYY-MM-DD\") or nil
  `checked'     — 0 (open) or 1 (completed)"
  (save-excursion
    (org-back-to-heading t)
    ;; -- Update title --
    (let ((new-title (alist-get 'content data)))
      (when new-title
        (org-edit-headline new-title)))
    ;; -- Update TODO state --
    ;; `checked' = 1 means the task is done in Todoist.  The API may
    ;; return `:json-false' for unchecked tasks instead of 0.
    (let* ((checked (alist-get 'checked data))
           (target-state (if (and checked
                                  (not (eq checked :json-false))
                                  (not (equal checked 0)))
                             "DONE" "TODO")))
      (org-todo target-state))
    ;; -- Update deadline --
    (let* ((due (alist-get 'due data))
           (date-str (and due (alist-get 'date due))))
      (if date-str
          (org-deadline nil date-str)
        ;; Remove deadline when remote has none.
        (org-deadline '(4))))
    ;; -- Update description/body --
    (let ((new-desc (or (alist-get 'description data) "")))
      (emacs-todoist-org--replace-body new-desc))))

(defun emacs-todoist-org--replace-body (new-body)
  "Replace the body text of the heading at point with NEW-BODY.
Preserves the property drawer, planning lines, and child headings."
  (save-excursion
    (org-back-to-heading t)
    (let* ((level (org-current-level))
           (element (org-element-at-point))
           (contents-begin (org-element-property :contents-begin element))
           (contents-end   (org-element-property :contents-end element)))
      (when (and contents-begin contents-end)
        (goto-char contents-begin)
        ;; Skip past planning line.
        (when (looking-at org-planning-line-re)
          (forward-line 1))
        ;; Skip past property drawer.
        (when (looking-at org-property-drawer-re)
          (goto-char (match-end 0))
          (when (looking-at "\n")
            (forward-char 1)))
        (let ((body-begin (point))
              ;; Find where the first child heading starts, if any.
              ;; Level was captured while point was on the heading line;
              ;; after skipping the property drawer, point may sit on a
              ;; child heading which would yield the wrong level.
              (first-child-pos
               (save-excursion
                 (if (re-search-forward
                      (format "^\\*\\{%d,\\} " (1+ level))
                      contents-end t)
                     (match-beginning 0)
                   nil))))
          (let ((body-end (or first-child-pos contents-end)))
            (delete-region body-begin body-end)
            (goto-char body-begin)
            (when (and new-body (not (string-empty-p new-body)))
              (insert new-body "\n"))))))))

;; ==============================================================================
;; Project resolution
;; ==============================================================================

(defun emacs-todoist-org-resolve-project ()
  "Determine the Todoist project for the heading at point.
Checks three sources in order, returning the first non-nil value:
  1. The heading's TODOIST_PROJECT property
  2. The file-level #+TODOIST_PROJECT: keyword
  3. The `emacs-todoist-default-project' variable"
  (or
   ;; 1. Heading property
   (org-entry-get (point) "TODOIST_PROJECT")
   ;; 2. File-level keyword (#+TODOIST_PROJECT: value)
   (save-excursion
     (goto-char (point-min))
     (when (re-search-forward
            "^#\\+TODOIST_PROJECT:[ \t]+\\(.+\\)" nil t)
       (string-trim (match-string-no-properties 1))))
   ;; 3. Global default
   emacs-todoist-default-project))

;; ==============================================================================
;; Aggregate heading data
;; ==============================================================================

(defun emacs-todoist-org-heading-to-alist ()
  "Bundle the heading at point into an alist with all sync-relevant fields.
Returns an alist with keys: `title', `description', `deadline',
`todo-state', `children', and `project'."
  (list (cons 'title       (emacs-todoist-org-heading-title))
        (cons 'description (emacs-todoist-org-heading-description))
        (cons 'deadline    (emacs-todoist-org-heading-deadline))
        (cons 'todo-state  (emacs-todoist-org-heading-todo-state))
        (cons 'children    (emacs-todoist-org-heading-children))
        (cons 'project     (emacs-todoist-org-resolve-project))))

(provide 'emacs-todoist-org)
;;; emacs-todoist-org.el ends here
