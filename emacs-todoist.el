;;; emacs-todoist.el --- Bidirectional sync between org-mode and Todoist  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Felix

;; Author: Felix
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1"))
;; Keywords: outlines, convenience, comm
;; URL: https://github.com/felix/emacs-todoist

;;; Commentary:

;; Bidirectionally syncs org-mode TODOs with Todoist via the Sync API v1.
;; Provides an ephemeral org-mode buffer as a Todoist frontend.

;;; Code:

(require 'emacs-todoist-org)
(require 'emacs-todoist-api)

(provide 'emacs-todoist)
;;; emacs-todoist.el ends here
