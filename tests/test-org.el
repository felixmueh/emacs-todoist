;;; test-org.el --- Tests for emacs-todoist-org  -*- lexical-binding: t; -*-

(require 'ert)
(require 'emacs-todoist-org)

(ert-deftest emacs-todoist-org-smoke-test ()
  "Trivial smoke test to verify test infrastructure works."
  (should (featurep 'emacs-todoist-org)))

;;; test-org.el ends here
