;;; run-tests.el --- Test runner for emacs-todoist  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Felix Mühlenberend
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Load all test files.
(require 'ert)

(let ((test-dir (file-name-directory (or load-file-name buffer-file-name))))
  (dolist (file (directory-files test-dir t "\\`test-.*\\.el\\'"))
    ;; Exclude live API tests — they hit the real Todoist API and are
    ;; run separately via `make test-live'.
    (unless (string-match-p "test-live" file)
      (load file nil t))))

;;; run-tests.el ends here
