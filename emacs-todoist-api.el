;;; emacs-todoist-api.el --- Todoist Sync API v1 wrapper  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Felix

;; Author: Felix
;; Keywords: comm

;;; Commentary:

;; Stateless Todoist Sync API v1 wrapper.  No org-mode dependency.
;; Sync tokens are passed in by callers and new tokens returned.
;;
;; The module targets the Sync API v1 endpoint at
;; https://api.todoist.com/api/v1/sync (not the older v9).
;;
;; Public API groups:
;;   Token:       -api-token (handles string or function)
;;   UUID:        -api-generate-uuid (RFC 4122 v4)
;;   Commands:    -api-build-command, -api-item-add, -api-item-update,
;;                -api-item-complete, -api-item-uncomplete, -api-item-delete
;;   Parsing:     -api-parse-response (extracts sync_token, items, etc.)
;;   Hashing:     -api-hash-item (SHA-1 of sync-relevant fields)
;;   HTTP:        -api-sync (core async call), -api-fetch-items, -api-fetch-projects
;;
;; All HTTP is async via `url-retrieve'.  Callers pass a CALLBACK that
;; receives the parsed response alist.  The `checked' field from the API
;; can be `t', `:json-false', 0, 1, or nil — see `emacs-todoist-api-hash-item'
;; for the canonical normalization pattern.

;;; Code:

