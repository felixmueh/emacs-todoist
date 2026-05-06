;;; test-find-heading.el --- Canonical heading lookup tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'org)
(require 'emacs-todoist-find-heading)

(defun emacs-todoist-test-find-heading--write-file (dir name text)
  "Write TEXT to NAME below DIR and return the file path."
  (let ((file (expand-file-name name dir)))
    (make-directory (file-name-directory file) t)
    (with-temp-file file
      (insert text))
    file))

(defmacro emacs-todoist-test-find-heading--with-env (&rest body)
  "Run BODY with isolated Org and lookup-cache state."
  (declare (indent 0))
  `(let* ((test-dir (make-temp-file "et-find-" t))
          (org-directory test-dir)
          (emacs-todoist-frontend-file-name "todoist.org")
          (emacs-todoist-find-heading-cache-file
           (expand-file-name "find-heading-cache.el" test-dir))
          (org-refile-targets nil)
          (buffers '()))
     (unwind-protect
         (cl-letf (((symbol-function 'find-file-noselect)
                    (lambda (file &rest args)
                      (let ((buf (apply (symbol-function
                                         'emacs-todoist-test-find-heading--real-find-file-noselect)
                                        file args)))
                        (push buf buffers)
                        buf))))
           ,@body)
       (dolist (buf buffers)
         (when (buffer-live-p buf)
           (kill-buffer buf)))
       (when (file-directory-p test-dir)
         (delete-directory test-dir t)))))

(defalias 'emacs-todoist-test-find-heading--real-find-file-noselect
  (symbol-function 'find-file-noselect))

(defun emacs-todoist-test-find-heading--write-cache (todoist-id plist)
  "Write one cache entry for TODOIST-ID with PLIST."
  (with-temp-file emacs-todoist-find-heading-cache-file
    (prin1 (list (cons todoist-id plist)) (current-buffer))
    (insert "\n")))

(defun emacs-todoist-test-find-heading--marker-in-file (file title)
  "Return a marker at heading TITLE in FILE."
  (let ((buf (find-file-noselect file)))
    (with-current-buffer buf
      (org-mode)
      (goto-char (point-min))
      (re-search-forward (format "^\\* TODO %s" (regexp-quote title)))
      (beginning-of-line)
      (copy-marker (point) t))))

(ert-deftest emacs-todoist-find-heading/current-file-wins-before-cache ()
  "Current non-frontend buffer is searched before cache hints."
  (emacs-todoist-test-find-heading--with-env
    (let* ((current-file
            (emacs-todoist-test-find-heading--write-file
             test-dir "current.org"
             "* TODO Current\n:PROPERTIES:\n:TODOIST_ID: t1\n:END:\n"))
           (cached-file
            (emacs-todoist-test-find-heading--write-file
             test-dir "cached.org"
             "* TODO Cached\n:PROPERTIES:\n:TODOIST_ID: t1\n:END:\n"))
           (current-buffer (find-file-noselect current-file)))
      (emacs-todoist-test-find-heading--write-cache
       "t1" (list :file cached-file :position 1 :title "Cached"))
      (let ((marker (with-current-buffer current-buffer
                      (org-mode)
                      (emacs-todoist-find-heading "t1" (current-buffer)))))
        (should marker)
        (should (equal current-file
                       (with-current-buffer (marker-buffer marker)
                         (buffer-file-name))))
        (should (equal 1 (with-current-buffer (marker-buffer marker)
                           (goto-char marker)
                           (org-current-level))))))))

(ert-deftest emacs-todoist-find-heading/cached-org-id-used-before-file ()
  "A cached Org ID is resolved and verified before cached file search."
  (emacs-todoist-test-find-heading--with-env
    (let* ((org-id-file
            (emacs-todoist-test-find-heading--write-file
             test-dir "org-id.org"
             "* TODO By ID\n:PROPERTIES:\n:ID: source-id\n:TODOIST_ID: t1\n:END:\n"))
           (cached-file
            (emacs-todoist-test-find-heading--write-file
             test-dir "cached.org"
             "* TODO By file\n:PROPERTIES:\n:TODOIST_ID: t1\n:END:\n"))
           (org-id-marker
            (emacs-todoist-test-find-heading--marker-in-file org-id-file "By ID")))
      (emacs-todoist-test-find-heading--write-cache
       "t1" (list :org-id "source-id" :file cached-file))
      (cl-letf (((symbol-function 'org-id-find)
                 (lambda (_id markerp)
                   (when markerp org-id-marker))))
        (let ((marker (emacs-todoist-find-heading "t1" nil)))
          (should marker)
          (should (equal org-id-file
                         (with-current-buffer (marker-buffer marker)
                           (buffer-file-name)))))))))

(ert-deftest emacs-todoist-find-heading/stale-org-id-rejected ()
  "Cached Org ID hints are rejected when TODOIST_ID does not match."
  (emacs-todoist-test-find-heading--with-env
    (let* ((stale-file
            (emacs-todoist-test-find-heading--write-file
             test-dir "stale.org"
             "* TODO Stale\n:PROPERTIES:\n:ID: source-id\n:TODOIST_ID: other\n:END:\n"))
           (cached-file
            (emacs-todoist-test-find-heading--write-file
             test-dir "cached.org"
             "* TODO Cached\n:PROPERTIES:\n:TODOIST_ID: t1\n:END:\n"))
           (stale-marker
            (emacs-todoist-test-find-heading--marker-in-file stale-file "Stale")))
      (emacs-todoist-test-find-heading--write-cache
       "t1" (list :org-id "source-id" :file cached-file))
      (cl-letf (((symbol-function 'org-id-find)
                 (lambda (_id markerp)
                   (when markerp stale-marker))))
        (let ((marker (emacs-todoist-find-heading "t1" nil)))
          (should marker)
          (should (equal cached-file
                         (with-current-buffer (marker-buffer marker)
                           (buffer-file-name)))))))))

(ert-deftest emacs-todoist-find-heading/frontend-org-id-rejected ()
  "Cached Org ID hints are rejected when they resolve to the frontend file."
  (emacs-todoist-test-find-heading--with-env
    (let* ((frontend-file
            (emacs-todoist-test-find-heading--write-file
             test-dir "todoist.org"
             "* TODO Frontend\n:PROPERTIES:\n:ID: view-id\n:TODOIST_ID: t1\n:END:\n"))
           (source-file
            (emacs-todoist-test-find-heading--write-file
             test-dir "source.org"
             "* TODO Source\n:PROPERTIES:\n:TODOIST_ID: t1\n:END:\n"))
           (frontend-marker
            (emacs-todoist-test-find-heading--marker-in-file
             frontend-file "Frontend")))
      (emacs-todoist-test-find-heading--write-cache
       "t1" (list :org-id "view-id" :file source-file))
      (cl-letf (((symbol-function 'org-id-find)
                 (lambda (_id markerp)
                   (when markerp frontend-marker))))
        (let ((marker (emacs-todoist-find-heading "t1" nil)))
          (should marker)
          (should (equal source-file
                         (with-current-buffer (marker-buffer marker)
                           (buffer-file-name)))))))))

(ert-deftest emacs-todoist-find-heading/cached-file-fallback-updates-cache ()
  "Cached file fallback finds the heading and refreshes cache metadata."
  (emacs-todoist-test-find-heading--with-env
    (let ((cached-file
           (emacs-todoist-test-find-heading--write-file
            test-dir "cached.org"
            "* TODO Cached\n:PROPERTIES:\n:ID: real-id\n:TODOIST_ID: t1\n:END:\n")))
      (emacs-todoist-test-find-heading--write-cache
       "t1" (list :file cached-file :position 999 :title "Old"))
      (let ((marker (emacs-todoist-find-heading "t1" nil)))
        (should marker)
        (let ((entry (cdr (assoc "t1"
                                 (emacs-todoist-find-heading--load-cache)))))
          (should (equal "real-id" (plist-get entry :org-id)))
          (should (equal "Cached" (plist-get entry :title)))
          (should (equal cached-file (plist-get entry :file))))))))

(ert-deftest emacs-todoist-find-heading/refile-files-fallback ()
  "Refiles target files are searched after cache hints."
  (emacs-todoist-test-find-heading--with-env
    (let ((refile-file
           (emacs-todoist-test-find-heading--write-file
            test-dir "refile.org"
            "* TODO Refile\n:PROPERTIES:\n:TODOIST_ID: t1\n:END:\n")))
      (let ((org-refile-targets `((,refile-file :maxlevel . 5))))
        (let ((marker (emacs-todoist-find-heading "t1" nil)))
          (should marker)
          (should (equal refile-file
                         (with-current-buffer (marker-buffer marker)
                          (buffer-file-name)))))))))

