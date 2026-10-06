;;; check-deps.el --- Refuse a dependency too old to test against -*- lexical-binding: t; -*-

;;; Commentary:

;; Usage, from the repository root:
;;
;;   eask exec emacs --batch -l scripts/check-deps.el
;;
;; `scripts/run-tests.sh' runs it first.  It exits non-zero, naming the
;; fix, when mcp-server-lib is missing or older than the version Eask
;; requires.
;;
;; The case it catches: `eask install-deps' leaves an installed MELPA
;; snapshot in place when the version in Eask rises, because a date
;; version like 20260319.1344 compares greater than 0.5.0.  A checkout
;; whose .eask predates the requirement therefore keeps the old
;; mcp-server-lib, and the suite fails in bulk, in places that each
;; look like something else.
;;
;; The probe is what 0.5.0, the version Eask requires, added: a tool
;; spec carrying `:param-schemas'.  0.5.0 adds no public symbol to test
;; for, and a private one would break on the release that renames it,
;; so the probe registers a throwaway server through the public API
;; and drops it again.  An older copy refuses the key, and a copy older
;; still lacks the function, and both read as stale.
;;
;; The require is soft so that a missing mcp-server-lib reaches the
;; message below.  A hard require signals `file-missing' first, and the
;; script prints a backtrace instead of the remedy -- which is the
;; failure it exists to replace.  Byte-compilation does not care either
;; way: the require sits inside the `cond', so the compiler never
;; evaluates it, and the two functions the probe calls are declared.

;;; Code:

(declare-function mcp-server-lib-register-server "mcp-server-lib")
(declare-function mcp-server-lib-unregister-server "mcp-server-lib")

(defconst check-deps--stale
  (concat
   "The installed mcp-server-lib is older than the version Eask "
   "requires.\n"
   "eask leaves a MELPA date version in place when that requirement "
   "rises, so remove it and reinstall:\n"
   "  rm -rf .eask/*/elpa/mcp-server-lib-*\n"
   "  just install-deps")
  "What to tell someone whose mcp-server-lib is too old.")

(defconst check-deps--missing
  "mcp-server-lib is not installed.  Run: just install-deps"
  "What to tell someone who has no mcp-server-lib at all.")

(defun check-deps--probe-tool (count)
  "Return COUNT, as the tool the probe registers.

MCP Parameters:
  count - A number"
  count)

(defun check-deps--param-schemas-p ()
  "Return non-nil when mcp-server-lib registers a tool with `:param-schemas'."
  (condition-case nil
      (progn
        (mcp-server-lib-register-server
         :id "check-deps"
         :tools
         (list
          (list #'check-deps--probe-tool
                :id "check-deps-probe"
                :description "Probe."
                :param-schemas '(("count" (type . "integer"))))))
        (mcp-server-lib-unregister-server "check-deps")
        t)
    (error nil)))

(cond
 ((not (require 'mcp-server-lib nil t))
  (message "%s" check-deps--missing)
  (kill-emacs 1))
 ((not (check-deps--param-schemas-p))
  (message "%s" check-deps--stale)
  (kill-emacs 1)))

(provide 'check-deps)
;;; check-deps.el ends here
