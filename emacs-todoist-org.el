;;; emacs-todoist-org.el --- Org-mode operations for emacs-todoist  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Felix Mühlenberend

;; Author: Felix Mühlenberend <felix.muehlenberend@mailbox.org>
;; Keywords: outlines, convenience
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

(defun emacs-todoist-org-heading-due-string ()
  "Return the TODOIST_DUE_STRING property at point, or nil.
Whitespace-only values are normalized to nil."
  (when-let* ((value (org-entry-get (point) "TODOIST_DUE_STRING")))
    (let ((trimmed (string-trim value)))
      (unless (string-empty-p trimmed)
        trimmed))))

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

(defun emacs-todoist-set-todo-state (state)
  "Set heading TODO STATE by editing the headline text directly.
Does not call `org-todo' on purpose.  emacs-todoist uses this for
accepted remote state so Org's TODO transition machinery and
`org-after-todo-state-change-hook' are not invoked.

STATE should be a TODO keyword string like \"TODO\" or \"DONE\".
When STATE is nil, any existing TODO keyword is removed."
  (org-back-to-heading t)
  (let ((current-state (org-get-todo-state))
        (line-end (line-end-position)))
    (save-excursion
      (beginning-of-line)
      (re-search-forward "^\\*+\\s-*" line-end t)
      (cond
       (current-state
        (when (re-search-forward
               (concat "\\_<" (regexp-quote current-state) "\\_>\\s-*")
               line-end t)
          (replace-match (if state (concat state " ") "") t t)))
       (state
        (insert state " "))))))

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

;; This normalization is intentionally separate from
;; `emacs-todoist-api--normalize-hash-string': local-hash computation
;; operates on org heading fields, not on Todoist API payloads.
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
The hash covers title, deadline, due string, description, and TODO
state so we can detect local edits that need to be pushed to Todoist."
  (let ((title    (emacs-todoist-org--normalize-hash-string
                   (emacs-todoist-org-heading-title)))
        (deadline (emacs-todoist-org--normalize-hash-string
                   (emacs-todoist-org-heading-deadline)))
        (due-string (emacs-todoist-org--normalize-hash-string
                     (emacs-todoist-org-heading-due-string)))
        (desc     (emacs-todoist-org--normalize-hash-string
                   (emacs-todoist-org-heading-description)))
        (state    (emacs-todoist-org--normalize-hash-string
                   (emacs-todoist-org-heading-todo-state))))
    (sha1 (format "%S" (list title deadline due-string desc state)))))

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
  `due'         — alist with `date'/`string'/`is_recurring' keys or nil
  `checked'     — 0 (open) or 1 (completed)"
  (save-excursion
    (org-back-to-heading t)
    ;; -- Update title --
    (let ((new-title (alist-get 'content data)))
      (when new-title
        (org-edit-headline new-title)))
    ;; -- Update TODO state --
    ;; `checked' = 1 means the task is done in Todoist.  Apply accepted
    ;; remote state textually so Org TODO blockers/hooks do not veto or
    ;; retrigger sync.
    (let* ((checked (alist-get 'checked data))
           (target-state (if (and checked
                                  (not (eq checked :json-false))
                                  (not (equal checked 0)))
                             "DONE" "TODO")))
      (emacs-todoist-set-todo-state target-state))
    ;; -- Update deadline --
    (let* ((due (alist-get 'due data))
           (date-str (and due (alist-get 'date due))))
      (if date-str
          (org-deadline nil date-str)
        ;; Remove deadline when remote has none.
        (org-deadline '(4))))
    ;; -- Update recurrence property --
    (let* ((due (alist-get 'due data))
           (raw-recurring (and due (alist-get 'is_recurring due)))
           (is-recurring (and raw-recurring
                              (not (eq raw-recurring :json-false))
                              (not (equal raw-recurring 0))))
           (due-string (and due (alist-get 'string due))))
      (if (and is-recurring due-string)
          (org-entry-put (point) "TODOIST_DUE_STRING" (format "%s" due-string))
        (org-entry-delete (point) "TODOIST_DUE_STRING")))
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
Checks four sources in order, returning the first non-nil value:
  1. The heading's TODOIST_PROJECT property
  2. The nearest ancestor heading's TODOIST_PROJECT property
  3. The file-level #+TODOIST_PROJECT: keyword
  4. The `emacs-todoist-default-project' variable"
  (or
   ;; 1. Heading property
   (org-entry-get (point) "TODOIST_PROJECT")
   ;; 2. Nearest ancestor heading property.
   (save-excursion
     (let (project)
       (while (and (not project) (org-up-heading-safe))
         (setq project (org-entry-get (point) "TODOIST_PROJECT")))
       project))
   ;; 3. File-level keyword (#+TODOIST_PROJECT: value)
   (save-excursion
     (goto-char (point-min))
     (when (re-search-forward
            "^#\\+TODOIST_PROJECT:[ \t]+\\(.+\\)" nil t)
       (string-trim (match-string-no-properties 1))))
   ;; 4. Global default
   emacs-todoist-default-project))

;; ==============================================================================
;; Aggregate heading data
;; ==============================================================================

(defun emacs-todoist-org-heading-to-alist ()
  "Bundle the heading at point into an alist with all sync-relevant fields.
Returns an alist with keys: `title', `description', `deadline',
`due-string', `todo-state', `children', and `project'."
  (list (cons 'title       (emacs-todoist-org-heading-title))
        (cons 'description (emacs-todoist-org-heading-description))
        (cons 'deadline    (emacs-todoist-org-heading-deadline))
        (cons 'due-string  (emacs-todoist-org-heading-due-string))
        (cons 'todo-state  (emacs-todoist-org-heading-todo-state))
        (cons 'children    (emacs-todoist-org-heading-children))
        (cons 'project     (emacs-todoist-org-resolve-project))))

(provide 'emacs-todoist-org)
;;; emacs-todoist-org.el ends here
