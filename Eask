;; -*- mode: eask; lexical-binding: t -*-

(package "org-records-mcp"
         "0.11.0"
         "MCP server for Org-mode")

(website-url "https://github.com/stfl/org-records-mcp")
(keywords "convenience" "files" "matching" "outlines")

(source "melpa")

(depends-on "emacs" "30.1")
(depends-on "mcp-server-lib" "0.4.0")
(depends-on "org-ql" "0.9")

(setq network-security-level 'low)

(package-file "org-records-mcp.el")

(files "org-records-mcp.el"
       "org-records-mcp-stdio.sh")

(script "test" "eask test ert org-records-mcp-test.el")

(script "org-lint"
        (concat "emacs -Q --batch "
                "--eval \"(require 'org)\" "
                "--eval \"(require 'org-lint)\" "
                "--eval \"(let ((all-checks-passed t) "
                        "(files (append "
                                 "(list \\\"README.org\\\" \\\"CONTRIBUTING.org\\\") "
                                 "(directory-files-recursively "
                                   "\\\"docs\\\" \\\"[.]org$\\\")))) "
                    "(dolist (file files all-checks-passed) "
                      "(let ((path (expand-file-name file))) "
                        "(with-temp-buffer "
                          "(setq default-directory (file-name-directory path)) "
                          "(insert-file-contents path) "
                          "(org-mode) "
                          "(let* ((all-results (org-lint)) "
                                 "(results (seq-filter "
                                           "(lambda (r) "
                                             "(not (string= (aref (cadr r) 1) \\\"low\\\"))) "
                                           "all-results))) "
                            "(when results "
                              "(message \\\"Found issues in %s: %S\\\" file results) "
                              "(setq all-checks-passed nil)))))) "
                    "(unless all-checks-passed (kill-emacs 1)))\""))
