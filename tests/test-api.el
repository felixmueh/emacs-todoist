;;; test-api.el --- Tests for emacs-todoist-api  -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'emacs-todoist-api)

;; ==============================================================================
;; Smoke test
;; ==============================================================================

(ert-deftest emacs-todoist-api-smoke-test ()
  "Trivial smoke test to verify test infrastructure works."
  (should (featurep 'emacs-todoist-api)))

;; ==============================================================================
;; Token retrieval
;; ==============================================================================

(ert-deftest emacs-todoist-api-token/returns-string-directly ()
  "When `emacs-todoist-api-token' is a plain string, return it as-is."
  (let ((emacs-todoist-api-token "test-token-abc123"))
    (should (equal "test-token-abc123" (emacs-todoist-api-token)))))

(ert-deftest emacs-todoist-api-token/calls-function ()
  "When `emacs-todoist-api-token' is a function, call it to get the token.
This supports auth-source or password-store integration where the token
is retrieved dynamically."
  (let ((emacs-todoist-api-token (lambda () "dynamic-token-xyz")))
    (should (equal "dynamic-token-xyz" (emacs-todoist-api-token)))))

;; ==============================================================================
;; UUID generation
;; ==============================================================================

(ert-deftest emacs-todoist-api-uuid/matches-v4-format ()
  "Generated UUID must match the canonical 8-4-4-4-12 hex format
with version nibble 4 and variant bits 10xx."
  (let ((uuid (emacs-todoist-api-generate-uuid)))
    ;; Overall shape: 8-4-4-4-12 hex digits.
    (should (string-match-p
             "^[0-9a-f]\\{8\\}-[0-9a-f]\\{4\\}-4[0-9a-f]\\{3\\}-[89ab][0-9a-f]\\{3\\}-[0-9a-f]\\{12\\}$"
             uuid))))

(ert-deftest emacs-todoist-api-uuid/unique-values ()
  "Two consecutive UUID calls should produce different values.
Collision probability is astronomically low for proper randomness."
  (should-not (equal (emacs-todoist-api-generate-uuid)
                     (emacs-todoist-api-generate-uuid))))

;; ==============================================================================
;; build-command
;; ==============================================================================

(ert-deftest emacs-todoist-api-build-command/has-required-keys ()
  "A built command must contain `type', `uuid', and `args' keys."
  (let ((cmd (emacs-todoist-api-build-command "item_add" '((content . "Test")))))
    (should (equal "item_add" (alist-get 'type cmd)))
    (should (stringp (alist-get 'uuid cmd)))
    (should (equal '((content . "Test")) (alist-get 'args cmd)))))

(ert-deftest emacs-todoist-api-build-command/with-temp-id ()
  "When a temp-id is provided, the command includes a `temp_id' key."
  (let ((cmd (emacs-todoist-api-build-command "item_add" '((content . "X")) "tmp-123")))
    (should (equal "tmp-123" (alist-get 'temp_id cmd)))))

(ert-deftest emacs-todoist-api-build-command/without-temp-id ()
  "When no temp-id is given, `temp_id' should be absent from the command."
  (let ((cmd (emacs-todoist-api-build-command "item_add" '((content . "X")))))
    (should-not (assq 'temp_id cmd))))

;; ==============================================================================
;; item-add
;; ==============================================================================

(ert-deftest emacs-todoist-api-item-add/basic ()
  "Minimal item_add has the right type and content in args."
  (let ((cmd (emacs-todoist-api-item-add "Buy milk")))
    (should (equal "item_add" (alist-get 'type cmd)))
    (should (equal "Buy milk" (alist-get 'content (alist-get 'args cmd))))))

(ert-deftest emacs-todoist-api-item-add/optional-fields-absent ()
  "Without optional keyword args, only `content' appears in args."
  (let* ((cmd (emacs-todoist-api-item-add "Simple task"))
         (args (alist-get 'args cmd)))
    (should-not (assq 'description args))
    (should-not (assq 'project_id args))
    (should-not (assq 'parent_id args))
    (should-not (assq 'due args))))

(ert-deftest emacs-todoist-api-item-add/all-optional-fields ()
  "All optional keyword args appear in the command args when provided."
  (let* ((cmd (emacs-todoist-api-item-add "Task"
               :description "Details"
               :project-id "proj-1"
               :parent-id "parent-1"
               :due-date "2026-01-15"))
         (args (alist-get 'args cmd)))
    (should (equal "Details" (alist-get 'description args)))
    (should (equal "proj-1" (alist-get 'project_id args)))
    (should (equal "parent-1" (alist-get 'parent_id args)))
    ;; Due date is wrapped in the Todoist due object structure.
    (should (equal '((date . "2026-01-15")) (alist-get 'due args)))))

(ert-deftest emacs-todoist-api-item-add/due-date-structure ()
  "`:due-date' must produce the nested `(due (date . \"...\"))' alist
that the Todoist Sync API expects."
  (let* ((cmd (emacs-todoist-api-item-add "Deadline task" :due-date "2026-01-15"))
         (due (alist-get 'due (alist-get 'args cmd))))
    (should (equal "2026-01-15" (alist-get 'date due)))))

(ert-deftest emacs-todoist-api-item-add/temp-id ()
  "`:temp-id' sets the `temp_id' field on the outer command, not in args."
  (let ((cmd (emacs-todoist-api-item-add "New task" :temp-id "tmp-abc")))
    (should (equal "tmp-abc" (alist-get 'temp_id cmd)))
    ;; temp_id should not leak into the args.
    (should-not (assq 'temp_id (alist-get 'args cmd)))))

;; ==============================================================================
;; item-update
;; ==============================================================================

(ert-deftest emacs-todoist-api-item-update/type-and-id ()
  "item_update command has correct type and includes `id' in args."
  (let ((cmd (emacs-todoist-api-item-update "task-42" :content "New title")))
    (should (equal "item_update" (alist-get 'type cmd)))
    (should (equal "task-42" (alist-get 'id (alist-get 'args cmd))))))

(ert-deftest emacs-todoist-api-item-update/only-provided-fields ()
  "Only keyword args that are actually passed appear in the command args.
This prevents accidentally clearing fields on Todoist's side."
  (let* ((cmd (emacs-todoist-api-item-update "task-42" :content "Updated"))
         (args (alist-get 'args cmd)))
    (should (equal "Updated" (alist-get 'content args)))
    ;; Fields not provided should be absent.
    (should-not (assq 'description args))
    (should-not (assq 'due args))
    (should-not (assq 'project_id args))))

(ert-deftest emacs-todoist-api-item-update/due-date ()
  "`:due-date' in item_update produces the same nested structure as item_add."
  (let* ((cmd (emacs-todoist-api-item-update "task-42" :due-date "2026-03-01"))
         (due (alist-get 'due (alist-get 'args cmd))))
    (should (equal "2026-03-01" (alist-get 'date due)))))

;; ==============================================================================
;; item-complete
;; ==============================================================================

(ert-deftest emacs-todoist-api-item-complete/single-id ()
  "A single ID produces exactly one `item_complete' command."
  (let ((cmds (emacs-todoist-api-item-complete '("id-1"))))
    (should (= 1 (length cmds)))
    (should (equal "item_complete" (alist-get 'type (car cmds))))
    (should (equal "id-1" (alist-get 'id (alist-get 'args (car cmds)))))))

(ert-deftest emacs-todoist-api-item-complete/multiple-ids ()
  "Multiple IDs produce one command per ID, preserving order."
  (let ((cmds (emacs-todoist-api-item-complete '("id-1" "id-2" "id-3"))))
    (should (= 3 (length cmds)))
    (should (equal "id-1" (alist-get 'id (alist-get 'args (nth 0 cmds)))))
    (should (equal "id-2" (alist-get 'id (alist-get 'args (nth 1 cmds)))))
    (should (equal "id-3" (alist-get 'id (alist-get 'args (nth 2 cmds)))))))

;; ==============================================================================
;; item-uncomplete
;; ==============================================================================

(ert-deftest emacs-todoist-api-item-uncomplete/type ()
  "item_uncomplete commands have the correct type string."
  (let ((cmds (emacs-todoist-api-item-uncomplete '("id-1"))))
    (should (= 1 (length cmds)))
    (should (equal "item_uncomplete" (alist-get 'type (car cmds))))))

(ert-deftest emacs-todoist-api-item-uncomplete/multiple-ids ()
  "Multiple IDs produce one `item_uncomplete' per ID."
  (let ((cmds (emacs-todoist-api-item-uncomplete '("a" "b"))))
    (should (= 2 (length cmds)))
    (should (equal "a" (alist-get 'id (alist-get 'args (nth 0 cmds)))))
    (should (equal "b" (alist-get 'id (alist-get 'args (nth 1 cmds)))))))

;; ==============================================================================
;; item-delete
;; ==============================================================================

(ert-deftest emacs-todoist-api-item-delete/type ()
  "item_delete commands have the correct type string."
  (let ((cmds (emacs-todoist-api-item-delete '("id-1"))))
    (should (= 1 (length cmds)))
    (should (equal "item_delete" (alist-get 'type (car cmds))))))

(ert-deftest emacs-todoist-api-item-delete/multiple-ids ()
  "Multiple IDs produce one `item_delete' per ID."
  (let ((cmds (emacs-todoist-api-item-delete '("x" "y" "z"))))
    (should (= 3 (length cmds)))
    (should (equal "x" (alist-get 'id (alist-get 'args (nth 0 cmds)))))
    (should (equal "y" (alist-get 'id (alist-get 'args (nth 1 cmds)))))
    (should (equal "z" (alist-get 'id (alist-get 'args (nth 2 cmds)))))))

;; ==============================================================================
;; parse-response
;; ==============================================================================

(ert-deftest emacs-todoist-api-parse-response/extracts-sync-token ()
  "The sync_token field is extracted from the raw API response."
  (let* ((response '((sync_token . "new-token-123")))
         (parsed (emacs-todoist-api-parse-response response)))
    (should (equal "new-token-123" (alist-get 'sync_token parsed)))))

(ert-deftest emacs-todoist-api-parse-response/extracts-temp-id-mapping ()
  "temp_id_mapping is passed through from the response."
  (let* ((mapping '((tmp-1 . "real-1") (tmp-2 . "real-2")))
         (response `((temp_id_mapping . ,mapping)))
         (parsed (emacs-todoist-api-parse-response response)))
    (should (equal mapping (alist-get 'temp_id_mapping parsed)))))

(ert-deftest emacs-todoist-api-parse-response/extracts-items ()
  "The items list is extracted from the response."
  (let* ((items '(((id . "1") (content . "Task A"))
                  ((id . "2") (content . "Task B"))))
         (response `((items . ,items)))
         (parsed (emacs-todoist-api-parse-response response)))
    (should (equal items (alist-get 'items parsed)))))

(ert-deftest emacs-todoist-api-parse-response/extracts-sync-status ()
  "sync_status (uuid to ok/error mapping) is extracted."
  (let* ((status '((uuid-1 . "ok") (uuid-2 . ((error_code . 42)))))
         (response `((sync_status . ,status)))
         (parsed (emacs-todoist-api-parse-response response)))
    (should (equal status (alist-get 'sync_status parsed)))))

(ert-deftest emacs-todoist-api-parse-response/missing-keys-return-nil ()
  "Keys absent from the response should yield nil, not an error."
  (let ((parsed (emacs-todoist-api-parse-response '())))
    (should (null (alist-get 'sync_token parsed)))
    (should (null (alist-get 'sync_status parsed)))
    (should (null (alist-get 'temp_id_mapping parsed)))
    (should (null (alist-get 'items parsed)))))

(ert-deftest emacs-todoist-api-parse-response/empty-response ()
  "nil as response should not error, treating all fields as absent."
  (let ((parsed (emacs-todoist-api-parse-response nil)))
    (should (null (alist-get 'sync_token parsed)))))

;; ==============================================================================
;; hash-item
;; ==============================================================================

(ert-deftest emacs-todoist-api-hash-item/stability ()
  "Hashing the same item twice produces the same result."
  (let ((item '((content . "Buy eggs") (description . "From the farm")
                (due . ((date . "2026-02-01"))) (checked . 0))))
    (should (equal (emacs-todoist-api-hash-item item)
                   (emacs-todoist-api-hash-item item)))))

(ert-deftest emacs-todoist-api-hash-item/content-changes-hash ()
  "Changing `content' must produce a different hash."
  (let ((item-a '((content . "Buy eggs") (description . "") (due) (checked . 0)))
        (item-b '((content . "Buy milk") (description . "") (due) (checked . 0))))
    (should-not (equal (emacs-todoist-api-hash-item item-a)
                       (emacs-todoist-api-hash-item item-b)))))

(ert-deftest emacs-todoist-api-hash-item/description-changes-hash ()
  "Changing `description' must produce a different hash."
  (let ((item-a '((content . "Task") (description . "Desc A") (due) (checked . 0)))
        (item-b '((content . "Task") (description . "Desc B") (due) (checked . 0))))
    (should-not (equal (emacs-todoist-api-hash-item item-a)
                       (emacs-todoist-api-hash-item item-b)))))

(ert-deftest emacs-todoist-api-hash-item/description-trims-surrounding-whitespace ()
  "Leading/trailing whitespace in `description' is ignored for hashing."
  (let ((item-a '((content . "Task") (description . "Body text") (due) (checked . 0)))
        (item-b '((content . "Task") (description . "\n  Body text \n") (due) (checked . 0))))
    (should (equal (emacs-todoist-api-hash-item item-a)
                   (emacs-todoist-api-hash-item item-b)))))

(ert-deftest emacs-todoist-api-hash-item/content-trims-surrounding-whitespace ()
  "Leading/trailing whitespace in `content' is ignored for hashing."
  (let ((item-a '((content . "Task") (description . "") (due) (checked . 0)))
        (item-b '((content . "  Task  ") (description . "") (due) (checked . 0))))
    (should (equal (emacs-todoist-api-hash-item item-a)
                   (emacs-todoist-api-hash-item item-b)))))

(ert-deftest emacs-todoist-api-hash-item/ignores-text-properties ()
  "Text properties on content/description are ignored for hashing."
  (let* ((content (copy-sequence "Task"))
         (description (copy-sequence "Body"))
         (plain '((content . "Task") (description . "Body") (due) (checked . 0)))
         (prop nil))
    (add-text-properties 0 (length content) '(face bold) content)
    (add-text-properties 0 (length description) '(face italic) description)
    (setq prop `((content . ,content) (description . ,description) (due) (checked . 0)))
    (should (equal (emacs-todoist-api-hash-item plain)
                   (emacs-todoist-api-hash-item prop)))))

(ert-deftest emacs-todoist-api-hash-item/due-changes-hash ()
  "Changing `due' must produce a different hash."
  (let ((item-a '((content . "Task") (description . "") (due (date . "2026-01-01")) (checked . 0)))
        (item-b '((content . "Task") (description . "") (due (date . "2026-12-31")) (checked . 0))))
    (should-not (equal (emacs-todoist-api-hash-item item-a)
                       (emacs-todoist-api-hash-item item-b)))))

(ert-deftest emacs-todoist-api-hash-item/checked-changes-hash ()
  "Changing `checked' (0 vs 1) must produce a different hash."
  (let ((item-a '((content . "Task") (description . "") (due) (checked . 0)))
        (item-b '((content . "Task") (description . "") (due) (checked . 1))))
    (should-not (equal (emacs-todoist-api-hash-item item-a)
                       (emacs-todoist-api-hash-item item-b)))))

;; ==============================================================================
;; sync — mocked HTTP
;; ==============================================================================

(ert-deftest emacs-todoist-api-sync/sends-correct-request ()
  "Verify that `emacs-todoist-api-sync' constructs the right HTTP request
and parses a mock JSON response.  We mock `url-retrieve' to avoid any
real network calls."
  (let* ((emacs-todoist-api-token "test-token")
         (captured-url nil)
         (captured-method nil)
         (captured-headers nil)
         (captured-data nil)
         (callback-result nil))
    ;; Mock `url-retrieve' to capture what was sent and immediately invoke
    ;; the callback with a fake HTTP response buffer.
    (cl-letf (((symbol-function 'url-retrieve)
               (lambda (url callback &rest _args)
                 (setq captured-url url)
                 (setq captured-method url-request-method)
                 (setq captured-headers url-request-extra-headers)
                 (setq captured-data url-request-data)
                 ;; Simulate an HTTP response buffer with JSON body.
                 (with-temp-buffer
                   (insert "HTTP/1.1 200 OK\r\n")
                   (insert "Content-Type: application/json\r\n")
                   (insert "\r\n")
                   (insert "{\"sync_token\":\"new-tok\",\"items\":[{\"id\":\"1\",\"content\":\"Test\"}]}")
                   (funcall callback nil)))))
      (emacs-todoist-api-sync
       "*" '("items") nil
       (lambda (resp) (setq callback-result resp))))
    ;; Verify the request was constructed correctly.
    (should (equal "https://api.todoist.com/api/v1/sync" captured-url))
    (should (equal "POST" captured-method))
    (should (equal "Bearer test-token"
                   (alist-get "Authorization" captured-headers nil nil #'equal)))
    (should (equal "application/json"
                   (alist-get "Content-Type" captured-headers nil nil #'equal)))
    ;; Verify the callback received parsed data.
    (should (equal "new-tok" (alist-get 'sync_token callback-result)))
    (should (equal "1" (alist-get 'id (car (alist-get 'items callback-result)))))))

(ert-deftest emacs-todoist-api-sync/error-handling ()
  "When the HTTP response is malformed, the callback receives an error alist
instead of crashing."
  (let* ((emacs-todoist-api-token "test-token")
         (callback-result nil))
    (cl-letf (((symbol-function 'url-retrieve)
               (lambda (_url callback &rest _args)
                 ;; Simulate a response with no body — `json-read' will fail.
                 (with-temp-buffer
                   (insert "HTTP/1.1 500 Internal Server Error\r\n\r\n")
                   (funcall callback nil)))))
      (emacs-todoist-api-sync
       "*" '("items") nil
       (lambda (resp) (setq callback-result resp))))
    ;; The callback should have received an error alist, not a crash.
    (should (alist-get 'error callback-result))))

(ert-deftest emacs-todoist-api-sync/escapes-non-ascii-request-body ()
  "Sync request body is ASCII-only and escapes Unicode payload text."
  (let* ((emacs-todoist-api-token "test-token")
         (captured-data nil))
    (cl-letf (((symbol-function 'url-retrieve)
               (lambda (_url callback &rest _args)
                 (setq captured-data url-request-data)
                 (with-temp-buffer
                   (insert "HTTP/1.1 200 OK\r\n")
                   (insert "Content-Type: application/json\r\n")
                   (insert "\r\n")
                   (insert "{\"sync_token\":\"tok\",\"items\":[]}")
                   (funcall callback nil)))))
      (emacs-todoist-api-sync
       "*" '("items")
       '(((type . "item_update")
          (uuid . "u-1")
          (args . ((id . "task-1")
                   (content . "über test")
                   (description . "naïve")))))
       #'ignore))
    (should captured-data)
    (should-not (multibyte-string-p captured-data))
    (let ((payload (decode-coding-string captured-data 'utf-8)))
      (should (string-match-p "\\\\u00fcber test" payload))
      (should (string-match-p "na\\\\u00efve" payload))
      (should-not (string-match-p "über test" payload)))))

;; ==============================================================================
;; fetch-items — convenience wrapper
;; ==============================================================================

(ert-deftest emacs-todoist-api-fetch-items/delegates-to-sync ()
  "Verify `fetch-items' calls `sync' with resource_types=[\"items\"]
and no commands."
  (let* ((captured-token nil)
         (captured-types nil)
         (captured-cmds nil))
    (cl-letf (((symbol-function 'emacs-todoist-api-sync)
               (lambda (token types cmds callback)
                 (setq captured-token token
                       captured-types types
                       captured-cmds cmds)
                 (funcall callback '((sync_token . "tok"))))))
      (emacs-todoist-api-fetch-items "*" #'ignore))
    (should (equal "*" captured-token))
    (should (equal '("items") captured-types))
    (should (null captured-cmds))))

;;; test-api.el ends here