(require 'json)
(require 'url)
(require 'cl-lib)

;; The real `defcustom' lives in emacs-todoist.el; we declare it here so
;; this module compiles without warnings and can be used standalone.
(defvar emacs-todoist-api-token nil
  "Todoist API token.  String or function returning a string.")

;; ==============================================================================
;; Token retrieval
;; ==============================================================================

(defun emacs-todoist-api-token ()
  "Return the Todoist API token string.
If `emacs-todoist-api-token' is a function, call it to obtain the
token; otherwise return its value directly."
  (if (functionp emacs-todoist-api-token)
      (funcall emacs-todoist-api-token)
    emacs-todoist-api-token))

;; ==============================================================================
;; UUID generation
;; ==============================================================================

(defun emacs-todoist-api-generate-uuid ()
  "Generate a UUID v4 string.
Sets the version nibble to 4 and the variant bits to 10xx per RFC 4122."
  (format "%04x%04x-%04x-%04x-%04x-%04x%04x%04x"
          (random 65536)
          (random 65536)
          (random 65536)
          ;; Version 4: high nibble must be 0100 (4).
          (logior #x4000 (logand #x0fff (random 65536)))
          ;; Variant 1: top two bits must be 10.
          (logior #x8000 (logand #x3fff (random 65536)))
          (random 65536)
          (random 65536)
          (random 65536)))

;; ==============================================================================
;; Command building
;; ==============================================================================

(defun emacs-todoist-api-build-command (type args &optional temp-id)
  "Build a Todoist Sync API command alist.
TYPE is the command type string (e.g. \"item_add\").
ARGS is an alist of command arguments.
TEMP-ID, when non-nil, is included as the `temp_id' field."
  (let ((cmd `((type . ,type)
               (uuid . ,(emacs-todoist-api-generate-uuid))
               (args . ,args))))
    (when temp-id
      (push `(temp_id . ,temp-id) cmd))
    cmd))

;; ==============================================================================
;; Item command builders
;; ==============================================================================

;; Each builder constructs command alists suitable for inclusion in the
;; `commands' array of a Sync API request.  They do not make network
;; calls themselves — the caller collects commands and passes them to
;; `emacs-todoist-api-sync'.

(defun emacs-todoist-api-item-add (content &rest args)
  "Build an `item_add' command for a task with CONTENT.
Keyword ARGS:
  :description  — task description string
  :project-id   — project ID string
  :parent-id    — parent task ID string
  :due-date     — deadline as \"YYYY-MM-DD\", converted to Todoist due object
  :temp-id      — temporary ID for the new item"
  (let ((cmd-args `((content . ,content)))
        (temp-id  (plist-get args :temp-id)))
    ;; Only include optional fields when explicitly provided.  We check
    ;; `plist-member' rather than `plist-get' so that nil-valued keys are
    ;; still omitted (a nil description is meaningless to Todoist).
    (when-let* ((desc (plist-get args :description)))
      (push `(description . ,desc) cmd-args))
    (when-let* ((pid (plist-get args :project-id)))
      (push `(project_id . ,pid) cmd-args))
    (when-let* ((pid (plist-get args :parent-id)))
      (push `(parent_id . ,pid) cmd-args))
    (when-let* ((date (plist-get args :due-date)))
      (push `(due . ((date . ,date))) cmd-args))
    (emacs-todoist-api-build-command "item_add" cmd-args temp-id)))

(defun emacs-todoist-api-item-update (id &rest args)
  "Build an `item_update' command for task ID.
Keyword ARGS:
  :content      — new title
  :description  — new description
  :due-date     — new deadline as \"YYYY-MM-DD\", or nil to clear
  :project-id   — move to a different project"
  (let ((cmd-args `((id . ,id))))
    (when-let* ((content (plist-get args :content)))
      (push `(content . ,content) cmd-args))
    (when-let* ((desc (plist-get args :description)))
      (push `(description . ,desc) cmd-args))
    (when-let* ((pid (plist-get args :project-id)))
      (push `(project_id . ,pid) cmd-args))
    (when-let* ((date (plist-get args :due-date)))
      (push `(due . ((date . ,date))) cmd-args))
    (emacs-todoist-api-build-command "item_update" cmd-args)))

(defun emacs-todoist-api-item-complete (ids)
  "Build `item_complete' commands for each ID in IDS.
IDS is a list of task ID strings.  Returns a list of command alists,
one per ID, since the Sync API v1 `item_complete' takes a single `id'."
  (mapcar (lambda (id)
            (emacs-todoist-api-build-command "item_complete" `((id . ,id))))
          ids))

(defun emacs-todoist-api-item-uncomplete (ids)
  "Build `item_uncomplete' commands for each ID in IDS.
Same semantics as `emacs-todoist-api-item-complete'."
  (mapcar (lambda (id)
            (emacs-todoist-api-build-command "item_uncomplete" `((id . ,id))))
          ids))

(defun emacs-todoist-api-item-delete (ids)
  "Build `item_delete' commands for each ID in IDS.
Same semantics as `emacs-todoist-api-item-complete'."
  (mapcar (lambda (id)
            (emacs-todoist-api-build-command "item_delete" `((id . ,id))))
          ids))

;; ==============================================================================
;; Response parsing
;; ==============================================================================

(defun emacs-todoist-api-parse-response (response)
  "Parse a Todoist Sync API RESPONSE alist.
Returns an alist with keys:
  `sync_token'      — new sync token string
  `sync_status'     — alist of uuid to status
  `temp_id_mapping' — alist of temp-id to real-id
  `items'           — list of item alists
  `projects'        — list of project alists
Missing keys in RESPONSE are returned as nil."
  `((sync_token      . ,(alist-get 'sync_token response))
    (sync_status     . ,(alist-get 'sync_status response))
    (temp_id_mapping . ,(alist-get 'temp_id_mapping response))
    (items           . ,(alist-get 'items response))
    (projects        . ,(alist-get 'projects response))))

;; ==============================================================================
;; Item hashing
;; ==============================================================================

(defun emacs-todoist-api-hash-item (item)
  "Compute SHA-1 of sync-relevant fields of a Todoist ITEM alist.
Hashes `content', `description', `due', and `checked' to produce the
TODOIST_REMOTE_HASH stored alongside org headings."
  (let* ((content     (alist-get 'content item))
         (description (alist-get 'description item))
         (due         (alist-get 'due item))
         (raw-checked (alist-get 'checked item))
         ;; Normalize checked: the API may return `:json-false' for
         ;; unchecked tasks, but locally we use 0.  Canonicalize to
         ;; 0/1 so hashes match across local and remote representations.
         ;; The API may return `t' (JSON true), 1, `:json-false'
         ;; (JSON false), 0, or nil.  Treat anything truthy that isn't
         ;; `:json-false' or 0 as checked.
         (checked (if (and raw-checked
                          (not (eq raw-checked :json-false))
                          (not (equal raw-checked 0)))
                      1 0)))
    (sha1 (format "%S" (list content description due checked)))))

;; ==============================================================================
;; JSON encoding helpers
;; ==============================================================================

(defun emacs-todoist-api--json-escape-non-ascii-char (char)
  "Return JSON-safe ASCII escape for Unicode codepoint CHAR."
  (if (<= char #xFFFF)
      (format "\\u%04x" char)
    (let* ((u (- char #x10000))
           (hi (+ #xD800 (lsh u -10)))
           (lo (+ #xDC00 (logand u #x3FF))))
      (format "\\u%04x\\u%04x" hi lo))))

(defun emacs-todoist-api--json-encode-ascii (obj)
  "JSON encode OBJ and escape all non-ASCII chars as \\uXXXX."
  (replace-regexp-in-string
   "[^\0-\177]"
   (lambda (s)
     (emacs-todoist-api--json-escape-non-ascii-char
      (string-to-char s)))
   (json-encode obj)
   t t))

;; ==============================================================================
;; Core sync call
;; ==============================================================================

(defun emacs-todoist-api-sync (sync-token resource-types commands callback)
  "Perform a Todoist Sync API call.
SYNC-TOKEN is the current sync token string (use \"*\" for a full sync).
RESOURCE-TYPES is a list of resource type strings (e.g. (\"items\")).
COMMANDS is a list of command alists, or nil for read-only syncs.
CALLBACK is called with the parsed response alist on success, or
an alist containing an `error' key on failure.

Uses `url-retrieve' for asynchronous HTTP."
  (let* ((url-request-method "POST")
         (url-request-extra-headers
          `(("Authorization" . ,(concat "Bearer " (emacs-todoist-api-token)))
            ("Content-Type"  . "application/json")))
         ;; Build the JSON request body.  `json-encode' handles converting
         ;; our alist/list structure to proper JSON.
         (body `((sync_token     . ,sync-token)
                 (resource_types . ,(vconcat resource-types))
                 (commands       . ,(vconcat (or commands [])))))
         ;; `url-retrieve' can signal "Multibyte text in HTTP request" when
         ;; payload text contains raw non-ASCII chars.  Keep the JSON
         ;; payload ASCII-only (\uXXXX escapes), then pass unibyte bytes.
         (url-request-data
          (string-as-unibyte
           (emacs-todoist-api--json-encode-ascii body))))
    (url-retrieve
     "https://api.todoist.com/api/v1/sync"
     (lambda (_status)
       (condition-case err
           (progn
             ;; Skip HTTP headers — the body follows the first blank line.
             (goto-char (point-min))
             (re-search-forward "\r?\n\r?\n")
             (let* ((json-object-type 'alist)
                    (json-array-type  'list)
                    (json-key-type    'symbol)
                    (parsed (json-read)))
               ;; The API returns a top-level `error' key on auth and
               ;; request-level failures (e.g. invalid token, 403).
               ;; Pass it through so callers see the error.
               (if (alist-get 'error parsed)
                   (funcall callback
                            `((error . ,(format "%s (code %s)"
                                                (alist-get 'error parsed)
                                                (alist-get 'error_code parsed)))))
                 (funcall callback
                          (emacs-todoist-api-parse-response parsed)))))
         (error
          (funcall callback `((error . ,(error-message-string err))))))))))

;; ==============================================================================
;; Convenience wrappers
;; ==============================================================================

(defun emacs-todoist-api-fetch-items (sync-token callback)
  "Fetch all items from Todoist using SYNC-TOKEN.
Calls CALLBACK with the parsed response.  This is a read-only sync
with no commands — only items are requested."
  (emacs-todoist-api-sync sync-token '("items") nil callback))

(defun emacs-todoist-api-fetch-projects (callback)
  "Fetch all projects from Todoist.
Calls CALLBACK with the parsed response.  Always performs a full sync
since projects are a session-level concern, not per-heading."
  (emacs-todoist-api-sync "*" '("projects") nil callback))

(provide 'emacs-todoist-api)
;;; emacs-todoist-api.el ends here
