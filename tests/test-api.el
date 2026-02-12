;;; test-api.el --- Tests for emacs-todoist-api  -*- lexical-binding: t; -*-

(require 'ert)
(require 'emacs-todoist-api)

(ert-deftest emacs-todoist-api-smoke-test ()
  "Trivial smoke test to verify test infrastructure works."
  (should (featurep 'emacs-todoist-api)))

;;; test-api.el ends here
