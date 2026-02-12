;;; test-integration.el --- Integration tests for emacs-todoist  -*- lexical-binding: t; -*-

(require 'ert)
(require 'emacs-todoist)

(ert-deftest emacs-todoist-integration-smoke-test ()
  "Trivial smoke test to verify test infrastructure works."
  (should (featurep 'emacs-todoist)))

;;; test-integration.el ends here
