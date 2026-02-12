;;; emacs-todoist-api.el --- Todoist Sync API v1 wrapper  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Felix

;; Author: Felix
;; Keywords: comm

;;; Commentary:

;; Stateless Todoist Sync API v1 wrapper.  No org-mode dependency.
;; Sync tokens are passed in by callers and new tokens returned.

;;; Code:

(require 'json)
(require 'url)

(provide 'emacs-todoist-api)
;;; emacs-todoist-api.el ends here