(ert-deftest emacs-todoist-find-heading/refile-function-target-fallback ()
  "Function-valued refile targets are resolved and searched."
  (emacs-todoist-test-find-heading--with-env
    (let ((refile-file
           (emacs-todoist-test-find-heading--write-file
            test-dir "refile-function.org"
            "* TODO Refile function\n:PROPERTIES:\n:TODOIST_ID: t1\n:END:\n")))
      (let ((org-refile-targets `(((lambda () (list ,refile-file))
                                   :maxlevel . 5))))
        (let ((marker (emacs-todoist-find-heading "t1" nil)))
          (should marker)
          (should (equal refile-file
                         (with-current-buffer (marker-buffer marker)
                           (buffer-file-name)))))))))

(ert-deftest emacs-todoist-find-heading/frontend-file-excluded ()
  "The Todoist frontend file is excluded from current, cache, and refile search."
  (emacs-todoist-test-find-heading--with-env
    (let* ((frontend-file
            (emacs-todoist-test-find-heading--write-file
             test-dir "todoist.org"
             "* TODO Frontend\n:PROPERTIES:\n:TODOIST_ID: t1\n:END:\n"))
           (source-file
            (emacs-todoist-test-find-heading--write-file
             test-dir "source.org"
             "* TODO Source\n:PROPERTIES:\n:TODOIST_ID: t1\n:END:\n"))
           (frontend-buffer (find-file-noselect frontend-file)))
      (emacs-todoist-test-find-heading--write-cache
       "t1" (list :file frontend-file :position 1 :title "Frontend"))
      (let ((org-refile-targets `((,frontend-file :maxlevel . 5)
                                  (,source-file :maxlevel . 5))))
        (let ((marker (with-current-buffer frontend-buffer
                        (org-mode)
                        (emacs-todoist-find-heading "t1" (current-buffer)))))
          (should marker)
          (should (equal source-file
                         (with-current-buffer (marker-buffer marker)
                           (buffer-file-name)))))))))

(ert-deftest emacs-todoist-find-heading/frontend-only-returns-nil ()
  "Lookup returns nil when the only matching heading is in the frontend file."
  (emacs-todoist-test-find-heading--with-env
    (let* ((frontend-file
            (emacs-todoist-test-find-heading--write-file
             test-dir "todoist.org"
             "* TODO Frontend\n:PROPERTIES:\n:TODOIST_ID: t1\n:END:\n"))
           (frontend-buffer (find-file-noselect frontend-file)))
      (emacs-todoist-test-find-heading--write-cache
       "t1" (list :file frontend-file :position 1 :title "Frontend"))
      (let ((org-refile-targets `((,frontend-file :maxlevel . 5))))
        (with-current-buffer frontend-buffer
          (org-mode)
          (should-not (emacs-todoist-find-heading "t1" (current-buffer))))))))

;;; test-find-heading.el ends here
