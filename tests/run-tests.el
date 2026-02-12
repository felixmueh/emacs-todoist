;;; run-tests.el --- Test runner for emacs-todoist  -*- lexical-binding: t; -*-

;; Load all test files.
(require 'ert)

(let ((test-dir (file-name-directory (or load-file-name buffer-file-name))))
  (dolist (file (directory-files test-dir t "\\`test-.*\\.el\\'"))
    (load file nil t)))

;;; run-tests.el ends here
