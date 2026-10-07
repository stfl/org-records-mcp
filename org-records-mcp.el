;;; org-records-mcp.el --- MCP server for Org-mode -*- lexical-binding: t; -*-

;; Copyright (C) 2025 Laurynas Biveinis, Stefan Lendl

;; Author: Laurynas Biveinis <laurynas.biveinis@gmail.com>
;;         Stefan Lendl <s@stfl.dev>
;; Maintainer: Stefan Lendl <s@stfl.dev>
;; Keywords: convenience, files, matching, outlines
;; Version: 0.12.0
;; Package-Requires: ((emacs "30.1") (mcp-server-lib "0.5.0") (org-ql "0.9"))
;; Homepage: https://github.com/stfl/org-records-mcp

;; This file is NOT part of GNU Emacs.

;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see
;; <https://www.gnu.org/licenses/>.

;;; Commentary:

;; This package implements a Model Context Protocol (MCP) server for
;; Org-mode.

;;; Code:

(require 'cl-lib)
(require 'mcp-server-lib)
(require 'org)
(require 'org-archive)
(require 'org-element)
(require 'org-id)
(require 'org-ql)
(require 'org-refile)
(require 'org-clock)
(require 'url-util)

(defcustom org-records-mcp-allowed-files nil
  "List of paths to Org files that can be accessed via MCP.
Entries may be absolute or relative paths.  Relative paths are
resolved against `org-directory', matching the behavior of
`org-agenda-files'.  Tilde expansion (`~/...') and environment
variable substitution apply.  Absolute paths pass through
unchanged, so absolute and relative entries are interchangeable.

When nil (the default), org-records-mcp falls back to `org-agenda-files',
so an existing Org-mode configuration works out of the box.  Set
this variable explicitly to expose a different (or narrower) set
of files to MCP.

Each entry names a file.  A directory entry is ignored: it does not
make the files under it reachable.  To let calls reach files under a
directory, see `org-records-mcp-file-scope-override'."
  :type '(repeat file)
  :group 'org-records-mcp)

(defcustom org-records-mcp-file-scope-override nil
  "Whether a call may reach an Org file outside the allowed files.
The allowed files are the ones `org-records-mcp-allowed-files' resolves to.
A call names another file by passing its path, and this setting
decides whether that is permitted:

  nil          Refuse.  Only the allowed files are reachable.  This
               is the default.

  A list of    Permit a file under one of these directories, the
  directories  override roots.  Relative roots resolve against
               `org-directory'.

  t            Permit any Org file.  Every Org file the Emacs
               process can read and write becomes readable and
               writable by MCP clients.  Prefer a list of roots.

The permission covers reading and writing alike and applies only to
the call that names the file; nothing carries over to later calls.
An `id:' link names the file Emacs's ID index places its ID in, so
this setting reaches that file as it reaches the file of a `file:'
link.  The file of the running clock is not named by the call and
stays within the allowed files, a clock starts only in the allowed
files, and a view always runs over the allowed files alone.

A file reachable this way is an existing local file ending in
`.org' or `.org_archive'; an encrypted `.org.gpg' file is not.
A path that is remote (TRAMP) as written, once `.', `..' and `~'
are expanded, or at the end of a symlink is refused before TRAMP
can open a connection for it, and a remote root is ignored.  Symlinks,
including roots that are symlinks, are resolved before the root
check, so a symlink pointing out of a root is refused."
  :type
  '(choice
    (const :tag "Refuse" nil)
    (const :tag "Permit any Org file" t)
    (repeat :tag "Permit under these directories" directory))
  :group 'org-records-mcp)

(defcustom org-records-mcp-node-field-lists
  '((reference link) (outline title todo level link))
  "Named lists of node fields a call can ask for by name.
A call says how much of a node it wants in its `fields' parameter,
either as a list of field names or, more shortly, as the name of a
list here.  Each entry is (NAME FIELD...), NAME the name a call
sends as a string and FIELD a field of `org-records-mcp--node-fields'; a
call naming a list that is not here, or a list naming a field that
does not exist, is refused.

The two lists it starts with are the two shapes the surface itself
has a word for: `reference' is a node carrying its link alone, the
smallest thing a later call can be made from, and `outline' adds
what it takes to show the node in an outline.  They are a starting
point rather than the set: a workflow that asks the same question
repeatedly gives that question a name here, and the whole point of
the setting is that org-records-mcp does not decide which names exist."
  :type '(alist :key-type symbol :value-type (repeat symbol))
  :group 'org-records-mcp)

(defcustom org-records-mcp-computed-fields nil
  "Values a workflow computes for a node as it is read.
Each entry is (NAME . FUNCTION): NAME both the name a call asks for
and the key the value arrives under, FUNCTION called with no
arguments at the node while its response is built.  An answer of nil
is left out, the way a node field with no value is.

A computed field is this server's answer at the moment of reading --
a ranking, say, or the priority of a parent -- so it belongs to no
drawer and no write puts it back.  It arrives under `computed',
apart from the Org drawer under `properties', and that is what keeps
a client from writing one into a file as though it had been stored
there.

Nothing is configured out of the box: what is worth computing is the
workflow's question rather than this server's, and an external
package populates this as it populates `org-records-mcp-node-field-lists'.
A read carries every field configured here; a match list carries
the ones `org-records-mcp-list-computed-fields' names."
  :type '(alist :key-type symbol :value-type function)
  :group 'org-records-mcp)

(defcustom org-records-mcp-list-fields
  '(title todo priority tags scheduled deadline link)
  "The node fields a match list carries unasked.
org-query and org-view return each match as a line of an overview,
and a client reads the node behind a line by its link.  Out of the
box a line carries what it takes to triage the match -- its title,
state, priority, tags and dates -- and that link.  The body and the
children are left to the read, since filling them would read every
matched subtree.

The value is a list of node field names, the ones a call's `fields'
parameter takes and docs/reading.org lists under \"The node\".  A
workflow whose lists answer another question adds the fields that
answer it.  A call's `fields' parameter replaces the list, so a
client asks for the rest by name.  A name here that is no node field
is refused at a call that takes the default, naming this setting."
  :type '(repeat symbol)
  :group 'org-records-mcp)

(defcustom org-records-mcp-list-computed-fields nil
  "The computed fields a match list carries unasked.
org-query and org-view return each match as a line of an overview.
A computed field that answers a question of the list -- a rank the
matches are sorted by, the priority of a match's parent -- belongs
on the line; one that describes the node on its own belongs to the read,
which carries every one.

The value is a list of names from `org-records-mcp-computed-fields',
or `all' for every field it configures.  Out of the box it is empty,
as that setting is: what is worth computing is the workflow's
question, and the package that configures a computed field adds the
ones its lists sort or group by here.  A call's `computed' parameter
replaces it, so a client asks for the rest by name.  A name here
that `org-records-mcp-computed-fields' does not configure is refused
at a call that takes the default, naming this setting."
  :type
  '(choice
    (repeat :tag "These fields" symbol)
    (const :tag "Every configured field" all))
  :group 'org-records-mcp)

(defcustom org-records-mcp-read-max-nodes 500
  "The most nodes one read of a node returns.
A call expands as many generations of children as its `depth' asks
for, and a few generations of a large outline run to far more of the
file than the caller meant to ask for.  A read whose walk passes
this many nodes is refused, naming the node it stopped at so that
the caller can read that node on its own instead.

It is never trimmed to fit: a caller handed a subtree that was
silently shortened believes it has seen the whole thing and has no
way to find out otherwise.

The count is every node the response carries -- the node that was
read, the generations expanded under it, and the references that
end the walk -- so raising it raises what one call may return."
  :type 'natnum
  :group 'org-records-mcp)

(defcustom org-records-mcp-history-max-revisions 200
  "The most revisions of a file one history of a heading reads.
org-node-history reads the file as every commit in its window holds
it, whether or not that commit changed the heading, and a window
reaching far back on a file committed every few minutes reads far
more of it than the caller meant to ask about.  A history whose
window holds more revisions of the file than this is refused, naming
the remedy, a later `since'.

It is never trimmed to fit: a history silently cut short reads like
one that is complete."
  :type 'natnum
  :group 'org-records-mcp)

(defcustom org-records-mcp-clock-continuous-threshold 30
  "Max minutes since last clock-out for continuous clocking.
When `org-clock-continuously' is non-nil and a new clock-in without
an explicit start occurs within this many minutes of the last
clock-out, the new clock starts at that clock-out rather than at the
current time.  A gap of exactly this many minutes still continues;
one a second longer does not.

The last clock-out is the latest end of a closed clock in the allowed
files at or before the current time: a clock ending later is passed
over, and the one before it continues.  The end of a running clock
the same call closes counts, even where rounding writes it after the
current time.  An explicit start is taken as given.  Whichever start
is chosen is written through `org-clock-rounding-minutes' like any
other, so under rounding it can differ from the previous clock's end."
  :type 'integer
  :group 'org-records-mcp)

(defcustom org-records-mcp-views nil
  "Named views the org-view tool runs, one question of the outline each.
A workflow generates this from the definitions that build its agenda
commands, so a view and the agenda block beside it cannot answer
differently.  While it is nil the org-view tool is not registered.

Each entry is (NAME . PLIST).  NAME is the symbol a call names the
view by; PLIST declares it:

  :name   A label for a reader, carried in the tool description.
  :query  The org-ql query the view asks: a function returning the
          sexp, or a literal sexp for a view that takes no
          parameters.
  :filter Non-nil when the view takes a filter, named from
          `org-records-mcp-filters'.
  :range  The range names the view takes, the first of them the
          range it runs at unasked.  A single name may be written
          without the parentheses.  Absent, the view takes no range.

A view is called with the parameters it declares and no others, in
the order filter then range, so the declaration is the calling
convention as much as it is the vocabulary: a filter reaches the
query as the sexp `org-records-mcp-filters' holds for it, and a range as one
of the symbols :range lists.  A call naming a parameter the view
does not declare is refused rather than ignored, because a caller
that believes it narrowed a search which in fact returned everything
has no way to find out."
  :type '(alist :key-type symbol :value-type plist)
  :group 'org-records-mcp)

(defcustom org-records-mcp-filters nil
  "Named restrictions a view is asked under, such as one project.
Each entry is (NAME . SEXP): NAME the symbol a call names the filter
by, SEXP the org-ql expression the view's query folds into its own.

A call names a filter rather than writing one, and a name that is
not here is refused with the names that are.  The closed vocabulary
is the point: a caller handed an expression slot invents predicates
that do not exist, and org-ql then either errors confusingly or
matches nothing.  A caller that genuinely wants to write a query has
the org-query tool."
  :type '(alist :key-type symbol :value-type sexp)
  :group 'org-records-mcp)

(defcustom org-records-mcp-view-catalogue-function nil
  "Function writing the views part of the org-view tool description.
When nil, the description lists every view in `org-records-mcp-views', one
line each, with what it takes.  When non-nil, it is a function of
no arguments returning a string, and that string stands in place of
those lines, indented as the caller wants it and ending its last
line with a newline, which is added when it is missing.

It suits a workflow whose views follow a rule, such as an area and a
question joined into one name, where the rule tells a client more
than the list of every name it produces.  The function is called
when `org-records-mcp-enable' registers the tools.  It changes what a client
reads and nothing a call does: a view runs by the name
`org-records-mcp-views' gives it, and an unknown name or a parameter the
view does not take is refused, whatever the description says."
  :type '(choice (const :tag "List every view" nil) function)
  :group 'org-records-mcp)

(defcustom org-records-mcp-query-sort-fn nil
  "Sort comparator the org-view tool answers in the order of.
Passed as the `:sort' argument to `org-ql-select'.
When nil, no sorting is applied."
  :type '(choice (const :tag "No sorting" nil) function)
  :group 'org-records-mcp)

(defconst org-records-mcp--server-id "org-records-mcp"
  "Server ID for org-records-mcp MCP server registration.")

(defconst org-records-mcp-version
  (eval-when-compile
    (require 'package)
    ;; `package-get-version' finds this file whether it is byte-compiled
    ;; from the repository checkout or from an installed package: it
    ;; reads the version from the `<name>-<version>' directory an ELPA
    ;; install unpacks into, and only falls back to this file's header
    ;; (`Version:' or `Package-Version:', an install can carry either)
    ;; when the directory name does not carry one, e.g. a checkout run
    ;; straight from source.
    (package-get-version))
  "Version org-records-mcp reports as `serverInfo.version' in the handshake.
Computed once, at compile time, by `package-get-version', so it cannot
drift from the package metadata the way a second copy of the string
would.")

;; Error handling helpers
;;
;; A refusal a client acts on carries its class as a prefix on the
;; message.  The transport has no error code of any kind:
;; `mcp-server-lib-tool-throw' carries a string, and the org://{link}
;; resource re-signals that same string as JSON-RPC `invalid-params', so
;; a marker inside the message is the only thing both paths keep.  The
;; prefixes live in the helpers below and nowhere else, so that no call
;; site can raise a conflict that is not marked as one.  The vocabulary
;; is published contract: docs/writing.org, "How a refusal is classed".

(defconst org-records-mcp--refusal-conflict "conflict: "
  "Marker on a refusal saying the client's belief is stale.
The recovery is to read the file again and re-plan; sending the same
call again refuses it again.  Only `org-records-mcp--tool-conflict-error'
writes it.")

(defconst org-records-mcp--refusal-blocked "blocked: "
  "Marker on a refusal Org itself made, such as a vetoed TODO change.
The recovery is to tell the user why Org said no.  Only
`org-records-mcp--tool-blocked-error' writes it.")

(defun org-records-mcp--id-not-found-error (id)
  "Throw error for ID not found.
The refusal is unmarked, the validation class: an ID org-records-mcp cannot
resolve is as likely a heading that has gone, a conflict, as one a
client invented, and nothing here tells the two apart."
  (mcp-server-lib-tool-throw (format "Cannot find ID '%s'" id)))

(defun org-records-mcp--tool-validation-error (message &rest args)
  "Throw validation error MESSAGE with ARGS for tool operations.
Validation is the unmarked default class: the call itself was
malformed, and the recovery is to correct it and send it again."
  (mcp-server-lib-tool-throw (apply #'format message args)))

(defun org-records-mcp--tool-conflict-error (message &rest args)
  "Throw conflict refusal MESSAGE with ARGS, marked `conflict:'.
A conflict says the file is not as the client believed it to be, so
the recovery is to read it again and re-plan rather than to retry."
  (mcp-server-lib-tool-throw
   (concat
    org-records-mcp--refusal-conflict (apply #'format message args))))

(defun org-records-mcp--tool-blocked-error (message &rest args)
  "Throw Org-veto refusal MESSAGE with ARGS, marked `blocked:'.
Org refused the change itself, so neither reading again nor
correcting the call helps; the user decides what to do next."
  (mcp-server-lib-tool-throw
   (concat
    org-records-mcp--refusal-blocked (apply #'format message args))))

(defun org-records-mcp--state-mismatch-error (expected found context)
  "Throw a conflict refusal for a precondition that no longer holds.
EXPECTED is the expected value, FOUND is the actual value,
CONTEXT describes what is being compared."
  (org-records-mcp--tool-conflict-error
   "%s mismatch: expected '%s', found '%s'"
   context expected found))

(defun org-records-mcp--missing-param-error (name)
  "Throw the refusal a call that did not send parameter NAME gets.
A required parameter carrying a blank, see `org-records-mcp--blank-param-p',
is refused with this message too, so that the two spellings of one
mistake read alike: a client that fills a parameter it is not using
has sent nothing, whether it left the parameter out or wrote an
empty value into it."
  (org-records-mcp--tool-validation-error
   "Missing required parameter: %s"
   name))

(defun org-records-mcp--json-name (value)
  "Return the JSON spelling of VALUE, for a refusal to name it by.
VALUE is what `json-read-from-string' made of a client's JSON, and a
refusal that printed that back would hand the client the spelling of
its own value in another language: an object reads as an alist,
false as `:json-false', null as nil.  A string and a number are
printed as JSON writes them, and a composite is named by its kind,
since a refusal wants to say what arrived rather than repeat it."
  (cond
   ((null value)
    "null")
   ((eq value t)
    "true")
   ((eq value :json-false)
    "false")
   ((stringp value)
    (format "%S" value))
   ((numberp value)
    (format "%s" value))
   ((vectorp value)
    "an array")
   (t
    "an object")))

(defun org-records-mcp--text-param-given (value name)
  "Return VALUE, the text the required parameter NAME carries.
Any string is text, \"\" included: the parameters read this way carry
text, so \"\" is the text naming none, and a required parameter is
free to carry it.

Every other blank, see `org-records-mcp--blank-param-p', is a parameter the
call did not send and is refused as one.  Null in particular says
nothing: a client that fills an unused parameter with it would
otherwise be read as asserting that a field was empty, or as asking
for a body of no text, and either way go on to destroy what was
there.  Anything else is a malformed call.

What \"\" then says is the parameter\\='s own business and not this
one\\='s: it asserts that a field held nothing in a `before', it is a
body of no text on `org-node-set-content', and it is refused as no
value by the fields that have none, see `org-records-mcp--value-to-write'.
So the refusal here says only that text was wanted.

NAME is the parameter as the call spells it, so the refusal names
what the client sent rather than the field behind it."
  (cond
   ((stringp value)
    value)
   ((org-records-mcp--blank-param-p value)
    (org-records-mcp--missing-param-error name))
   (t
    (org-records-mcp--tool-validation-error
     "%s must be a string, not %s"
     name (org-records-mcp--json-name value)))))

(defun org-records-mcp--optional-text-given (value name)
  "Return the text the optional parameter NAME carries, or nil for none.
A string with something in it is text.  Every blank is the parameter
the call did not send — `org-records-mcp--blank-param-p' names them — and so
is a string of whitespace, because prose with nothing in it is
nothing to record.  Anything else is a malformed call and is refused
naming NAME.

This is the optional member of the family `org-records-mcp--text-param-given'
and `org-records-mcp--value-to-write' belong to, and it differs from both in
what a blank costs.  Those read a required parameter, where a blank
is the call failing to say something it had to say, so they refuse
it.  Here the parameter has a default — no text — so a blank asks
for that default and the call goes on without it.

Which matters more than it reads: an optional parameter is the one a
client fills with false or [] when it is not using it, and the text
it carries is written inside the change the rest of the call makes.
A blank refused here, or worse crashed on, would take that change
down with it."
  (cond
   ((org-string-nw-p value))
   ((stringp value)
    nil)
   ((org-records-mcp--blank-param-p value)
    nil)
   (t
    (org-records-mcp--tool-validation-error
     "%s must be a string, not %s"
     name (org-records-mcp--json-name value)))))

(defun org-records-mcp--null-text-p (value)
  "Return non-nil when VALUE is the text a client sends for JSON null.
The tool schema says a clearing `after' takes a string or null, see
`org-records-mcp--param-types', and a client that sends every argument
as a string sends the text null for null.  That text is exactly the four
lower-case letters JSON spells null in: padded or capitalised, it is
a string like any other.  Only an `after' that takes null to take a
value away asks this, see `org-records-mcp--value-to-write'; every other
parameter reads the text as the four letters it is."
  (equal value "null"))

(defun org-records-mcp--value-to-write (value name)
  "Return VALUE, the required parameter NAME naming what to write.
A string is the value to write.  JSON null is nil here, and asks for
the field to hold nothing: null is JSON\\='s word for no value, and
these fields have none of their own.  \"\" is not a timestamp, a
priority character or a TODO keyword, so it passes through as the
string it is and the field\\='s own validator refuses it, naming what
the field does accept and the null that asks for none.

The text null is nil too.  A client that sends every argument as a
string cannot send JSON null at all: it sends the text null instead,
and without this would be refused by a message naming the one value
it cannot produce.  `org-records-mcp--null-text-p' says what that text is.
It is no timestamp and no priority character, so it
takes away nothing a caller could have meant there.  A TODO keyword
is the one field a file may spell null, so `org-node-set-todo' reads
the text itself, once the file is known; see
`org-records-mcp--todo-null-text'.

Every other blank, see `org-records-mcp--blank-param-p', is a parameter the
client filled but did not send, and is refused as one: false is a
boolean and [] is an array, and neither is a way of saying nothing.

This is the value side of `org-records-mcp--text-param-given', which reads a
`before'.  The two differ on purpose.  A `before' names a state the
field was in, and its states are the values plus the empty one, which
\"\" names.  An `after' names a value to put in the field, and a
field with no empty value has no such value to name — so the two stop
being spelled alike exactly where the field stops having one."
  (cond
   ((or (null value) (org-records-mcp--null-text-p value))
    nil)
   ((stringp value)
    value)
   ((org-records-mcp--blank-param-p value)
    (org-records-mcp--missing-param-error name))
   (t
    (org-records-mcp--tool-validation-error
     "%s must be a string, or null to take the value away, not %s"
     name (org-records-mcp--json-name value)))))

(defun org-records-mcp--assert-before (before found context)
  "Refuse the call unless FOUND is the value BEFORE asserts.
FOUND is what the heading holds, in the form a read hands back, and
\"\" when the field has no value.  BEFORE is what the client believed
it held, read through `org-records-mcp--text-param-given'.  A digest is a
malformed call here, which `org-records-mcp--assert-field-value' refuses on
behalf of every field setter that asserts this way.  A value that
disagrees with FOUND is a conflict, which CONTEXT names the field
of."
  (org-records-mcp--assert-field-value before context)
  (let ((asserted
         (org-records-mcp--text-param-given before "before")))
    (unless (equal asserted found)
      (org-records-mcp--state-mismatch-error
       asserted found context))))

(defun org-records-mcp--saved-then-failed-error (what err)
  "Throw an error for a save that wrote the file and then failed.
WHAT names, as a clause, the change the file holds, so that a client
reading the message repeats neither the change nor the save.  ERR is
the error a function the save ran, such as one on `after-save-hook',
signalled."
  (org-records-mcp--tool-validation-error
   "%s, but a function run by the save failed: %s"
   what (error-message-string err)))

(defun org-records-mcp--tool-file-access-error
    (locator &optional hint)
  "Throw file access error for tool operations.
LOCATOR is the link or path the call sent, naming the file it may not
reach.  HINT, when non-nil, is a sentence appended to the message."
  (mcp-server-lib-tool-throw
   (concat
    (format "'%s': the referenced file not in allowed list" locator)
    (and hint (concat ".  " hint)))))

;; Helpers

(cl-defun org-records-mcp--file-buffer-context (file-path)
  "Return canonical buffer context for FILE-PATH.
The result is a plist with:

- `:buffer'     the canonical visited buffer
- `:existing-p' non-nil when the buffer was already visiting FILE-PATH
- `:modified-p' non-nil when that buffer was already modified before
                org-records-mcp touched it

If no buffer is visiting FILE-PATH yet, the buffer is opened with
`find-file-noselect'."
  (let* ((existing-buf (find-buffer-visiting file-path))
         (buf (or existing-buf (find-file-noselect file-path))))
    (list
     :buffer buf
     :existing-p (not (null existing-buf))
     :modified-p
     (with-current-buffer buf
       (buffer-modified-p)))))

(defun org-records-mcp--get-file-buffer (file-path)
  "Return the canonical visited buffer for FILE-PATH."
  (plist-get
   (org-records-mcp--file-buffer-context file-path)
   :buffer))

(defun org-records-mcp--read-file (file-path)
  "Read and return the current canonical contents of FILE-PATH."
  (with-current-buffer (org-records-mcp--get-file-buffer file-path)
    (save-restriction
      (widen)
      (buffer-string))))

(defun org-records-mcp--paths-equal-p (path1 path2)
  "Return t if PATH1 and PATH2 refer to the same file.
Handles symlinks and path variations by normalizing both paths."
  (string= (file-truename path1) (file-truename path2)))

(defun org-records-mcp-allowed-files ()
  "Return the effective allowed-files list (the function form).
Mirrors the Emacs idiom of `org-agenda-files': the same symbol
serves as a defcustom holding the user-configured list and as a
function returning the resolved list at call time.

When the variable `org-records-mcp-allowed-files' is non-nil, its entries
are returned verbatim (entries may be relative; expansion happens
in `org-records-mcp--expanded-allowed-files').  When nil, the result of
`(org-agenda-files t)' is returned, which uniformly handles list,
string-pointing-to-file, and directory forms of `org-agenda-files'
and yields fully absolute paths."
  (if org-records-mcp-allowed-files
      org-records-mcp-allowed-files
    (org-agenda-files t)))

(defvar org-records-mcp--file-set 'allowed
  "The files the running call works on.
The symbol `allowed' stands for the allowed files, where every call
works unless it names a set of files itself.  For a call that does,
`org-records-mcp--with-file-set' binds that set here as a list of files, and
`org-records-mcp--expanded-allowed-files' returns it in place of the allowed
files.  While `org-records-mcp--named-file-set', which that macro calls,
builds the set, it binds the allowed files here instead, computed
once.  Nothing else binds this variable, and both bind it with
`let', so the set ends with the call, even when the call fails, and
no later call sees it.")

(defun org-records-mcp--expanded-allowed-files ()
  "Return the allowed files, each made absolute.
While a call runs over a set of files it names, this returns that
set instead, from `org-records-mcp--file-set': the named set replaces the
allowed files for that call.

Pulls the source list from the function `org-records-mcp-allowed-files'
(which falls back to `org-agenda-files' when the variable
`org-records-mcp-allowed-files' is nil), then resolves relative entries
against `org-directory' exactly as `org-agenda-files' does.
Absolute entries pass through after tilde and environment variable
expansion.

The result holds files only.  A directory entry is dropped, so it
never makes the files under it reachable, neither through
`org-records-mcp--find-allowed-file' nor when the set is bound to
`org-agenda-files', where Org would expand it.  Directory entries of
`org-agenda-files' arrive here already expanded into their files by
the function `org-agenda-files'."
  (if (listp org-records-mcp--file-set)
      org-records-mcp--file-set
    (cl-remove-if
     #'file-directory-p
     (mapcar
      (lambda (f)
        (expand-file-name f org-directory))
      (org-records-mcp-allowed-files)))))

(defun org-records-mcp--local-file-name (name &optional dir)
  "Return NAME as an absolute local file name, or nil when it is remote.
NAME is expanded against DIR, or `default-directory' when DIR is
nil, with file name handlers disabled, so TRAMP takes no part.
Expansion collapses `.', `..', `~' and a relative name the way
every later file operation would, and `file-remote-p' checks the
result: `/tmp/../ssh:host:/x.org' is remote only once collapsed.

A `/:' quote on NAME is removed first.  Without handlers `/:' would
be an ordinary directory, while every later operation, handlers
enabled, removes it and reaches another file.  A name still quoted
after expansion is refused, as NAME is then no plain file name.
Callers use the returned name from here on, never NAME itself."
  (let ((expanded
         (let ((file-name-handler-alist nil))
           (expand-file-name (file-name-unquote name) dir))))
    (unless (or (file-name-quoted-p expanded t)
                (file-remote-p expanded))
      expanded)))

(defun org-records-mcp--local-truename (name &optional dir)
  "Return the truename of NAME, or nil when NAME or its target is remote.
NAME is made absolute by `org-records-mcp--local-file-name' against DIR.
Symlinks are then followed with file name handlers disabled, so a
local link whose target is a TRAMP name is never handed to TRAMP.
The resolved name is refused when it is remote, or quoted with
`/:', since a quoted link target is followed no further here but
would be once handlers are back."
  (when-let* ((local (org-records-mcp--local-file-name name dir))
              (truename
               (let ((file-name-handler-alist nil))
                 (file-truename local))))
    (unless (or (file-name-quoted-p truename t)
                (file-remote-p truename))
      truename)))

(defun org-records-mcp--override-roots ()
  "Return the roots of `org-records-mcp-file-scope-override', each made absolute.
Relative roots resolve against `org-directory'.  A remote root is
dropped before any file operation on it; it never permits anything.
Returns nil unless the setting is a list of directories."
  (when (consp org-records-mcp-file-scope-override)
    (delq
     nil
     (mapcar
      (lambda (root)
        (org-records-mcp--local-file-name root org-directory))
      org-records-mcp-file-scope-override))))

(defun org-records-mcp--org-file-name-p (name)
  "Return non-nil when NAME ends in `.org' or `.org_archive'.
These are the Org files a scope override reaches.  Case matters."
  (let ((case-fold-search nil))
    (string-match-p "\\.org\\(?:_archive\\)?\\'" name)))

(defun org-records-mcp--override-permits-p (name truename)
  "Return non-nil when `org-records-mcp-file-scope-override' permits TRUENAME.
TRUENAME is the local truename, from `org-records-mcp--local-truename', of
the file or directory a call names as NAME.  NAME must be absolute.
Under a list of roots TRUENAME must lie inside one of them, each
resolved the same way at every call; under t any TRUENAME is
permitted, and under nil none is."
  (and org-records-mcp-file-scope-override
       (file-name-absolute-p name)
       (or (eq org-records-mcp-file-scope-override t)
           (cl-some
            (lambda (root)
              (when-let* ((root-truename
                           (org-records-mcp--local-truename root)))
                (file-in-directory-p truename root-truename)))
            (org-records-mcp--override-roots)))))

(defun org-records-mcp--find-allowed-file (filename &optional named)
  "Return the absolute path of FILENAME when a call may reach it, else nil.
This is the one place that decides whether a path is reachable.

FILENAME is resolved by `org-records-mcp--local-truename' first, and refused
when it, or what it points to, is remote (TRAMP), before TRAMP can
open a connection for it.  A FILENAME in the allowed files is
reachable, and the expanded allowed-files entry is returned.

NAMED non-nil means the call names FILENAME, which makes it a scope
override when FILENAME lies outside the allowed files.  A call names
the file of a `file:' link, an entry of its `files', and the file
Emacs's ID index places the ID of an `id:' link in.
`org-records-mcp-file-scope-override' then decides: its truename must end
in `.org' or `.org_archive' and be an existing regular file, and
`org-records-mcp--override-permits-p' must permit it.  A permitted FILENAME
is returned as its truename.  Without NAMED, as for the file of the
running clock, only the allowed files are reachable."
  (when-let* ((truename (org-records-mcp--local-truename filename)))
    (if-let* ((found
               (cl-find
                truename
                (org-records-mcp--expanded-allowed-files)
                :test #'org-records-mcp--paths-equal-p)))
        (expand-file-name found)
      (when (and named
                 (org-records-mcp--org-file-name-p truename)
                 (org-records-mcp--override-permits-p
                  filename truename)
                 (file-regular-p truename))
        truename))))

(defun org-records-mcp--named-file-set (files)
  "Return the Org files FILES names, each one reachable by the call.
FILES is the `files' parameter of a call: an array of paths, or a
single path.  Every entry must be absolute, as `file-name-absolute-p'
reads it, so `~/' counts; a relative entry is refused rather than
resolved against `default-directory'.  An entry naming a file must
pass the gate, `org-records-mcp--find-allowed-file', as a file the call names.

An entry naming a directory is walked for Org files when
`org-records-mcp--override-permits-p' permits the directory's local
truename.  Otherwise, as under nil or outside every root, the
directory is not read at all: the entry stands for the allowed files
under it, and is refused when there are none.  A remote directory is
never read either, since it has no local truename.

The walk, `directory-files-recursively', descends into every
subdirectory except hidden ones, whose names start with `.', and
never follows a symlink to a directory, so it cannot loop or leave
the directory that way.  A subdirectory it cannot read is skipped; a
named directory it cannot search is an error.  So is a directory
that fails while the walk lists it, such as one removed meanwhile;
the error names it as the call reaches it.  In each directory it
takes the files Org takes from a directory in `org-agenda-files':
names matching `org-agenda-file-regexp', by default every `.org'
file and no archive, and of those the ones not hidden that
`org-records-mcp--org-file-name-p' accepts.  Of those it skips what is not a
regular file, such as a dangling symlink or a FIFO.  Every file it
takes must pass the gate; one that does not, such as a symlink out
of every root, fails the call with an error naming it as the call
reaches it, the entry followed by the path below it, never the file
the symlink resolves to.

The walk runs with file name handlers disabled: every name it builds
is local, and no handler should take part in reading it.

Each file is returned once, where FILES first reaches it.  Entries
come in order.  A walked directory's files come in the order
`directory-files-recursively' returns them: depth first, each
subdirectory's files before the files beside them, each directory's
names in alphabetical order.  A directory that is not walked gives
its allowed files in the order of the allowed files."
  (let ((entries
         (cond
          ((stringp files)
           (list files))
          ((sequencep files)
           (append files nil))))
        (found nil)
        ;; The allowed files, computed once for the whole set, and
        ;; never the set of an enclosing call.  The gate reads them
        ;; from here.
        (org-records-mcp--file-set
         (let ((org-records-mcp--file-set 'allowed))
           (org-records-mcp--expanded-allowed-files))))
    (unless (and entries (cl-every #'stringp entries))
      (org-records-mcp--tool-validation-error
       "files must be a non-empty array of paths"))
    ;; A relative entry would resolve against `default-directory',
    ;; which depends on whatever buffer is current in Emacs.
    (dolist (entry entries)
      (unless (file-name-absolute-p entry)
        (org-records-mcp--tool-validation-error
         "files entry names no file by its full path: %s.  Send a full \
path, such as /home/user/notes.org"
         entry)))
    (cl-flet
        ((add
          (file locator)
          ;; LOCATOR is FILE as the call reaches it, for the refusal.
          (let ((allowed
                 (or
                  (org-records-mcp--find-allowed-file file t)
                  (org-records-mcp--tool-file-access-error locator))))
            (unless (member allowed found)
              (push allowed found))))
         (below
          (entry truename path)
          ;; PATH as the call reaches it.  ENTRY names the directory
          ;; whose local truename is TRUENAME; a PATH under TRUENAME is
          ;; ENTRY followed by the path below it, any other PATH, such
          ;; as TRUENAME itself, is ENTRY.
          (if (and (stringp path)
                   (string-prefix-p
                    (file-name-as-directory truename) path))
              (concat
               (file-name-as-directory entry)
               (file-relative-name path truename))
            entry)))
      (dolist (entry entries)
        (let ((truename (org-records-mcp--local-truename entry)))
          (cond
           ((not (and truename (file-directory-p truename)))
            (add entry entry))
           ((org-records-mcp--override-permits-p entry truename)
            (let ((file-name-handler-alist nil))
              (unless (file-accessible-directory-p truename)
                (org-records-mcp--tool-validation-error
                 "Cannot read directory: %s"
                 entry))
              (dolist
                  (path
                   (condition-case err
                       (let ((case-fold-search nil))
                         (directory-files-recursively
                          truename
                          org-agenda-file-regexp
                          nil
                          (lambda (dir)
                            (and (not
                                  (string-prefix-p
                                   "." (file-name-nondirectory dir)))
                                 ;; With a function as PREDICATE,
                                 ;; rather than t, the walk signals
                                 ;; on a subdirectory it cannot read
                                 ;; instead of skipping it.
                                 (file-readable-p dir)))))
                     ;; A directory can still fail when it is listed:
                     ;; one removed after the predicate passed it, an
                     ;; I/O error, or a denial `file-readable-p' did
                     ;; not foresee.  The error data ends with the
                     ;; directory.  The whole call fails, so it never
                     ;; searches only part of the set.
                     (file-error
                      (org-records-mcp--tool-validation-error
                       "Cannot read directory: %s"
                       (below entry truename (car (last err)))))))
                (let ((name (file-name-nondirectory path)))
                  (when (and (not (string-prefix-p "." name))
                             (org-records-mcp--org-file-name-p name)
                             (file-regular-p path))
                    (add path (below entry truename path)))))))
           (t
            (let ((under
                   (cl-remove-if-not
                    (lambda (file)
                      (when-let* ((file-truename
                                   (org-records-mcp--local-truename
                                    file)))
                        (file-in-directory-p file-truename truename)))
                    org-records-mcp--file-set)))
              (unless under
                (org-records-mcp--tool-file-access-error entry))
              (dolist (file under)
                (add file entry))))))))
    (nreverse found)))

(defun org-records-mcp--refresh-file-buffers
    (file-path &optional except-buffer)
  "Refresh clean buffers visiting FILE-PATH except EXCEPT-BUFFER.
Preserves user edits by skipping already-modified buffers. Preserves
narrowing state across the refresh operation."
  (dolist (buf (buffer-list))
    (when (not (eq buf except-buffer))
      (with-current-buffer buf
        (when-let* ((buf-file (buffer-file-name)))
          (when (and (org-records-mcp--paths-equal-p
                      buf-file file-path)
                     (not (buffer-modified-p)))
            (let ((was-narrowed (buffer-narrowed-p))
                  (narrow-start nil)
                  (narrow-end nil))
              ;; Save narrowing markers if narrowed
              (when was-narrowed
                (setq narrow-start (point-min-marker))
                (setq narrow-end (point-max-marker)))
              (condition-case err
                  (save-mark-and-excursion
                    (unwind-protect
                        (progn
                          (revert-buffer t t t)
                          ;; Check if buffer was modified by hooks
                          (when (buffer-modified-p)
                            (org-records-mcp--tool-validation-error
                             "Buffer for file %s was modified during \
refresh.  Check your `after-revert-hook' for functions that modify \
the buffer"
                             file-path)))
                      ;; Restore narrowing even if revert fails
                      (when was-narrowed
                        (narrow-to-region narrow-start narrow-end))))
                (error
                 (org-records-mcp--tool-validation-error
                  "Failed to refresh buffer for file %s: %s. \
Check your Emacs hooks (`before-revert-hook', \
`after-revert-hook', `revert-buffer-function')"
                  file-path (error-message-string err)))))))))))

(defvar org-records-mcp--unsaved-change-p nil
  "Non-nil when the running tool call leaves a change unsaved.
A change stays unsaved when its buffer still differs from its file
after the save step.  That happens when the buffer already had
unsaved edits, because org-records-mcp never saves such a buffer, unless a
hook saved it during the call.  `org-records-mcp--modify-and-save' binds it
after saving the buffer it edits, and `org-records-mcp--complete-and-save'
reports it as the `saved' response field.  A tool that also edits
another buffer binds it around `org-records-mcp--modify-and-save' so the
response covers both edits.")

(defun org-records-mcp--link-of-change ()
  "Return the link to the heading at point, for a response to report.
No identifier is created for it.  When no link can be made, whatever
the error, the tool error says that the change itself was made, so a
client does not repeat it."
  (condition-case err
      (org-records-mcp--link-at-point)
    (error
     (org-records-mcp--tool-validation-error
      "The change was made%s, but no link to it could be made: %s"
      (if org-records-mcp--unsaved-change-p
          " and left unsaved"
        "")
      (if (eq (car err) 'mcp-server-lib-tool-error)
          (cadr err)
        (error-message-string err))))))

(defun org-records-mcp--complete-and-save (response-alist)
  "Return the JSON response for a change to the heading at point.
RESPONSE-ALIST is an alist of response fields.  The `link' field is
the heading's link from `org-records-mcp--link-of-change', unless
RESPONSE-ALIST already carries one: a verb that takes the whole node
away leaves no heading at point to link to and names the link the
node had instead, read while the node was still there.  The `saved'
field is false when `org-records-mcp--unsaved-change-p' is non-nil."
  (json-encode
   (append
    `((success . t)
      (saved
       .
       ,(if org-records-mcp--unsaved-change-p
            :json-false t)))
    (if (assq 'link response-alist)
        response-alist
      (append
       response-alist
       `((link . ,(org-records-mcp--link-of-change))))))))

(defun org-records-mcp--maybe-save-buffer
    (buf file-path preexisting-modified-p)
  "Save BUF when it was clean before org-records-mcp wrote to it.
FILE-PATH is refreshed in other visiting buffers only after an actual
save. If PREEXISTING-MODIFIED-P is non-nil, BUF is left dirty and
unsaved so pre-existing user edits are preserved."
  (unless preexisting-modified-p
    (with-current-buffer buf
      (when (buffer-modified-p)
        (save-buffer)))
    (org-records-mcp--refresh-file-buffers file-path buf)))

(defmacro org-records-mcp--with-org-file (file-path &rest body)
  "Execute BODY in the canonical Org buffer for FILE-PATH."
  (declare (indent 1) (debug (form body)))
  `(let ((buf (org-records-mcp--get-file-buffer ,file-path))
         (result nil))
     (with-current-buffer buf
       (save-restriction
         (widen)
         (setq result
               (save-mark-and-excursion
                 (save-match-data
                   (goto-char (point-min))
                   ,@body)))))
     result))

(defmacro org-records-mcp--with-allowed-agenda-files (&rest body)
  "Execute BODY with `org-agenda-files' bound to existing allowed files.
The binding is the subset of `org-records-mcp-allowed-files' that exists on
disk, with each entry expanded to an absolute path (relative entries
resolved against `org-directory').  This is the single ingress point
that maps the org-records-mcp security boundary onto Org's multi-file
convention, so tool handlers can rely on `org-agenda-files' instead
of re-implementing the filter.

BODY passes the variable to Org explicitly and never lets Org read
it through the function `org-agenda-files': while the agenda is
restricted, as by `org-agenda-set-restriction-lock', that function
returns the file of the restriction, not the binding."
  (declare (indent 0) (debug (body)))
  `(let ((org-agenda-files
          (cl-remove-if-not
           #'file-exists-p
           (org-records-mcp--expanded-allowed-files))))
     ,@body))

(defun org-records-mcp--blank-param-p (value)
  "Return non-nil when VALUE, a parameter of a call, is blank.
A blank parameter is one the call does not send.  Clients fill a
parameter they are not using with an empty value, so JSON null,
false, \"\" and [] all read that way: an optional parameter that is
blank takes its default and a required one is refused with
`org-records-mcp--missing-param-error'.

`{}' decodes to nil, which is what null decodes to, so nothing after
the decoder tells the two apart: `{}' means wherever it stands what
null means there.  It is blank here, as null is; in an `after' that
reads null as the ask to hold nothing it asks that, see
`org-records-mcp--value-to-write', and in a `before' map it asserts the line
is absent, see `org-records-mcp--assert-property'.

A required parameter never means \"not sent\", which leaves the
spellings that do mean something free to be read before this is
asked.  A `before' takes \"\" for the state of a field that held
nothing, see `org-records-mcp--text-param-given'.  An `after' takes null for
\"make this nothing\", see `org-records-mcp--value-to-write', and \"\" only
where the field has an empty value of its own — a body, a property
line, and the tag set, which spells its empty value [], see
`org-records-mcp--tag-set-given'.  A property map reads `false' as the text
`nil' Org stores, on either side of the call, see
`org-records-mcp--validate-properties'."
  (member value '(nil "" [] :json-false)))

(defun org-records-mcp--array-param (value what)
  "Return VALUE, a call's array parameter WHAT, as the array it names.
The tool schema publishes these parameters as arrays, see
`org-records-mcp--param-types', but a client that sends every argument as
a string cannot send a JSON array at all: it sends the array as its
own JSON text instead.  A VALUE
whose first non-blank character is a left bracket is read back here,
decoding as mcp-server-lib decodes an array that arrived as one, so
the call goes on as if it had.  Such text that is not a JSON array is
refused, naming WHAT.

A left bracket begins no other value any of these parameters takes: a
path is absolute, a field, property or computed name is an
identifier, and `org-tag-re' forbids a bracket in a tag.  Any other
VALUE is returned as it came, so a single tag, a single path,
\"all\", \"none\" and the name of a configured list each reach their
own check unchanged."
  (org-records-mcp--json-text-param value what "[" "array"))

(defun org-records-mcp--object-param (value what)
  "Return VALUE, a call's object parameter WHAT, as the object it names.
A client that sends every argument as a string cannot send a JSON
object either, whatever the tool schema says: it sends the object as
its own JSON text.  A VALUE whose
first non-blank character is a left brace is read back here, decoding
as mcp-server-lib decodes an object that arrived as one, so the call
goes on as if it had.  The text of an empty object decodes to nil, as
{} does, and means what {} means there.  Such text that is not a JSON
object is refused, naming WHAT.

A left brace begins no other value these parameters take, because
none of them takes a string at all: \"\" is blank, see
`org-records-mcp--blank-param-p', and every other string is refused by the
parameter's own check.  So the text form takes away nothing a caller
could have meant, and any other VALUE is returned as it came, to meet
that check unchanged."
  (org-records-mcp--json-text-param value what "{" "object"))

(defun org-records-mcp--json-text-param (value what opener kind)
  "Return VALUE, parameter WHAT, read back from JSON text if it is some.
VALUE is read back when it is a string whose first non-blank
character is OPENER, and returned as it came otherwise.  Text that
opens with OPENER and does not parse is refused, naming WHAT and
KIND, the JSON value OPENER begins.  `org-records-mcp--array-param' and
`org-records-mcp--object-param' say why each parameter may be read this way."
  (if (and (stringp value)
           (string-match-p
            (concat "\\`[[:space:]]*" (regexp-quote opener)) value))
      (condition-case nil
          (json-parse-string value
                             :array-type 'array
                             :object-type 'alist
                             :null-object nil
                             :false-object
                             :json-false)
        (json-error
         (org-records-mcp--tool-validation-error
          "%s begins with %s but is not a JSON %s: %s"
          what opener kind value)))
    value))

(defun org-records-mcp--boolean-param (value name)
  "Return VALUE, the call's boolean parameter NAME, as t or nil.
JSON true and \"true\" are true.  A blank VALUE, see
`org-records-mcp--blank-param-p', JSON false and null included, is false, and
so are \"false\" and :false, the keyword `json-parse-string' decodes
false to.  Any other VALUE is refused with an error naming NAME."
  (cond
   ((member value '(t "true"))
    t)
   ((or (org-records-mcp--blank-param-p value)
        (member value '(:false "false")))
    nil)
   (t
    (org-records-mcp--tool-validation-error
     "%s must be true or false: %s"
     name (org-records-mcp--json-name value)))))

(defun org-records-mcp--depth-given (depth)
  "Return DEPTH, a call's `depth' parameter, as a generation count.
A blank DEPTH, see `org-records-mcp--blank-param-p', is none: the call asks
for no expansion and the node's children come back as references.
A whole number is that many generations, and so is a string holding
one, which is how a client that sends every argument as a string
sends it.  Anything else is refused, since there is no such thing
as a fraction of a generation or a walk of minus one."
  (let ((count
         (cond
          ((org-records-mcp--blank-param-p depth)
           0)
          ((integerp depth)
           depth)
          ((and (stringp depth) (string-match-p "\\`[0-9]+\\'" depth))
           (string-to-number depth)))))
    (unless (and count (>= count 0))
      (org-records-mcp--tool-validation-error
       "depth must be a whole number of generations, not: %s"
       (org-records-mcp--json-name depth)))
    count))

(defun org-records-mcp--files-given (files)
  "Return FILES, a call's `files' parameter, or nil when it is blank.
See `org-records-mcp--blank-param-p'.  A FILES sent as the text of a JSON
array is read back as that array first, see `org-records-mcp--array-param'.
Every tool taking `files' reads it through here."
  (let ((files (org-records-mcp--array-param files "files")))
    (unless (org-records-mcp--blank-param-p files)
      files)))

(defun org-records-mcp--optional-link-given (link name)
  "Return LINK, an optional link parameter of a call, or nil when it is blank.
Clients may fill an optional parameter they do not use with an empty
value, so every blank, see `org-records-mcp--blank-param-p', and a string
holding nothing but whitespace mean that the call names no link.

NAME is the parameter as the call spells it.  A LINK that is not
blank and not a string is refused as
`org-records-mcp--text-param-given' refuses one, naming NAME and the JSON
kind of what arrived, so that no later message echoes the value in
the Elisp reader\\='s spelling of it.  A string is returned for
`org-records-mcp--link-target' to check.

The required counterpart is `org-records-mcp--link-given', which refuses a
blank instead of reading it as none: an optional parameter has a
meaning for a parameter that was not sent, and a required one has
none."
  (unless (or (org-records-mcp--blank-param-p link)
              (and (stringp link) (string-blank-p link)))
    (org-records-mcp--text-param-given link name)))

(defun org-records-mcp--link-given (link name)
  "Return LINK, the link the required parameter NAME carries.
A blank LINK is the parameter the call did not send and is refused as
one, naming NAME, the way every required text parameter is refused by
`org-records-mcp--text-param-given'.  A link is blank on the same terms an
optional one is, see `org-records-mcp--optional-link-given': every blank of
`org-records-mcp--blank-param-p' and a string holding nothing but whitespace.
A LINK that is not blank and not a string is refused as that function
refuses one, naming NAME and the JSON kind of what arrived.

Both are read here rather than left to `org-records-mcp--link-parse', which
has no parameter to name and would echo the value back in the Elisp
reader\\='s spelling of the client\\='s JSON — `nil', `t', a list of
dotted pairs.  A string is returned for that parser to check, which
is where a string that is no link is refused."
  (org-records-mcp--text-param-given
   (org-records-mcp--optional-link-given link name) name))

(defmacro org-records-mcp--closing-opened-buffers (files &rest body)
  "Run BODY, then kill the buffers it opened to visit FILES.
FILES, a list of files, is evaluated before BODY runs.  A buffer that
already visited one of them then is left open, and so is a buffer
BODY leaves modified.  Every other buffer visiting one of them is
killed once BODY returns or exits non-locally, so scanning files a
call names leaves the user's buffer list as it was."
  (declare (indent 1) (debug (form body)))
  (let ((unvisited (make-symbol "unvisited")))
    `(let ((,unvisited (cl-remove-if #'find-buffer-visiting ,files)))
       (unwind-protect
           (progn
             ,@body)
         (dolist (file ,unvisited)
           (when-let* ((buffer (find-buffer-visiting file)))
             (unless (buffer-modified-p buffer)
               (kill-buffer buffer))))))))

(defmacro org-records-mcp--with-file-set (files &rest body)
  "Run BODY over the files a call names in FILES, or the allowed files.
FILES is the call's `files' parameter.  Unless it is blank, see
`org-records-mcp--files-given', `org-records-mcp--named-file-set' checks and expands
it, and the resulting set replaces the allowed files for BODY through
`org-records-mcp--file-set'; the buffers BODY opens to visit that set are
killed afterwards by `org-records-mcp--closing-opened-buffers'.  When it is
blank, BODY runs over the allowed files and leaves the buffers it
opens for them, as the agenda does.  Either way BODY runs inside
`org-records-mcp--with-allowed-agenda-files', so `org-agenda-files' holds the
existing files it works on."
  (declare (indent 1) (debug (form body)))
  (macroexp-let2 nil files `(org-records-mcp--files-given ,files)
    `(let ((org-records-mcp--file-set
            (if ,files
                (org-records-mcp--named-file-set ,files)
              'allowed)))
       (org-records-mcp--closing-opened-buffers
           (and ,files org-records-mcp--file-set)
         (org-records-mcp--with-allowed-agenda-files
           ,@body)))))

(defmacro org-records-mcp--modify-and-save
    (file-path operation response-alist &rest body)
  "Execute BODY to modify Org file at FILE-PATH.
BODY runs in the canonical visited buffer for FILE-PATH and leaves
point in the entry of the heading it changed; the response's `link'
links to that heading.  If the buffer was already modified before
BODY runs, org-records-mcp leaves it dirty and unsaved.  Otherwise it saves
the buffer and refreshes other clean visiting buffers afterward.

BODY and the save form one change.  When either signals an error,
the buffer is put back as it was and the error propagates.  If a
hook saved a buffer that was clean partway through, org-records-mcp saves it
again, so the file is put back too.  If the save wrote the file and
then failed, as in `after-save-hook', the change is kept and the
error says it was made, so a client does not repeat it.

The response reports `saved' as false when the buffer still differs
from its file after the save, so a hook that saved the buffer while
BODY ran yields true.  RESPONSE-ALIST is evaluated after the save,
with point where BODY left it, so a link that cannot be made never
keeps the change from being saved.  OPERATION is retained for
call-site clarity and compatibility.  BODY can access FILE-PATH,
OPERATION, and RESPONSE-ALIST as variables."
  (declare (indent 3) (debug (form form form body)))
  (let ((position (make-symbol "position"))
        (group (make-symbol "group"))
        (done (make-symbol "done")))
    `(let* ((ctx (org-records-mcp--file-buffer-context ,file-path))
            (buf (plist-get ctx :buffer))
            (preexisting-modified-p (plist-get ctx :modified-p))
            (,position nil))
       (ignore ,operation)
       (unwind-protect
           (progn
             (with-current-buffer buf
               ;; `atomic-change-group' written out, with its bindings,
               ;; so that a save which wrote the file and then failed
               ;; keeps the change.  Cancelling the group undoes BODY's
               ;; edits, with undo turned off in BUF too, and undoing
               ;; the first edit of a clean buffer marks it unmodified
               ;; again unless its file was written during the call.
               (let ((,group (prepare-change-group))
                     (undo-outer-limit nil)
                     (undo-limit most-positive-fixnum)
                     (undo-strong-limit most-positive-fixnum)
                     (,done nil))
                 (unwind-protect
                     (progn
                       (activate-change-group ,group)
                       (save-restriction
                         (widen)
                         (save-mark-and-excursion
                           (save-match-data
                             (goto-char (point-min))
                             ,@body
                             (setq ,position (point-marker)))))
                       (unless preexisting-modified-p
                         (when (buffer-modified-p)
                           (condition-case err
                               (save-buffer)
                             (error
                              ;; An unmodified buffer means the file
                              ;; holds the change.
                              (unless (buffer-modified-p)
                                (setq ,done t)
                                (org-records-mcp--saved-then-failed-error
                                 "The change was made and saved" err))
                              (signal (car err) (cdr err))))))
                       (setq ,done t))
                   (if ,done
                       (accept-change-group ,group)
                     (cancel-change-group ,group)
                     ;; Still modified: a hook wrote the file during the
                     ;; call.  BUF holds no edits of the user's, so
                     ;; saving it puts the file back.  A second failure
                     ;; must not replace the first error.
                     (when (and (not preexisting-modified-p)
                                (buffer-modified-p))
                       (ignore-errors
                         (save-buffer)))))))
             ;; Outside the change group: the file is written by now,
             ;; and undoing the edit would part the buffer from it.
             (unless preexisting-modified-p
               (org-records-mcp--refresh-file-buffers ,file-path buf))
             (let ((org-records-mcp--unsaved-change-p
                    (or org-records-mcp--unsaved-change-p
                        (buffer-modified-p buf))))
               (with-current-buffer buf
                 (org-with-wide-buffer
                  (goto-char ,position)
                  (org-records-mcp--complete-and-save
                   ,response-alist)))))
         (when ,position
           (set-marker ,position nil))))))

(defun org-records-mcp--percent-decode (string)
  "Return STRING with its percent-encoding undone once.
The escapes are UTF-8 bytes, as `url-hexify-string' writes them, and
raw non-ASCII characters in STRING may sit between them.  Every escape
decodes to its byte, `%0A' and `%0D' included."
  (decode-coding-string
   (url-unhex-string (encode-coding-string string 'utf-8) t) 'utf-8))

(defun org-records-mcp--node-text-at-point ()
  "Return the text of the subtree at point, its heading included.
The text is the region `org-records-mcp--subtree-bounds' delimits, with one
trailing newline dropped: the region runs up to the next heading, and
a caller reading one subtree has no use for the line break that
separates it from that heading.

The trim belongs to this read and to nothing else.  A caller that
needs the region itself takes it from `org-records-mcp--subtree-bounds', not
from what this returns, so a presentation decision made here stays
here.  Point does not move."
  (let* ((bounds (org-records-mcp--subtree-bounds))
         (text
          (buffer-substring-no-properties (car bounds) (cdr bounds))))
    (if (string-suffix-p "\n" text)
        (substring text 0 -1)
      text)))

(defun org-records-mcp--link-at-point ()
  "Return the native Org link to the heading at point.
Every response field that carries a link takes it from here.
The link is the one a non-interactive `org-store-link' makes when it
may use existing identifiers only, in this order:

  heading with an :ID:        id:ID
  heading with a :CUSTOM_ID:  file:PATH::#CUSTOM_ID
  any other heading           file:PATH::*TITLE
  before the first heading    id:ID of a file-level :ID:, else
                              file:PATH::LINE, or file:PATH

PATH is the file name as `abbreviate-file-name' writes it.  The link
is returned as its text, without brackets or description.  Point may
be anywhere in the heading's entry and is not moved; the buffer is
read widened.  No identifier is created.

An `id:' link made before the first heading addresses the whole file;
see `org-records-mcp--target-heading-p'.  A `file:' link made there searches
for the text of its line.  org-records-mcp cannot resolve that one: its
resolver accepts only a search that ends on a heading.  No tool links
such a position: every write links the heading it changed, and every
read lists the headings Org's parser finds.

Throws a tool error when `org-store-link' changes the buffer, or makes
anything but an `id:' link or a `file:' link searching for the
heading's custom ID or title, or, before the first heading, an `id:'
or `file:' link.  Neither happens in stock Org; advice on
`org-store-link' can cause both."
  (org-with-wide-buffer
   (unless (org-before-first-heading-p)
     (org-back-to-heading t))
   (let*
       ((at-heading (not (org-before-first-heading-p)))
        (tick (buffer-chars-modified-tick))
        (stored
         ;; Each binding stops a user setting from changing the form
         ;; of the link or from creating an identifier.  They are made
         ;; with this buffer current, so they also override a
         ;; buffer-local value, such as the `org-id-link-to-org-use-id'
         ;; that Doom's org-roam module sets from `find-file-hook'.
         (let ( ;; Link by an existing :ID:, never create one.
               (org-id-link-to-org-use-id 'use-existing)
               ;; A heading without its own :ID: gets its own link,
               ;; not `id:PARENT::*Title' through an ancestor's :ID:.
               (org-id-link-consider-parent-id nil)
               ;; No `::' search after an `id:' link.
               (org-id-link-use-context nil)
               ;; A `file:' link names the heading, not the bare file.
               (org-link-context-for-files t)
               ;; An active region is no search string.
               (org-ignore-region t)
               ;; No package's search string replaces the heading's.
               (org-create-file-search-functions nil)
               ;; Only the `id:' link type stores links.  Another
               ;; store function that claims Org buffers would take
               ;; the link over (Org 9.8 keeps the last one that
               ;; matches) or, matching together with `id:', prompt
               ;; for a choice (Org 9.7).
               (org-link-parameters
                (mapcar
                 (lambda (entry)
                   (if (equal (car entry) "id")
                       entry
                     (cons
                      (car entry)
                      (org-plist-delete (cdr entry) :store))))
                 org-link-parameters))
               ;; `org-store-link' sets this global with `setq'; keep
               ;; the user's value, such as a pending capture's.
               (org-store-link-plist nil)
               ;; A prompt signals instead of waiting for input.
               (inhibit-interaction t))
           ;; Before anything else, Org links a <<target>> around
           ;; point, and at the start of a line that includes one
           ;; ending the previous line.
           (save-restriction
             (narrow-to-region (line-beginning-position) (point-max))
             (org-store-link nil nil))))
        (link
         ;; A non-interactive `org-store-link' returns a bracket link,
         ;; and Org has no function returning the bare one, so take
         ;; it apart with Org's own regexp and unescaping.
         (and stored
              (string-match org-link-bracket-re stored)
              (org-link-unescape
               (match-string-no-properties 1 stored)))))
     (unless (= tick (buffer-chars-modified-tick))
       (org-records-mcp--tool-validation-error
        "org-store-link changed %s while linking to it; org-records-mcp \
creates no identifiers, so advice on org-store-link must leave \
non-interactive calls alone"
        (buffer-name)))
     (unless (and link
                  (string-match-p
                   (if at-heading
                       "\\`\\(?:id:\\|file:.*::[*#]\\)"
                     "\\`\\(?:id:\\|file:\\)")
                   link))
       (org-records-mcp--tool-validation-error
        "org-store-link made %s, not an id: or file: link to the \
heading, in %s; advice on org-store-link changes the link"
        (or stored "no link") (buffer-name)))
     link)))

(defun org-records-mcp--tag-sets-at-point ()
  "Return the tags of the heading at point as (EFFECTIVE . OWN).

EFFECTIVE is `org-get-tags' called without its LOCAL argument, so the
list follows `org-use-tag-inheritance' and
`org-tags-exclude-from-inheritance' — including their list and regexp
forms — rather than a policy fixed here.  OWN is the part of that same
list written on the heading itself: Org marks every inherited entry
with the `inherited' text property, so one call yields both sets, and
there is no second scan and no second notion of what a tag is.

Both lists are plain strings; the text property is an artifact of how
Org reports inheritance, not something a caller should have to know."
  (let ((tags (org-get-tags)))
    (cons
     (mapcar #'substring-no-properties tags)
     (mapcar
      #'substring-no-properties
      (cl-remove-if
       (lambda (tag) (get-text-property 0 'inherited tag)) tags)))))

(defun org-records-mcp--title-at-point ()
  "Return the title of the heading at point, as Org reads it.
`org-get-heading' drops the TODO keyword, the priority cookie, the
tags and the COMMENT keyword, and Org's own
`org-link--normalize-string' then drops statistics cookies and
collapses runs of whitespace.  That is the normalization
`org-link-search' applies to a heading before matching a `::*title'
link against it, so every read, every write precondition and Org's
own link resolution agree on what a heading is called.

`ol.el' exports no public equivalent, and this private function is
load-bearing in seven places inside `ol.el' itself.  A test pins its
behaviour, so a change in Org fails the suite loudly instead of
drifting through every read; reimplementing the rule here with a
regexp would be the second definition this one exists to remove."
  (org-link--normalize-string (org-get-heading t t t t)))

(defun org-records-mcp--titles-equal-p (a b)
  "Return non-nil when A and B name the same heading to Org.
The comparison is the one `org-link-search' makes when it resolves a
`::*title' link: both titles are normalized as
`org-records-mcp--title-at-point' normalizes a heading, split into words and
compared letter case aside.  A write precondition therefore accepts
every title that reaches the heading through a link, rather than
refusing the call a link has just resolved."
  (cl-flet ((words
             (title)
             (mapcar
              #'upcase
              (split-string (org-link--normalize-string title)))))
    (equal (words a) (words b))))

(defun org-records-mcp--statistics-cookie (title)
  "Return the statistics cookie in TITLE, or nil when it has none.
Org's own parser decides what one is: a cookie is a
`statistics-cookie' object of a headline's title, so asking
`org-element-parse-secondary-string' for that one object type
applies the rule Org applies when it updates a cookie, rather than
adding a regexp that would be a second definition of it.  A title
carrying more than one answers with the first."
  (car
   (org-element-map
    (org-element-parse-secondary-string
     title '(statistics-cookie))
    'statistics-cookie
    (lambda (cookie) (org-element-property :value cookie)))))

(defun org-records-mcp--title-keeping-cookie (after)
  "Return the text a rename to AFTER writes on the heading at point.
A statistics cookie is no part of a title: `org-records-mcp--title-at-point'
normalizes it away, which is half of what makes one title serve
every caller.  So a client composing AFTER from what it read has no
cookie to send back, and writing AFTER verbatim would take the
heading's cookie away for good -- `org-update-statistics-cookies'
refreshes a cookie that is there and never adds one, so the parent's
progress display would not come back.  The heading is therefore read
as written, cookie and all, and the cookie is carried over.

It goes at the end of the title, wherever it stood before: AFTER is
new text, with no position in it to put the cookie back into.  An
AFTER naming a cookie of its own keeps that one, because the client
asked for it."
  (let ((cookie
         (org-records-mcp--statistics-cookie
          (org-get-heading t t t t))))
    (if (or (null cookie) (org-records-mcp--statistics-cookie after))
        after
      (concat after " " cookie))))

(defun org-records-mcp--heading-metadata-at-point ()
  "Return canonical heading metadata at point as a plist.

Reads the heading in one `org-element-at-point' call and one
`org-get-tags' call, so callers do not have to chain
`org-entry-get'/`org-get-tags'/`org-get-todo-state' themselves.

Returned plist keys:
  :title       string, with TODO/priority/tags/comment stripped
  :todo        string or nil
  :priority    one-character string or nil
  :tags        list of strings, the tags in effect on the heading
  :local-tags  list of strings, the tags written on the heading itself
  :level       integer
  :scheduled   Org timestamp string or nil
  :deadline    Org timestamp string or nil
  :closed      Org timestamp string or nil

The two tag lists come from `org-records-mcp--tag-sets-at-point', so every
caller reports the same tags for the same heading under the same
configuration.

Two fields are read from the parsed heading because `org-entry-get'
cannot say what they hold.  It answers with the default priority for
a heading that carries no cookie, so it could never report the field
as empty; and it stops a planning timestamp at the first `>', so a
date range comes back as its first half.  The `:raw-value' of the
parsed timestamp is the whole Org string, in canonical Org
abbreviation and with no locale-dependent reformatting."
  (let* ((el (org-element-at-point))
         (priority-char (org-element-property :priority el))
         (tag-sets (org-records-mcp--tag-sets-at-point))
         (sched (org-element-property :scheduled el))
         (deadl (org-element-property :deadline el))
         (clsd (org-element-property :closed el)))
    (list
     :title (org-records-mcp--title-at-point)
     :todo (org-element-property :todo-keyword el)
     :priority (and priority-char (char-to-string priority-char))
     :tags (car tag-sets)
     :local-tags (cdr tag-sets)
     :level (org-element-property :level el)
     :scheduled (and sched (org-element-property :raw-value sched))
     :deadline (and deadl (org-element-property :raw-value deadl))
     :closed (and clsd (org-element-property :raw-value clsd)))))

(defun org-records-mcp--asserted-value (field)
  "Return FIELD of the heading at point as a `before' asserts it.
FIELD is a key of `org-records-mcp--heading-metadata-at-point', and the
value is that plist's, with \"\" for a field the heading does not
carry — the string a `before' asserts absence with, see
`org-records-mcp--assert-before'.

This is the one accessor per field that the read surface and the
assertion path share, and it is the metadata the read surface is
built from, so a value compared against a `before' is the value the
client was handed.  Two accessors let the guard refuse a true belief
for good and admit a stale one on the same field: `org-entry-get'
stops a SCHEDULED at the first `>', so a date range read whole could
never be asserted, and reports a property whose text is `nil' as no
property at all, so \"\" destroyed a value it never named.

A field gains an assertion by appearing here, which is why the
plist and not a per-field reader is what a field record names."
  (or (plist-get (org-records-mcp--heading-metadata-at-point) field)
      ""))

(defun org-records-mcp--subtree-bounds ()
  "Return the subtree of the heading at point as (BEGIN . END).
BEGIN is the heading's first star and END is where the next heading
of the same level or a shallower one begins, or the end of the
buffer.  That is the region Org's own parser gives the headline, so
every descendant lies inside it whatever depth a caller asked to see.

This is the one definition of a subtree's extent: a caller reading
the text verbatim and a caller measuring the region resolve to the
same bytes rather than to two walks that agree by coincidence.  Point
does not move."
  (save-excursion
    (org-back-to-heading t)
    (let ((el (org-element-at-point)))
      (cons
       (org-element-property :begin el)
       (org-element-property :end el)))))

(defun org-records-mcp--body-bounds ()
  "Return the body of the heading at point as (BEGIN . END).
The body begins where `org-end-of-meta-data' with FULL leaves point,
past planning lines, drawers and blank lines.  It ends at the first
child, which `org-goto-first-child' finds, or, when there is none,
after the last non-blank character of the subtree, where
`org-end-of-subtree' leaves point.  An empty body ends where it
begins, at the start of the next heading's line or at the end of the
buffer.  A line starting with `*' is part of the body unless Org
reads it as a heading.

Both ends are found from the heading itself.  Past an empty body lies
the next heading, a child or a sibling, and `org-goto-first-child'
called there would find that heading's first child instead.  Point
does not move."
  (save-excursion
    (org-back-to-heading t)
    (let ((end
           (save-excursion
             (if (org-goto-first-child)
                 (point)
               (org-end-of-subtree t)))))
      (org-end-of-meta-data t)
      (cons (point) (max (point) end)))))

(defun org-records-mcp--insert-body-text (text)
  "Insert TEXT at point, the end of a heading's body, on lines of its own.
A line break goes before TEXT unless point starts a line, and after
it unless TEXT ends in one or a line break follows point."
  (unless (bolp)
    (insert "\n"))
  (insert text)
  (unless (or (bolp) (eq (char-after) ?\n))
    (insert "\n")))

(defconst org-records-mcp--special-properties
  '("TODO"
    "TAGS"
    "ALLTAGS"
    "PRIORITY"
    "SCHEDULED"
    "DEADLINE"
    "CLOSED"
    "CATEGORY"
    "ITEM"
    "FILE"
    "BLOCKED"
    "CLOCKSUM"
    "CLOCKSUM_T"
    "TIMESTAMP"
    "TIMESTAMP_IA")
  "Org special properties that cannot be set via `org-node-set-properties'.")


;; Nodes

(defconst org-records-mcp--node-fields
  '(title
    todo
    priority
    tags
    local_tags
    scheduled
    deadline
    closed
    file
    id
    level
    link
    breadcrumbs
    blocked
    log
    content
    content_digest
    digest
    children)
  "Every field a node can carry.
`org-records-mcp--node-at-point' builds each of these and nothing else, and
a field a call asks for is checked against this list before any
file is opened.  The tool descriptions and docs/reading.org
describe the same names to a client, so a field added here is added
to the builder, to that page and to the node description in the
same change.

A node's Org drawer is not among them.  A drawer holds names the
user chose, `TITLE' as readily as `Effort', so putting them in this
namespace would let one collide with a field; the `properties'
parameter names them instead, and they arrive under their own key.")

(defconst org-records-mcp--node-child-fields '(title todo level link)
  "The fields a child node carries.
A child is a node like any other, asked for with few fields: its
title and TODO state show the outline, and its link addresses it in
the call that reads it in full.")

(defconst org-records-mcp--node-read-fields
  '(title
    todo
    priority
    tags
    local_tags
    scheduled
    deadline
    closed
    file
    id
    level
    link
    breadcrumbs
    blocked
    log
    content
    children)
  "The fields the org-node-read tool and the org://{link} resource carry.
Every field but the two digests: a read is the whole node, and a
digest is for a call about to change something.  A match list
carries `org-records-mcp-list-fields' instead.")

(defun org-records-mcp--node-field (name)
  "Return the node field NAME names, or refuse NAME as not one.
NAME is a string, the way a call's `fields' parameter sends it, or
a symbol, the way `org-records-mcp-node-field-lists' holds it.  The match is
by name and never by `intern', so nothing a call sends becomes a
symbol, and the refusal names every field there is to ask for."
  (let ((text (format "%s" name)))
    (or (cl-find
         text
         org-records-mcp--node-fields
         :key #'symbol-name
         :test #'string=)
        (org-records-mcp--tool-validation-error
         "Unknown node field: %s.  Valid fields: %s"
         text
         (mapconcat #'symbol-name org-records-mcp--node-fields
                    ", ")))))

(defun org-records-mcp--named-node-fields (name)
  "Return the fields the list called NAME holds, or refuse NAME.
The lists are `org-records-mcp-node-field-lists', which the user owns, so
the refusal names the lists that are configured rather than a set
this server decided on, and says how to ask for fields without
naming a list at all."
  (or (cdr
       (cl-find
        name
        org-records-mcp-node-field-lists
        :key (lambda (entry) (format "%s" (car entry)))
        :test #'string=))
      (org-records-mcp--tool-validation-error
       "Unknown field list: %s.  Configured lists: %s.  \
Fields are also named directly, as an array such as \
[\"title\", \"link\"]"
       name
       (if org-records-mcp-node-field-lists
           (mapconcat (lambda (entry) (format "%s" (car entry)))
                      org-records-mcp-node-field-lists
                      ", ")
         "none"))))

(defun org-records-mcp--node-field-names (fields)
  "Return the field names a call's FIELDS parameter asks for.
FIELDS is an array of names, which is the list of names itself, or
a string naming a list in `org-records-mcp-node-field-lists'.  The names
themselves are not checked here; `org-records-mcp--node-field' checks each
one, so a name from a configured list is checked as a name a call
spelled out is."
  (cond
   ((stringp fields)
    (org-records-mcp--named-node-fields fields))
   ((or (vectorp fields) (consp fields))
    (append fields nil))
   (t
    (org-records-mcp--tool-validation-error
     "fields takes an array of field names, or the name of a \
configured list as a string, not: %s"
     (org-records-mcp--json-name fields)))))

(defun org-records-mcp--refuse-setting-name
    (setting name what parameter)
  "Refuse NAME, which SETTING holds and which is no WHAT.
SETTING is the variable a call's default came from, and PARAMETER
the call parameter that overrides it.  The refusal names the
setting rather than the call, which sent nothing, so a client
learns the fault is the configuration's and how to go around it."
  (org-records-mcp--tool-validation-error
   "%s names %s, which is no %s; send %s to override"
   setting name what parameter))

(defun org-records-mcp--node-fields-given
    (fields default &optional setting)
  "Return the node fields a call asking for FIELDS wants.
FIELDS is the `fields' parameter of a call, see
`org-records-mcp--node-field-names'.  A blank FIELDS, see
`org-records-mcp--blank-param-p', means the call asks for nothing in
particular and takes DEFAULT, the fields that endpoint carries when
it is not asked.

Every name is resolved here, at the parameter, rather than in
`org-records-mcp--node-at-point': a node is then built from fields that are
known to exist, and a call that misspells one is refused before a
file is opened.  DEFAULT is resolved the same way.  SETTING, when
non-nil, is the variable DEFAULT is the value of, and a name in it
that is no field is refused naming SETTING, see
`org-records-mcp--refuse-setting-name'.  A field named twice is
dropped to once, since it would otherwise be a key sent twice.

A FIELDS sent as the text of a JSON array is read back as that array
first, see `org-records-mcp--array-param'."
  (let ((fields (org-records-mcp--array-param fields "fields")))
    (delete-dups
     (if (org-records-mcp--blank-param-p fields)
         (mapcar
          (lambda (name)
            (if (and setting
                     (not
                      (cl-find
                       (format "%s" name)
                       org-records-mcp--node-fields
                       :key #'symbol-name
                       :test #'string=)))
                (org-records-mcp--refuse-setting-name
                 setting name "node field" "fields")
              (org-records-mcp--node-field name)))
          default)
       (mapcar
        #'org-records-mcp--node-field
        (org-records-mcp--node-field-names fields))))))

(defun org-records-mcp--group-given (value default what)
  "Return what a call's WHAT parameter, VALUE, asks for.
VALUE is an array of names, or a string naming a group: \"all\" is
every member there is and \"none\" is no member at all.  A blank
VALUE, see `org-records-mcp--blank-param-p', means the call does not send
the parameter and takes DEFAULT, what that endpoint carries unasked.

The answer is the symbol `all', nil for none, or the list of names
the call wrote.  Which names are valid is the parameter's business
rather than this grammar's, so the caller checks them; WHAT names the
parameter in the refusal raised here.

A VALUE sent as the text of a JSON array is read back as that array
first, see `org-records-mcp--array-param'."
  (let ((value (org-records-mcp--array-param value what)))
    (cond
     ((org-records-mcp--blank-param-p value)
      default)
     ((equal value "all")
      'all)
     ((equal value "none")
      nil)
     ((or (vectorp value) (consp value))
      (append value nil))
     (t
      (org-records-mcp--tool-validation-error
       "%s takes an array of names, or \"all\" or \"none\" as a \
string, not: %s"
       what (org-records-mcp--json-name value))))))

(defun org-records-mcp--assert-not-accumulating (name)
  "Refuse NAME when it is a drawer line adding to a property, not one.
Org joins a `NAME+' line into what the plain name holds, so no read
reports the `+' spelling and no `before' can assert it.  A write
under it would change the plain property behind an assertion that
never named it, which is the one thing every write here is guarded
against."
  (when (string-suffix-p "+" name)
    (org-records-mcp--tool-validation-error
     "Not a property name: %s.  A trailing `+' makes a drawer line \
add to the property named without it, so it names none of its own"
     name)))

(defun org-records-mcp--drawer-property (name)
  "Return NAME as a drawer property name, or refuse it as not one.
Org holds a property name upcased and matches it that way, so a call
naming `effort' asks for the property a drawer writes as `Effort'
and reads it back under the name Org keeps.

A special property is refused rather than answered empty: Org
computes those rather than storing them, so no drawer holds one, and
what each says a node says as a field of its own.  A `NAME+' line is
refused the same way, by `org-records-mcp--assert-not-accumulating': it adds
to what NAME holds rather than being a property, and NAME is the
name a read answers under."
  (unless (stringp name)
    (org-records-mcp--tool-validation-error
     "A property name is a string, not: %s"
     (org-records-mcp--json-name name)))
  (unless (with-syntax-table org-mode-syntax-table
            (org--valid-property-p name))
    (org-records-mcp--tool-validation-error
     "Invalid property name: '%s'"
     name))
  (org-records-mcp--assert-not-accumulating name)
  (let ((upper (upcase name)))
    (when (member upper org-records-mcp--special-properties)
      (org-records-mcp--tool-validation-error
       "Not a drawer property: %s.  Org computes it rather than \
storing it; the node's own fields carry what it says.  Special \
properties: %s"
       name
       (mapconcat #'identity org-records-mcp--special-properties
                  ", ")))
    upper))

(defun org-records-mcp--node-properties-given (properties default)
  "Return the drawer properties a call asking for PROPERTIES wants.
PROPERTIES is the `properties' parameter of a call: an array of
property names, or one of the group names `org-records-mcp--group-given'
takes, or blank for DEFAULT, the drawer that endpoint carries
unasked.

Every name is resolved here, at the parameter, as a field name is,
so a call that names something no drawer can hold is refused before
a file is opened."
  (let ((asked
         (org-records-mcp--group-given
          properties default "properties")))
    (if (eq asked 'all)
        'all
      (mapcar #'org-records-mcp--drawer-property asked))))

(defun org-records-mcp--computed-field (name)
  "Return the computed field NAME names, or refuse NAME as not one.
NAME is a string, the way a call's `computed' parameter sends it.
The fields are `org-records-mcp-computed-fields', which the user owns, so
the refusal names what is configured rather than a set this server
decided on.  The match is by name and never by `intern', so nothing
a call sends becomes a symbol."
  (let ((text (format "%s" name)))
    (or (car
         (cl-find
          text
          org-records-mcp-computed-fields
          :key (lambda (entry) (format "%s" (car entry)))
          :test #'string=))
        (org-records-mcp--tool-validation-error
         "Unknown computed field: %s.  Configured computed fields: %s"
         text
         (if org-records-mcp-computed-fields
             (mapconcat (lambda (entry) (format "%s" (car entry)))
                        org-records-mcp-computed-fields
                        ", ")
           "none")))))

(defun org-records-mcp--node-computed-given
    (computed default &optional setting)
  "Return the computed fields a call asking for COMPUTED wants.
COMPUTED is the `computed' parameter of a call: an array of names,
or one of the group names `org-records-mcp--group-given' takes, or blank for
DEFAULT, what that endpoint carries unasked.

Every name is resolved here, at the parameter, as a field name is,
so a call naming a field nobody configured is refused before a file
is opened.  SETTING, when non-nil, is the variable DEFAULT is the
value of, and a name in it nobody configured is refused naming
SETTING, see `org-records-mcp--refuse-setting-name'."
  (when (and setting
             (listp default)
             (org-records-mcp--blank-param-p
              (org-records-mcp--array-param computed "computed")))
    (dolist (name default)
      (unless (cl-find
               (format "%s" name)
               org-records-mcp-computed-fields
               :key (lambda (entry) (format "%s" (car entry)))
               :test #'string=)
        (org-records-mcp--refuse-setting-name
         setting name "configured computed field" "computed"))))
  (let ((asked
         (org-records-mcp--group-given computed default "computed")))
    (if (eq asked 'all)
        'all
      (mapcar #'org-records-mcp--computed-field asked))))

(defun org-records-mcp--file-title ()
  "Return the title of the file the current buffer visits.
It is the `#+TITLE:' keyword, which `org-get-title' reads, and the
file's own name when the file sets none, so every node has a title."
  (or (org-get-title) (file-name-nondirectory (buffer-file-name))))

(defun org-records-mcp--file-link ()
  "Return the native Org link to the file the current buffer visits.
It is the `id:' link of the file's own property drawer when the file
has one -- the ID org-roam gives a file node, which `org-id-open'
resolves to the top of the file -- and `file:PATH' otherwise, with
PATH written as `abbreviate-file-name' writes it, as every heading
link in a response is written.  Either form names the whole file when
a later call sends it back, see `org-records-mcp--target-heading-p'.

The ID comes from Org's own parse of the file-level drawer rather
than from `org-entry-get', which reads the first heading's drawer
instead when the file opens on a heading.  No identifier is created."
  (let ((id
         (org-with-wide-buffer
          (goto-char (point-min))
          (org-element-property :ID (org-element-org-data-parser)))))
    (if (org-string-nw-p id)
        (concat "id:" id)
      (concat "file:" (abbreviate-file-name (buffer-file-name))))))

(defun org-records-mcp--node-child-positions (file-node)
  "Return the buffer positions of the children of the node at point.
FILE-NODE non-nil means the node is the file the buffer visits, and
its children are the level-1 headings Org's parser finds.  A sibling
walk started at the first heading would follow that heading's own
level instead, and miss the level-1 headings of a file that opens at
a deeper one.

Otherwise the children are the headings one level below the heading
at point, which `org-goto-first-child' and `org-get-next-sibling'
walk.  Point does not move."
  (save-excursion
    (if file-node
        (org-element-map
         (org-element-parse-buffer 'headline) 'headline
         (lambda (h)
           (when (= (org-element-property :level h) 1)
             (org-element-property :begin h)))
         nil nil 'headline)
      (let ((child-level (1+ (org-current-level)))
            (positions '()))
        (org-back-to-heading t)
        (when (org-goto-first-child)
          (cl-loop
           do
           (when (= (org-current-level) child-level)
             (push (point) positions))
           while (org-get-next-sibling)))
        (nreverse positions)))))

(defun org-records-mcp--node-content-bounds (file-node children)
  "Return the body of the node at point as (BEGIN . END).
FILE-NODE non-nil means the node is the file, whose body is its
preamble: everything before CHILDREN, the positions
`org-records-mcp--node-child-positions' returned, or the whole file when it
holds no heading.  Otherwise the body is the region
`org-records-mcp--body-bounds' delimits, the one org-node-set-content writes
within, so what a client reads and what a write replaces are the same
region."
  (if file-node
      (cons (point-min) (or (car children) (point-max)))
    (org-records-mcp--body-bounds)))

(defun org-records-mcp--node-subtree-bounds (file-node)
  "Return the subtree of the node at point as (BEGIN . END).
FILE-NODE non-nil means the node is the file the buffer visits, and
its subtree is the whole of it.  Otherwise it is the region
`org-records-mcp--subtree-bounds' delimits: the heading, its body and every
descendant under it, whatever depth the call asked to see."
  (if file-node
      (cons (point-min) (point-max))
    (org-records-mcp--subtree-bounds)))

(defconst org-records-mcp--digest-prefix "sha256:"
  "The whole of a digest token's prefix, naming the algorithm behind it.
`org-records-mcp--digest' writes it, so the form org-records-mcp hands a client and
the form org-records-mcp takes back are one string and cannot drift apart.")

(defun org-records-mcp--digest (bounds)
  "Return the digest of the buffer region BOUNDS covers.
BOUNDS is (BEGIN . END) in the current buffer.  The token is
`sha256:' followed by the first 16 hexadecimal characters of the
SHA-256 of the region's text as UTF-8 bytes.

The token is opaque to the client that receives it: it says which
version of a region the client read, and a client asserts by sending
back the one it was given rather than by computing one.  The prefix
names the algorithm, so a token made by a later one is told apart
from this one without a second field to carry the answer.

The region is what is digested, never a tool's rendering of it: a
read that trims or formats what it returns is making a decision for
its reader, and a decision made for a reader is not a safety
boundary.  Every region has a digest, an empty one included, so a
node asked for a digest always carries one."
  (concat
   org-records-mcp--digest-prefix
   (substring (secure-hash
               'sha256
               (encode-coding-string (buffer-substring-no-properties
                                      (car bounds) (cdr bounds))
                                     'utf-8
                                     t))
              0 16)))

(defun org-records-mcp--digest-form-p (before)
  "Return non-nil when BEFORE carries a digest rather than a value.
`before' says what the client believed was there in one of two
forms — the value itself, or a token over the region that held it —
and `org-records-mcp--digest-prefix' is what tells the two apart.  The
algorithm rides in front of the token rather than in a parameter of
its own because a value can look like a token: a body of sixteen
hexadecimal characters is a body a client may assert."
  (and (stringp before)
       (string-prefix-p org-records-mcp--digest-prefix before)))

(defun org-records-mcp--digest-given (before)
  "Return BEFORE, the subtree digest a whole-node verb asserts with.
A verb that takes a node away takes every descendant with it, so the
call says which subtree it means by echoing the `digest' field of the
read it planned from, the prefix included: an echo is a copy, never a
token rebuilt from the parts of one.

A value in no such form matches no subtree at all.  Calling that a
malformed call sends the client back to a read for a token; calling
it a conflict would send it back to read the same file and assert
with the same value again.  A blank, see `org-records-mcp--blank-param-p',
is the parameter left out: a subtree has no empty spelling, so there
is nothing for one to name."
  (when (org-records-mcp--blank-param-p before)
    (org-records-mcp--missing-param-error "before"))
  (unless (org-records-mcp--digest-form-p before)
    (org-records-mcp--tool-validation-error
     "before must be the digest a read of this node returned, starting `%s': %s"
     org-records-mcp--digest-prefix
     (org-records-mcp--json-name before)))
  before)

(defun org-records-mcp--assert-field-value (before context)
  "Refuse the call when BEFORE is a digest where a field's value belongs.
A digest is a token over a region of the file, and a setter that
changes one field is not defined over a region: a token over the
body would refuse a priority change because a clock line moved, and
a token over the subtree would refuse it because a descendant was
edited.  That over-sensitivity is what the field-scoped assertion
exists to avoid, so the two forms of `before' are not
interchangeable.  CONTEXT names the field, so a refusal says which
assertion arrived in the wrong form.

The refusal is unmarked, the validation class: no version of the
file makes a token over a region the value of one field, so reading
the node again and sending the same token back refuses the call
again.  What has to change is the call."
  (when (org-records-mcp--digest-form-p before)
    (org-records-mcp--tool-validation-error
     "%s is asserted with the value it holds, not with a digest: '%s' covers a region and this call changes one field"
     context before)))

(defun org-records-mcp--assert-subtree (digest undone)
  "Refuse unless DIGEST is the digest of the subtree of the heading at point.
DIGEST is the token the call sent, compared as a string against the
one the subtree carries now.  UNDONE names, as a clause, what the
refusal did not do: the three verbs that assert this way cost their
caller sharply different things to get wrong, so each says which of
them did not happen.

The token covers the whole subtree, so an edit to a descendant the
client never read refuses the call.  That is the point of it: what
these verbs take away is the subtree entire, and a guard asserts
what it is about to destroy.

The refusal names the digest the call sent and not the one the
subtree carries now.  The current one is the only value that would
make the same call succeed, so handing it back would make resending
it the cheapest recovery there is — and a call that asserts a digest
the caller never read asserts nothing.  What the caller is owed is
that the node has moved on from the read they planned from, which is
what the message says; the recovery is to read it again."
  (unless (string=
           digest
           (org-records-mcp--digest
            (org-records-mcp--subtree-bounds)))
    (org-records-mcp--tool-conflict-error
     "Subtree mismatch: expected '%s'; the subtree has changed since that read, so read the node again for a current digest; %s"
     digest undone)))

(defun org-records-mcp--assert-clock-outside-subtree ()
  "Refuse unless Emacs's running clock is outside the subtree at point.
The clock is inside it when `org-clock-marker' points into the region
`org-records-mcp--subtree-bounds' gives the heading, in this buffer, which is
how Org itself asks the question.

org-node-delete is the one verb that asks: it takes the open CLOCK
line away with the text and never puts it down again, so the marker
`org-cut-subtree' saved for a paste collapses.  Emacs goes on
reporting a running clock with no line left to close, and the user's
next `org-clock-out' fails with `Clock start time is gone'.
org-node-refile puts the line down with the subtree and the marker
follows it, and org-archive-subtree reinstates the marker in the
archive copy itself, so neither strands the clock.

The refusal is the unmarked validation class and not a conflict: the
open CLOCK line was inside the region the client read, so the
subtree's digest is fresh, and there is nothing to read again that
would resolve this.  What resolves it is a clock-out, which the
message names.  org-records-mcp does not run one on the user's behalf: a tool
that stops the user's clock without being asked is worse than one
that declines."
  (when (and (eq (org-clocking-buffer) (current-buffer))
             (let ((bounds (org-records-mcp--subtree-bounds))
                   (clock (marker-position org-clock-marker)))
               (and (<= (car bounds) clock) (< clock (cdr bounds)))))
    (org-records-mcp--tool-validation-error
     "The clock is running in this node: close it with org-clock-out first; nothing was deleted")))

(defun org-records-mcp--file-drawer-region-p ()
  "Return non-nil when the buffer has a region for the file's own drawer.
A file's property drawer is the one Org reads at the top of the
buffer: before the first heading, and above the in-buffer settings,
since a drawer under a #+ keyword line is read as no drawer at all.

A file whose first line is a heading has no region there.  Every Org
property accessor starts from `org-back-to-heading-or-point-min',
which lands on that heading, so the drawer Org reads at `point-min'
is the heading's own: reading it would report another node's
properties as the file's, and `org-entry-delete' would take a line
out of it.  `org-records-mcp--file-link' keeps the two apart the same way,
by asking Org's parser for the file's ID rather than `org-entry-get'.

Point does not move."
  (save-excursion
    (goto-char (point-min))
    (org-before-first-heading-p)))

(defun org-records-mcp--drawer-at-point ()
  "Return the Org property drawer of the node at point as an alist.
Names are upcased, as `org-entry-properties' returns them, and a
value is the drawer's own text: a property written `:FOO: nil' holds
the string \"nil\" and is a property the node has, not an absent one.

`org-records-mcp--special-properties' are left out: Org computes them rather
than storing them, and each is a node field in its own right.

This is the one accessor per property that the read surface and the
assertion path share, the counterpart of `org-records-mcp--asserted-value'
for the drawer.  `org-entry-get' is the other reader Org offers and
it answers differently on the two drawers a guard most needs to be
right about — it reports `:FOO: nil' as no property, which made \"\"
an accepted assertion that then destroyed the value, and it reports
the last of two lines writing one name where a scan reports the
first."
  (cl-remove-if
   (lambda (pair)
     (member (car pair) org-records-mcp--special-properties))
   (org-entry-properties nil 'standard)))

(defun org-records-mcp--doubled-drawer-names ()
  "Return the names the drawer at point writes on more than one line.
`org-get-property-block' says where the drawer is and
`org-property-re' what a property line is, so the lines counted here
are the lines Org counts.

A `NAME+' line adds to what NAME holds rather than writing NAME a
second time: every reader Org has joins such a line in, and however
many of them a drawer carries they agree on one value.  So only the
plain name is counted, and only it can be written twice.

Org has no one answer for a name that is: a scan of the drawer
reports the first line, a lookup the last, `org-set-property' writes
the first and leaves the second standing, and `org-delete-property'
takes both away.  Such a name has no value to assert and no value to
replace, so `org-records-mcp--write-properties' refuses a call that names
one instead of reporting a mismatch no re-read can resolve."
  (save-excursion
    (when-let* ((block (org-get-property-block)))
      (goto-char (car block))
      (let ((seen nil)
            (doubled nil))
        (while (re-search-forward org-property-re (cdr block) t)
          (let ((name (upcase (match-string-no-properties 2))))
            (unless (string-suffix-p "+" name)
              (if (member name seen)
                  (cl-pushnew name doubled :test #'string=)
                (push name seen)))))
        (nreverse doubled)))))

(defun org-records-mcp--set-property (name value)
  "Write VALUE as the whole of what the property NAME holds at point.
A `NAME+' line adds to what NAME holds, and every reader Org has
joins the lines into the one value a read returns.
`org-set-property' writes the plain line alone, so on such a drawer
it would leave the property holding the new value and the old
addition together, while the response reported it set to the value
asked for.  The accumulating lines are what the new value
supersedes, and the `before' this write is guarded by asserted the
value they are part of, so the call named everything taken away
here.

Org takes those lines away only together with the plain one, in
`org-entry-delete', which is the removal this tool goes through;
this is that function's search narrowed to them, off the same
`org-re-property'.  The plain line is left for `org-set-property' to
rewrite where it stands, so setting a property does not move it down
the drawer."
  (save-excursion
    (when-let* ((block (org-get-property-block)))
      (let ((end (copy-marker (cdr block)))
            (re
             (org-re-property
              (concat (regexp-quote name) "\\+") t t)))
        (goto-char (car block))
        (while (re-search-forward re end t)
          (delete-region
           (match-beginning 0) (line-beginning-position 2)))
        (set-marker end nil))))
  (org-set-property name value))

(defun org-records-mcp--node-properties (names file-node)
  "Return the Org property drawer of the node at point, or nil.
NAMES is `all' for the whole drawer or the upcased names to take
from it, as `org-records-mcp--node-properties-given' resolved them; nil
takes nothing, and a name the drawer does not hold contributes
nothing, the way a field with no value does.

FILE-NODE non-nil means the node is the file the buffer visits, whose
drawer is the one before its first heading.  A file that opens on a
heading has none, see `org-records-mcp--file-drawer-region-p', and answers
with no drawer rather than with that heading's.

The drawer itself comes from `org-records-mcp--drawer-at-point', which the
assertion path reads too."
  (when (and names
             (or (not file-node)
                 (org-records-mcp--file-drawer-region-p)))
    (cl-remove-if-not
     (lambda (pair)
       (or (eq names 'all) (member (car pair) names)))
     (org-records-mcp--drawer-at-point))))

(defun org-records-mcp--node-computed (names)
  "Return the computed fields of the node at point, or nil.
NAMES is `all' for every field `org-records-mcp-computed-fields' configures,
or the names to take from it, as `org-records-mcp--node-computed-given'
resolved them; nil takes none.  Each function runs at the node, and
an answer of nil is left out, the way a field with no value is."
  (when names
    (delq
     nil
     (mapcar
      (lambda (entry)
        (when (or (eq names 'all) (memq (car entry) names))
          (when-let* ((value (funcall (cdr entry))))
            (cons (car entry) value))))
      org-records-mcp-computed-fields))))

(defun org-records-mcp--node-needs-children-p (fields file-node)
  "Return non-nil when a node carrying FIELDS must find its children.
A node asked for `children' needs their positions to build them.  A
file node, FILE-NODE non-nil, needs them for its body as well: a
file's body is the preamble before its first heading, so both
`content' and `content_digest' are bounded by the first child."
  (or (memq 'children fields)
      (and file-node
           (or (memq 'content fields)
               (memq 'content_digest fields)))))

(defun org-records-mcp--node-link-at-point (file-node)
  "Return the link naming the node at point.
FILE-NODE non-nil means the node is the file the buffer visits,
which `org-records-mcp--file-link' names; otherwise it is the heading at
point, which `org-records-mcp--link-at-point' names."
  (if file-node
      (org-records-mcp--file-link)
    (org-records-mcp--link-at-point)))

(defun org-records-mcp--crumb-at-point (&optional link)
  "Return the crumb naming the heading at point.
The crumb is an alist of its `title', `link' and `level', the title
and link taken from `org-records-mcp--title-at-point' and
`org-records-mcp--link-at-point', so a crumb names its heading as a
read of it does.  LINK, when non-nil, is that link already made for
the heading: making one is the costly part, since
`org-store-link' makes it."
  `((title . ,(org-records-mcp--title-at-point))
    (link . ,(or link (org-records-mcp--link-at-point)))
    (level . ,(org-outline-level))))

(defun org-records-mcp--breadcrumbs-at-point ()
  "Return the ancestors of the heading at point, outermost first.
Each is the crumb `org-records-mcp--crumb-at-point' makes at that
ancestor.  A heading with no TODO keyword is an ancestor like any
other; the file is not one, since `file' and `link' already name it.

The answer is a list, nil for a top-level heading and before the
first heading, so the field is left out of a node without ancestors.
The buffer is read widened, since a narrowing hides ancestors rather
than removing them, and point is not moved.

A walk makes this once, at the node it starts from; each generation
it expands below is handed its ancestors by its parent, see
`org-records-mcp--node-at-point'."
  (let (crumbs)
    (org-with-wide-buffer
     (unless (org-before-first-heading-p)
       (org-back-to-heading t)
       (while (org-up-heading-safe)
         (push (org-records-mcp--crumb-at-point) crumbs))))
    crumbs))

(defun org-records-mcp--blocked-at-point (todo)
  "Return whether the heading at point, in state TODO, is blocked.
The answer is Org's own, `org-entry-blocked-p', which runs
`org-blocker-hook' as a change to done would: it counts Org's
`org-enforce-todo-dependencies' and any blocker the user's Emacs
adds there, org-edna's among them when `org-edna-mode' is on.

It is t or `:json-false' for a heading whose TODO is a not-done
keyword, and nil otherwise, so the field is left out of a heading
without a keyword or with a done one: no change to done is there to
block.  The buffer is read widened, since a blocker may look at
siblings and children a narrowing hides, and point is not moved."
  (when (member todo org-not-done-keywords)
    (org-with-wide-buffer
     (org-back-to-heading t)
     (if (org-entry-blocked-p)
         t
       :json-false))))

(defconst org-records-mcp--log-escapes
  (let
      ((quoted
        (lambda (group)
          (format " *\\(?:\"\\(?%d:[^\"\n]*\\)\"\\)? *" group)))
       ;; Org's own timestamp regexps carry numbered groups of their
       ;; own, which would renumber the three the parse reads, so the
       ;; bracket shapes are spelled out here.
       (inactive
        "\\(?1:\\[[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}[^]\n]*\\]\\)")
       (active
        "\\(?1:<[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}[^>\n]*>\\)"))
    `(("%t" . ,inactive)
      ("%d" . ,inactive)
      ("%T" . ,active)
      ("%D" . ,active)
      ("%s" . ,(funcall quoted 2))
      ("%S" . ,(funcall quoted 3))
      ("%u" . ".*?")
      ("%U" . ".*?")))
  "What each escape of `org-log-note-headings' matches in a log entry.
`org-store-log-note' fills them: the time in group 1, the new state
or date in group 2 and the old one in group 3, each of those two in
the double quotes it writes and absent when it had none.  The
spaces around them take up the padding a width such as %-12s adds.")

(defun org-records-mcp--log-heading-regexp (heading)
  "Return the regexp matching a log entry's line written from HEADING.
HEADING is a value of `org-log-note-headings'.  The regexp matches
the entry's whole first line, the \\\\ Org ends it with when prose
follows included, and its groups are those
`org-records-mcp--log-escapes' names.

Org has no reader for the entries it writes: org-habit and the
agenda's log mode each build a regexp from the heading they look
for, quoting it and replacing its escapes, and this does the same
for every heading.  A width is dropped before quoting, since the
padding it writes is taken up by the escape itself."
  (concat
   "\\`"
   (org-replace-escapes
    (regexp-quote
     (replace-regexp-in-string
      "%-?[0-9.]*\\([a-zA-Z]\\)" "%\\1" heading
      t))
    org-records-mcp--log-escapes)
   "\\(?:[ \t]+\\\\\\\\\\)?[ \t]*\\'"))

(defun org-records-mcp--log-prose (lines)
  "Return LINES as prose: joined, the indentation they share removed.
LINES are indented with spaces alone, see
`org-records-mcp--log-item-lines'.  Blank lines at either end are
dropped, and nil means there is no prose.  `org-store-log-note'
indents every line of a note to the column of the item's text, so
removing what they share leaves the note as it was typed, its own
indentation kept."
  (let* ((lines
          (reverse
           (seq-drop-while
            #'string-blank-p
            (reverse (seq-drop-while #'string-blank-p lines)))))
         (indent
          (cl-loop
           for
           line
           in
           lines
           unless
           (string-blank-p line)
           minimize
           (- (length line) (length (string-trim-left line " +"))))))
    (when lines
      (mapconcat (lambda (line)
                   (if (string-blank-p line)
                       ""
                     (substring line indent)))
                 lines
                 "\n"))))

(defun org-records-mcp--log-item-lines (begin end)
  "Return the lines of the list item from BEGIN to END, indented with spaces.
Each line is indented to the column it starts at, whatever mix of
spaces and TABs the file indents it with: Org indents a note's lines
with a TAB once the item's text is 8 columns in and
`indent-tabs-mode' is on.  The bullet of the first line is blanked
to the same width, so its text keeps its column too, and what
follows the bullet -- a checkbox, a counter, a description tag --
is the item's text.  Nil when the item holds nothing but blanks."
  (save-excursion
    (goto-char begin)
    (forward-line 0)
    (let ((lines '()))
      (while (< (point) end)
        (if (and (null lines) (looking-at org-list-full-item-re))
            (goto-char (match-end 1))
          (back-to-indentation))
        (push (concat
               (make-string (current-column) ?\s)
               (buffer-substring-no-properties
                (point) (line-end-position)))
              lines)
        (forward-line))
      (unless (seq-every-p #'string-blank-p lines)
        (nreverse lines)))))

(defun org-records-mcp--log-headings ()
  "Return what log entries are told apart by, as (MATCHERS . UNDER-CLOCK).
MATCHERS is a list of (PURPOSE . REGEXP), one for each purpose
`org-log-note-headings' gives a heading line, in its order, REGEXP
the one `org-records-mcp--log-heading-regexp' makes.  UNDER-CLOCK
is the purpose of an item no heading matches that sits right under
a CLOCK line: `clock-out' when its heading is empty, which is the
note Org writes there, and otherwise the first purpose with an empty
heading, or nil when none has one.  Empty is as `org-store-log-note'
judges it, which writes no line for a blank heading.

A log is read with one of these, built once, rather than building a
regexp per heading for every entry it reads."
  (let ((blank
         (cl-remove-if
          #'org-string-nw-p
          org-log-note-headings
          :key #'cdr)))
    (cons
     (cl-loop
      for
      (purpose . heading)
      in
      org-log-note-headings
      when
      (org-string-nw-p heading)
      collect
      (cons purpose (org-records-mcp--log-heading-regexp heading)))
     (car (or (assq 'clock-out blank) (car blank))))))

(defun org-records-mcp--clock-end (clock)
  "Return the end of CLOCK, a clock element, as Org wrote it, or nil.
Nil for a clock still running."
  (let ((raw
         (org-element-property
          :raw-value (org-element-property :value clock))))
    (when (and raw (string-match "--\\(\\[[^]\n]+\\]\\)\\'" raw))
      (match-string 1 raw))))

(defun org-records-mcp--log-entry (begin end clock headings)
  "Return the log entry of the list item from BEGIN to END, or nil.
The item is one at the top of a log drawer.  The entry is an alist of the `kind', `time', `from', `to' and `text'
it has values for.  HEADINGS is what
`org-records-mcp--log-headings' answers.  The item's first line is
matched against each heading's regexp, and the purpose of the first
that matches is its kind; the time and the two states are what that
line carries, see `org-records-mcp--log-escapes', and the text is
the prose under it.

A purpose given an empty heading, such as `clock-out', writes the
prose alone, so nothing in the item names it.  Org writes a
clock-out note right below its clock, so an item no heading matches
that sits right under CLOCK, the clock element above it or nil, is
of the purpose HEADINGS names for that place, and its time is when
that clock ended.  Any other item no heading matches carries its
text and no kind.  An item with nothing in it is no entry, and gives
nil."
  (when-let* ((lines (org-records-mcp--log-item-lines begin end)))
    (let* ((first (string-trim-left (car lines)))
           ;; Org writes a heading's words as configured, so they
           ;; are matched as written.
           (case-fold-search nil)
           (matched
            (cl-loop
             for (purpose . regexp) in (car headings) thereis
             (and (string-match regexp first)
                  (list
                   purpose
                   (match-string 1 first)
                   (match-string 3 first)
                   (match-string 2 first)))))
           (placed (and (not matched) clock (cdr headings))))
      (cl-loop
       for
       (key . value)
       in
       `((kind
          .
          ,(when-let* ((kind (or (car matched) placed)))
             (symbol-name kind)))
         (time
          .
          ,(if placed
               (org-records-mcp--clock-end clock)
             (nth 1 matched)))
         (from . ,(nth 2 matched)) (to . ,(nth 3 matched))
         (text
          .
          ,(org-records-mcp--log-prose
            (if matched
                (cdr lines)
              lines))))
       when
       (and value (not (string-empty-p value)))
       collect
       (cons key value)))))

(defun org-records-mcp--log-drawer-contents ()
  "Return the contents of the log drawer of the heading at point.
The value is (BEGIN . END), or nil for a heading without the
drawer or with an empty one.  The drawer is the one
`org-log-into-drawer' names for this heading, its LOG_INTO_DRAWER
property counted, and LOGBOOK when it names none: a heading logging
into no drawer writes its notes into its body, and a drawer's notes
are kept in LOGBOOK.

It is found as `org-log-beginning' finds it, the first drawer of
that name below the heading's planning and properties.  That
function cannot be asked, since it answers where the next note goes
rather than whether there is a drawer.  The buffer is read widened
and point is not moved."
  (org-with-wide-buffer
   (org-back-to-heading t)
   (let ((regexp
          (concat
           "^[ \t]*:"
           (regexp-quote (or (org-log-into-drawer) "LOGBOOK"))
           ":[ \t]*$"))
         (case-fold-search t))
     (org-end-of-meta-data)
     (let ((end
            (if (org-at-heading-p)
                (point)
              (save-excursion
                (outline-next-heading)
                (point)))))
       (catch 'found
         (while (re-search-forward regexp end t)
           (let ((element (org-element-at-point)))
             (when (org-element-type-p element 'drawer)
               (throw 'found
                      (when-let* ((begin
                                   (org-element-contents-begin
                                    element)))
                        (cons
                         begin
                         (org-element-contents-end element))))))))))))

(defun org-records-mcp--log-at-point ()
  "Return the log entries of the heading at point, newest first.
Each is the alist `org-records-mcp--log-entry' makes of a list item
of the drawer `org-records-mcp--log-drawer-contents' finds.  CLOCK
lines are left out, since the clock tools answer for them, and so is
any text in the drawer that is not a list item.  A clock-out note is
read only when it is in this drawer: Org writes one under its CLOCK
line, in the drawer `org-clock-into-drawer' names.

Org writes the newest entry at the top of the drawer while
`org-log-states-order-reversed' is on, which a file's #+STARTUP can
turn off, and at the bottom otherwise; the drawer is read in the
order that setting says, so the newest entry comes first either
way.  The answer is nil when there is no entry, so the field is
left out."
  (when-let* ((bounds (org-records-mcp--log-drawer-contents)))
    (org-with-wide-buffer
     (goto-char (car bounds))
     (let ((headings (org-records-mcp--log-headings))
           (clock nil)
           (entries '()))
       ;; The drawer's elements are visited one at a time through
       ;; `org-element-at-point', which answers from Org's element
       ;; cache, rather than parsing the drawer afresh with
       ;; `org-element-parse-buffer' on every read.
       (while (progn
                (skip-chars-forward " \t\n" (cdr bounds))
                (< (point) (cdr bounds)))
         (let* ((element (org-element-at-point))
                (element
                 (if (org-element-type-p element 'item)
                     (org-element-parent element)
                   element)))
           (when (org-element-type-p element 'plain-list)
             ;; The list's own items, those at its top; the ones nested
             ;; under them are part of their text.
             (let ((struct (org-element-property :structure element)))
               (dolist (item
                        (org-list-get-all-items
                         (org-list-get-top-point struct)
                         struct
                         (org-list-prevs-alist struct)))
                 (when-let* ((entry
                              (org-records-mcp--log-entry
                               item
                               (org-list-get-item-end item struct)
                               clock
                               headings)))
                   (push entry entries))
                 ;; Only the first item sits right under the clock.
                 (setq clock nil))))
           (setq clock
                 (and (org-element-type-p element 'clock) element))
           (goto-char
            (max (org-element-end element)
                 (line-beginning-position 2)))))
       (if org-log-states-order-reversed
           (nreverse entries)
         entries)))))

(defun org-records-mcp--child-projection
    (fields properties computed depth)
  "Return what the children of a node asked for DEPTH carry.
The value is (FIELDS PROPERTIES COMPUTED) for the next generation.

While DEPTH remains, a child carries everything its parent was asked
for -- its fields, its drawer and its computed values alike -- so a
child inside a node is the node a call reading that child by its
link gets.  All three travel together because all three are what a
read of that child would answer: expanding the fields alone would
make an expanded child a shape of its own, which is what having one
node shape exists to prevent.

The generation past DEPTH comes back as a reference: the fields
`org-records-mcp--node-child-fields' names and neither namespace, so a walk
ends in an address the caller can follow rather than in a node that
looks whole and is not."
  (if (> depth 0)
      (list fields properties computed)
    (list org-records-mcp--node-child-fields nil nil)))

(defun org-records-mcp--spend-node (budget file-node)
  "Spend one node of BUDGET, or refuse the walk at the node at point.
BUDGET is the cell `org-records-mcp--projected-node-at-point' hands the
walk, holding the nodes the walk may still return.  When it is empty the walk is
refused rather than cut short: a caller handed a subtree that was
silently shortened believes it has seen the whole thing.

The refusal names the node the walk stopped at, which is a link the
caller can read on its own, and `org-records-mcp-read-max-nodes', which is
where the user raises the ceiling.  FILE-NODE says which kind of
node point is on; see `org-records-mcp--node-link-at-point'."
  (when (< (cl-decf (car budget)) 0)
    (org-records-mcp--tool-validation-error
     "Too many nodes: more than %d.  The walk stops at %s: ask for \
a shallower depth, or read that node on its own.  \
org-records-mcp-read-max-nodes sets the ceiling"
     org-records-mcp-read-max-nodes
     (org-records-mcp--node-link-at-point file-node))))

(defun org-records-mcp--node-at-point
    (fields
     properties computed depth file-node budget &optional ancestors)
  "Return the node at point as an alist carrying FIELDS, within BUDGET.
One node shape serves a file, a heading, a child and a query result,
so a client learns one vocabulary to walk an outline.

FIELDS is a list of node field names, in the order the node lists
them; `org-records-mcp--node-fields' names every one there is.  A field the
node has no value for -- no TODO state, no tag of its own, an empty
body -- is left out rather than sent as null.  PROPERTIES and
COMPUTED are the node\\='s two other namespaces, see
`org-records-mcp--projected-node-at-point'.

DEPTH is how many generations of children the `children' field
expands in place; see `org-records-mcp--child-projection' for what each
generation carries.

FILE-NODE non-nil builds the node of the file the buffer visits: a
node at level 0, carrying the file's title, a link to the file and
its preamble as its content.  The caller says which of the two it
asked for, because point cannot: a file that opens on a heading has
no position before that heading.

BUDGET is the walk\\='s, which `org-records-mcp--spend-node' spends one node
of per node built, this one included.  Every caller is given its own,
`org-records-mcp-read-max-nodes' nodes to spend, so a list of matches is
bounded one match at a time.

ANCESTORS, when non-nil, is a one-element list holding the node\\='s
ancestors as `org-records-mcp--breadcrumbs-at-point' would answer them.
A parent hands its expanded children their ancestors -- its own and
itself -- so a walk climbs the outline once, at the node it starts
from, rather than once per node it returns.  Nil means they are not
known and the node finds them itself."
  (org-records-mcp--spend-node budget file-node)
  (let* ((meta
          (unless file-node
            (org-records-mcp--heading-metadata-at-point)))
         (children
          (when (org-records-mcp--node-needs-children-p
                 fields file-node)
            (org-records-mcp--node-child-positions file-node)))
         (link
          (when (or (memq 'link fields) (memq 'id fields))
            (org-records-mcp--node-link-at-point file-node)))
         (crumbs
          (when (and (memq 'breadcrumbs fields) (not file-node))
            (if ancestors
                (car ancestors)
              (org-records-mcp--breadcrumbs-at-point))))
         (node '()))
    (dolist (field fields)
      (let
          ((value
            (pcase field
              ('title
               (if file-node
                   (org-records-mcp--file-title)
                 (plist-get meta :title)))
              ('todo (plist-get meta :todo))
              ('priority (plist-get meta :priority))
              ('tags
               (when-let* ((tags (plist-get meta :tags)))
                 (vconcat tags)))
              ('local_tags
               (when-let* ((tags (plist-get meta :local-tags)))
                 (vconcat tags)))
              ('scheduled (plist-get meta :scheduled))
              ('deadline (plist-get meta :deadline))
              ('closed (plist-get meta :closed))
              ('file (buffer-file-name))
              ;; The ID the link names, so `id' and `link' always
              ;; agree; a blank :ID: gives neither.
              ('id
               (and link
                    (string-prefix-p "id:" link)
                    (substring link 3)))
              ('level
               (if file-node
                   0
                 (plist-get meta :level)))
              ('link link)
              ('breadcrumbs (and crumbs (vconcat crumbs)))
              ('blocked
               (unless file-node
                 (org-records-mcp--blocked-at-point
                  (plist-get meta :todo))))
              ('log
               (unless file-node
                 (when-let* ((entries
                              (org-records-mcp--log-at-point)))
                   (vconcat entries))))
              ('content
               (let* ((bounds
                       (org-records-mcp--node-content-bounds
                        file-node children))
                      (text
                       (buffer-substring-no-properties
                        (car bounds) (cdr bounds))))
                 (unless (string-blank-p text)
                   (string-trim text))))
              ('content_digest
               (org-records-mcp--digest
                (org-records-mcp--node-content-bounds
                 file-node children)))
              ('digest
               (org-records-mcp--digest
                (org-records-mcp--node-subtree-bounds file-node)))
              ('children
               (pcase-let* ((`(,child-fields
                               ,child-properties ,child-computed)
                             (org-records-mcp--child-projection
                              fields properties computed depth))
                            (child-ancestors
                             (when (memq 'breadcrumbs child-fields)
                               (list
                                (unless file-node
                                  (append
                                   crumbs
                                   (list
                                    (save-excursion
                                      (org-back-to-heading t)
                                      (org-records-mcp--crumb-at-point
                                       link)))))))))
                 (vconcat
                  (mapcar
                   (lambda (position)
                     (save-excursion
                       (goto-char position)
                       (org-records-mcp--node-at-point
                        child-fields
                        child-properties
                        child-computed
                        (1- depth)
                        nil
                        budget
                        child-ancestors)))
                   children))))
              ;; A call's fields are resolved against
              ;; `org-records-mcp--node-fields' before they reach here, so
              ;; this catches a field list written in this file
              ;; that the builder does not build.
              (_ (error "Unknown node field: %s" field)))))
        (when value
          (push (cons field value) node))))
    (append
     (nreverse node)
     (when-let* ((drawer
                  (org-records-mcp--node-properties
                   properties file-node)))
       (list (cons 'properties drawer)))
     (when-let* ((values (org-records-mcp--node-computed computed)))
       (list (cons 'computed values))))))

(defun org-records-mcp--projected-node-at-point
    (fields properties computed &optional depth file-node)
  "Return the node at point as a call asking for it receives it.
FIELDS is the node\\='s own fields and DEPTH how many generations of
children it expands, see `org-records-mcp--node-at-point'; FILE-NODE says
the node is the file\\='s, as it does there.  PROPERTIES is the node\\='s
Org drawer, see `org-records-mcp--node-properties'.  COMPUTED is what the
configured functions answer for it, see `org-records-mcp--node-computed'.

The three are three namespaces and arrive as three.  A field is a
key of the node; the drawer is one key, `properties', holding the
names the user wrote in the file; the answers are one key,
`computed'.  A property called TITLE therefore cannot collide with
the field `title'.

Keeping the last two apart is what tells a client which values a
write can put back: `properties' is in the file and survives the
round trip, `computed' is this server's answer at this moment and
belongs to no drawer.  Merged into one object they would be
indistinguishable without reading the configuration, and a client
would write this server\\='s opinion into the user\\='s file.

All three reach every generation DEPTH expands, so an expanded child
is the node a read of its link returns; see
`org-records-mcp--child-projection'."
  (org-records-mcp--node-at-point
   fields
   properties
   computed
   (or depth 0)
   file-node
   (list org-records-mcp-read-max-nodes)))

;; Links

(defconst org-records-mcp--link-forms-hint
  "Send id:<uuid>, file:<path>::#<custom-id>, file:<path>::*<title> or \
file:<path>, with the file's full path"
  "The sentence that tells a client which link forms a call takes.")

(defun org-records-mcp--not-a-link-error (link)
  "Throw the error for LINK, a string that is not written as an Org link.
The message names the link forms a call takes instead, and says when
LINK starts with `org://', the scheme of the resource, not of a link."
  (org-records-mcp--tool-validation-error
   "Not an Org link: %s.  %s%s"
   link
   (if (and (stringp link)
            (string-prefix-p "org://" (string-trim link)))
       "Drop org://, which only a resource URI starts with.  "
     "")
   org-records-mcp--link-forms-hint))

(defun org-records-mcp--link-written-p (string)
  "Return non-nil when STRING is written as an Org link.
It is bracketed, with or without a description, starts with a link
type such as `id:' or `file:', or is a search such as `#custom-id' or
`*Title'.  A string starting with `org://', the scheme of the
resource, is no link, and neither is any other string, such as an ID,
a path or a title on its own."
  (when (stringp string)
    (let ((trimmed (string-trim string)))
      (and (not (string-prefix-p "org://" trimmed))
           (or (string-prefix-p "[[" trimmed)
               (string-match-p "\\`[#*]" trimmed)
               (string-match-p org-link-types-re trimmed))))))

(defun org-records-mcp--link-parse (link)
  "Parse LINK with `org-element-link-parser' and return the link object.
LINK is bracketed, with or without a description, or bare; see
`org-records-mcp--link-written-p'.  A search on its own, such as `#custom-id'
or `*Title', is parsed here and refused by `org-records-mcp--link-target' for
naming no file.  A string that is no link is refused by
`org-records-mcp--not-a-link-error'.  Link abbreviations are not expanded,
since an abbreviation can call a function, and
`org-link-translation-function' is not applied."
  (unless (org-records-mcp--link-written-p link)
    (org-records-mcp--not-a-link-error link))
  (let ((trimmed (string-trim link)))
    (with-temp-buffer
      (let ((org-link-abbrev-alist nil)
            (org-link-abbrev-alist-local nil)
            (org-link-translation-function nil))
        (insert
         (if (string-prefix-p "[[" trimmed)
             trimmed
           (org-link-make-string trimmed)))
        (goto-char (point-min))
        (let ((object (org-element-link-parser)))
          (unless (and object
                       (= (org-element-property :end object)
                          (point-max)))
            (org-records-mcp--tool-validation-error
             "Not a single Org link: %s"
             link))
          object)))))

(defun org-records-mcp--link-full-path-error (link)
  "Throw the error for LINK, which names no local file by its full path."
  (org-records-mcp--tool-validation-error
   "Link names no local file by its full path: %s.  Send a full path, \
such as file:/home/user/notes.org::*Heading, or an id: link"
   link))

(defun org-records-mcp--link-file (object link)
  "Return the file that the file link OBJECT names, if the call may reach it.
LINK is the link as the client sent it, for error messages.  The
path must be absolute and local.  `org-records-mcp--local-file-name' expands
it with file name handlers disabled, so a path that is remote as
written, or only once `.', `..' or `~' are expanded, is refused
before TRAMP can open a connection for it.  The expanded name then
goes through the scope gate, `org-records-mcp--find-allowed-file', as a file
the call names, so `org-records-mcp-file-scope-override' applies.  No buffer
is visited.

A refused path that holds `#' is most likely a path with an outline
path appended, bracketed so that Org reads it as a file link; its
refusal names the link forms to send.  Whether such a file exists
does not change the refusal, so it tells nothing about files the call
may not reach."
  (let ((application (org-element-property :application object))
        (path (org-element-property :path object)))
    (unless (member application '(nil "emacs"))
      (org-records-mcp--tool-validation-error
       "Link type 'file+%s' is not supported: %s"
       application link))
    (let ((local
           (and (file-name-absolute-p path)
                (org-records-mcp--local-file-name path))))
      (unless local
        (org-records-mcp--link-full-path-error link))
      (or (org-records-mcp--find-allowed-file local t)
          (org-records-mcp--tool-file-access-error
           link
           (and (string-search "#" path)
                org-records-mcp--link-forms-hint))))))

(defun org-records-mcp--link-id-file (id link)
  "Return the file that holds ID, which LINK names, when the call may reach it.
Emacs's ID index names the file, through `org-id-find-id-file', which
only reads the index.  That file must pass the scope gate,
`org-records-mcp--find-allowed-file', before this function reads it,
and it passes as a file the call names: the index names it on the
call's behalf, so `org-records-mcp-file-scope-override' reaches it as
it reaches the file of a `file:' link.  A file the index names that
is neither allowed nor permitted by the override is refused without
being read, and a remote one, or a symlink to one, before TRAMP can
open a connection for it.  Only then is the file searched for ID,
with `org-id-find-id-in-file', which reads the buffer visiting it, or
else its contents into a temporary buffer.

When the index lacks ID, or the file it names does not hold it, the
index is rescanned once with `org-id-update-id-locations', as
`org-id-find' does on a miss, and the file it then names goes through
the gate in turn; the caller finds ID in that file's buffer.  The
rescan is Org's and reads every file Org knows of, whatever the
scope: the agenda files and their archives, `org-id-extra-files', the
files of `org-id-files' and every Org file a buffer visits.  It
resolves each with `file-truename', so a remote file among them is
handed to TRAMP.  A first answer the gate refuses ends the lookup
there, with no rescan.
`org-id-find' is not called itself: it reads the file the index names
before any gate could refuse it, and so asks TRAMP about a remote one.

The index is read in a temporary buffer because `org-id-find-id-file'
falls back to the current buffer's file for an ID it lacks.  Errors
from the index, such as the refusal to rescan when
`org-id-track-globally' is off, count as an unknown ID.  Neither error
this function throws names a file."
  (cl-flet ((indexed-file
             ()
             (with-temp-buffer
               (ignore-errors
                 (org-id-find-id-file id))))
            (reachable
             (file)
             (or (org-records-mcp--find-allowed-file file t)
                 (org-records-mcp--tool-file-access-error link))))
    (unless (org-string-nw-p id)
      (org-records-mcp--id-not-found-error id))
    (let* ((indexed (indexed-file))
           (file (and indexed (reachable indexed))))
      (if (and file (org-id-find-id-in-file id file))
          file
        (ignore-errors
          (org-id-update-id-locations nil t))
        (reachable
         (or (indexed-file)
             (org-records-mcp--id-not-found-error id)))))))

(defun org-records-mcp--link-id-in-files (id files)
  "Return the first of the files FILES names that holds ID.
FILES is the call's `files' parameter.  `org-records-mcp--named-file-set'
checks and expands it, so it reaches as far as
`org-records-mcp-file-scope-override' permits, and its files are searched in
the order that function returns them.  Each is searched with
`org-id-find-id-in-file', which reads the file, or the buffer visiting
it, and consults no ID index: an ID in a file Emacs never indexed is
found, Org's rescan never runs, and nothing is added to
`org-id-locations'.  An ID none of them holds is an error naming FILES
as the call sent them.  The search opens no buffer on these files:
Org reads a file that no buffer visits into a work buffer of its own."
  (let ((set (org-records-mcp--named-file-set files)))
    (or (and (org-string-nw-p id)
             (cl-find-if
              (lambda (file) (org-id-find-id-in-file id file)) set))
        (org-records-mcp--tool-validation-error
         "Cannot find ID '%s' in files: %s"
         id
         (if (stringp files)
             files
           (mapconcat #'identity files ", "))))))

(defun org-records-mcp--check-files (object link files)
  "Return FILES, sent with LINK, or nil when it is blank.
OBJECT is LINK as `org-records-mcp--link-parse' parsed it.  FILES is the
call's `files' parameter, read through `org-records-mcp--files-given'.  It
applies only to an `id:' link, the one link type org-records-mcp resolves
without a file, so with any other LINK a FILES that is not blank is
refused here, before any file is opened: with a `file:' link, which
names its file already, or a link of another type."
  (when-let* ((files (org-records-mcp--files-given files)))
    (unless (equal (org-element-property :type object) "id")
      (org-records-mcp--tool-validation-error
       "files applies only to an id: link: %s"
       link))
    files))

(defun org-records-mcp--link-target
    (link name &optional files id-file)
  "Return the target of LINK, the link parameter NAME carries.
LINK is a native Org link and no buffer is visited to resolve it.
The value is a plist: `:link' is LINK, `:file' the file it names,
which the call may reach, `:id' the ID of an `id:' link, and
`:search' the part after `::', if any.  The file of an `id:' link is
the one Emacs's ID index names, through `org-records-mcp--link-id-file',
unless FILES or ID-FILE say otherwise.  Whether an `id:' link without
a search part names a heading or its whole file is decided in the
file's buffer, by `org-records-mcp--target-heading-p'.  Only `id:'
and `file:' links are accepted.  A string that is not a link is
refused by `org-records-mcp--link-parse', and every other link type
here, before any file is opened, and so is a link that names no
file, such as `[[#custom-id]]' or `[[*Title]]'.

NAME is the parameter LINK arrived in, so that a blank is refused as
the parameter it is rather than parsed: every link a call sends comes
through here, which is what makes that refusal the same on every
tool.  `org-records-mcp--link-given' is where it happens, and an optional link
parameter reaches here only once `org-records-mcp--optional-link-given' has
found it is not blank.

FILES is the call's `files' parameter, checked against LINK by
`org-records-mcp--check-files'.  When it is not blank, the ID of an `id:' link
is looked up in those files by `org-records-mcp--link-id-in-files' rather
than through Org's ID index.  ID-FILE, when non-nil, is a file the
call already reaches: the ID of an `id:' link is taken to be in it,
with no lookup, and the caller finds the ID in that file's buffer."
  (let*
      ((link (org-records-mcp--link-given link name))
       (object (org-records-mcp--link-parse link))
       (link (string-trim link))
       (files (org-records-mcp--check-files object link files))
       (type (org-element-property :type object))
       (path (org-element-property :path object))
       (target
        (pcase type
          ("id"
           ;; The parser keeps the search part of an `id:' link in
           ;; its path; split it off the way `org-id-open' does.
           (let* ((search
                   (and (string-match "::\\(.*\\)\\'" path)
                        (match-string 1 path)))
                  (id
                   (if search
                       (substring path 0 (match-beginning 0))
                     path)))
             (list
              :link link
              :file
              (cond
               (id-file
                id-file)
               (files
                (org-records-mcp--link-id-in-files id files))
               (t
                (org-records-mcp--link-id-file id link)))
              :id id
              :search search)))
          ("file"
           (list
            :link link
            :file (org-records-mcp--link-file object link)
            :search (org-element-property :search-option object)))
          ((or "custom-id" "fuzzy" "coderef")
           (org-records-mcp--link-full-path-error link))
          (_
           (org-records-mcp--tool-validation-error
            "Link type '%s' is not supported: send an id: or file: link"
            type)))))
    ;; `org-link-search' turns a regexp search into a sparse tree,
    ;; which would refold the user's buffer.
    (when (string-match-p
           "\\`/.*/\\'" (or (plist-get target :search) ""))
      (org-records-mcp--tool-validation-error
       "Regexp search is not supported in a link: %s"
       link))
    target))

(defun org-records-mcp--link-goto (target)
  "Move point to where TARGET points in the current buffer.
TARGET comes from `org-records-mcp--link-target', and the current buffer
visits its file, widened.  This is the lookup `org-id-open' and
`org-open-file' perform, without their navigation: `org-link-open' is
never called, because it switches windows, widens the user's buffer,
pushes the mark ring and unfolds headings.  A search that matches
several headings goes to the first, as it does in Org, and a search
that matches nothing is an error rather than an offer to create a
heading."
  (let ((id (plist-get target :id))
        (search (plist-get target :search)))
    (goto-char (point-min))
    (when id
      ;; The lookup yields the file only.  The ID is located in this
      ;; buffer, which may hold unsaved edits the file lacks.
      (goto-char
       (or (org-find-entry-with-id id)
           (org-records-mcp--id-not-found-error id))))
    (when search
      (save-restriction
        ;; An `id:' link searches the ID's subtree, as `org-id-open'
        ;; does, and a `file:' link the whole file.
        (when (and id (not (org-before-first-heading-p)))
          (org-narrow-to-subtree))
        (if (and (not id) (string-match-p "\\`[0-9]+\\'" search))
            ;; A line number, as `org-link-open-as-file' reads it.
            (org-goto-line (string-to-number search))
          (let ((org-link-search-must-match-exact-headline t)
                (org-execute-file-search-functions nil))
            (condition-case err
                (org-link-search search nil t)
              (error
               (org-records-mcp--tool-validation-error
                "Cannot resolve link %s: %s"
                (plist-get target :link)
                (error-message-string err))))))))))

(defun org-records-mcp--target-heading-p (target)
  "Return non-nil when TARGET names a heading rather than a whole file.
TARGET comes from `org-records-mcp--link-target', and the current buffer
visits its file, widened.  A link with a search part names a heading.
Without one, a `file:' link names its file, and so does an `id:' link
whose ID Org finds before the first heading, in the file-level
property drawer where org-roam keeps the ID of a file node:
`org-id-open' opens the file at its top for it.  Point does not move."
  (or (plist-get target :search)
      (and (plist-get target :id)
           (save-excursion
             (org-records-mcp--link-goto target)
             (not (org-before-first-heading-p))))))

(defun org-records-mcp--goto-heading (target)
  "Move point to the start of the heading TARGET names, or throw a tool error.
TARGET comes from `org-records-mcp--link-target', and the current buffer
visits its file, widened.  A TARGET naming a whole file, see
`org-records-mcp--target-heading-p', is refused."
  (org-records-mcp--link-goto target)
  (unless (and (org-records-mcp--target-heading-p target)
               (org-at-heading-p))
    (org-records-mcp--tool-validation-error
     "Link does not point to a heading: %s"
     (plist-get target :link)))
  ;; A search can land inside the heading's line, on a target or a
  ;; word of the title; every caller starts at the heading.
  (org-back-to-heading t))

(defun org-records-mcp--read-link
    (link name read-heading read-file &optional files)
  "Read what native Org LINK points to.
NAME is the parameter LINK arrived in; see `org-records-mcp--link-target'.
READ-HEADING is called with no arguments and point at the heading
LINK names.  READ-FILE is called with the file when LINK names a
whole file, see `org-records-mcp--target-heading-p'.  FILES is the call's
`files' parameter; see `org-records-mcp--link-target'."
  (let* ((target (org-records-mcp--link-target link name files))
         (file (plist-get target :file)))
    (org-records-mcp--with-org-file file
      (if (org-records-mcp--target-heading-p target)
          (progn
            (org-records-mcp--goto-heading target)
            (funcall read-heading))
        (funcall read-file file)))))

;; Clock helpers

(defun org-records-mcp--clock-round-time (time)
  "Round TIME per `org-clock-rounding-minutes'.
TIME is an Emacs time value.  Returns rounded time.

This helper mirrors the rounding logic that `org-clock-in' and
`org-clock-out' apply inline before writing CLOCK lines.  Org does
not expose a public rounding helper, so we reimplement the same
semantics: when `org-clock-rounding-minutes' is a positive integer
greater than 1, round the minutes to the nearest multiple and zero
the seconds.  Any change to Org's rounding behaviour should be
reflected here."
  (if (and (boundp 'org-clock-rounding-minutes)
           (numberp org-clock-rounding-minutes)
           (> org-clock-rounding-minutes 1))
      (let* ((r org-clock-rounding-minutes)
             (decoded (decode-time time))
             (minutes (nth 1 decoded))
             (rounded (* r (round minutes r))))
        (apply #'encode-time
               (append (list 0 rounded) (nthcdr 2 decoded))))
    time))

(defun org-records-mcp--clock-format-timestamp (time)
  "Format TIME as an inactive Org clock timestamp, e.g. `[YYYY-MM-DD Day HH:MM]'.
Delegates the format to `org-time-stamp-format' so the output tracks
Org's own `org-timestamp-formats' customization."
  (format-time-string (org-time-stamp-format t t) time))

(defconst org-records-mcp--clock-timestamp-re
  (concat
   "\\`\\([0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\)"
   "\\(?:[ T]\\([0-9]\\{2\\}:[0-9]\\{2\\}\\)\\(?::[0-9]\\{2\\}\\)?\\)?\\'")
  "The shape a clock tool's timestamp parameter takes.
ISO 8601 as the clock tools document it: a date, optionally a time
after `T' or a space, optionally seconds after that.  Group 1 is the
date and group 2 the minute, which is what
`org-records-mcp--clock-parse-timestamp' compares against.")

(defun org-records-mcp--clock-parse-timestamp (str)
  "Parse ISO timestamp STR to Emacs time, refusing a time that is not one.
STR should be in ISO 8601 format like 2026-03-23T14:30:00.
The `T' separator is normalised to a space so `org-time-string-to-time'
accepts it.

A shape is not an existence, and `org-time-string-to-time' does not
say which it was given: it rolls `2026-02-30' over to 2026-03-02 and
`2026-03-27T25:99:00' to 02:39 the next day, and the clock written
then records a time the call never named.  `org-clock-delete' is the
one that loses something by it — its `start' is compared against the
CLOCK lines rather than written, so a rolled-over value does not
record a wrong time, it matches a different clock and takes that one
away.

So the parsed time is formatted back and compared with what was
sent.  The comparison is to the minute because that is what a CLOCK
line holds: `org-time-string-to-time' drops seconds, so a call may
send them and they are not recorded."
  (let ((normalised (replace-regexp-in-string "T" " " (or str ""))))
    (unless (string-match
             org-records-mcp--clock-timestamp-re normalised)
      (org-records-mcp--tool-validation-error
       "Cannot parse timestamp: '%s'"
       str))
    (let ((sent
           (concat
            (match-string 1 normalised)
            " "
            (or (match-string 2 normalised) "00:00")))
          (time
           (condition-case _
               (org-time-string-to-time normalised)
             (error
              (org-records-mcp--tool-validation-error
               "Cannot parse timestamp: '%s'"
               str)))))
      (unless (string=
               (format-time-string "%Y-%m-%d %H:%M" time) sent)
        (org-records-mcp--tool-validation-error
         "Not a time: '%s'.  Org reads it as %s, which is not the \
time the call named"
         str (format-time-string "%Y-%m-%dT%H:%M:%S" time)))
      time)))

(defun org-records-mcp--clock-duration-string (seconds)
  "Format SECONDS as clock duration string `H:MM'.
Delegates to `org-duration-from-minutes' with the `h:mm' specifier
that Org itself uses for CLOCK lines."
  (org-duration-from-minutes (round seconds 60) 'h:mm))

(defun org-records-mcp--clock-element-start-str (clock)
  "Return CLOCK element's start timestamp text, without surrounding brackets.
CLOCK is an Org element of type `clock'.  For a closed-range clock
the returned text is the start half of the range."
  (let ((raw
         (org-element-property
          :raw-value (org-element-property :value clock))))
    (when (and raw (string-match "\\`\\[\\([^]]+\\)\\]" raw))
      (match-string 1 raw))))

(defun org-records-mcp--clock-element-start-time (clock)
  "Return CLOCK element's start as an Emacs time value."
  (org-timestamp-to-time (org-element-property :value clock)))

(defun org-records-mcp--clock-element-end-time (clock)
  "Return CLOCK element's end as an Emacs time value.
Returns nil for open (unclosed) clocks."
  (let ((value (org-element-property :value clock)))
    (when (eq (org-element-property :type value) 'inactive-range)
      (org-timestamp-to-time value t))))

(defmacro org-records-mcp--with-wide-clock-buffer (file &rest body)
  "Run BODY in the buffer `org-find-open-clocks' searches for FILE, widened.
`org-find-open-clocks' searches only the accessible part of that
buffer, so it misses a clock outside the user's narrowing, and so does
a read at a clock's marker.  BODY runs with the buffer, found the same
way, widened, and the user's narrowing is restored afterwards."
  (declare (indent 1) (debug (form body)))
  `(with-current-buffer (or (get-file-buffer ,file)
                            (find-file-noselect ,file))
     (org-with-wide-buffer ,@body)))

(defun org-records-mcp--clock-find-active ()
  "Return the open CLOCK entry currently in effect, or nil when there is none.
The Emacs session's own running clock is authoritative: whenever
`org-clock-is-active' reports one whose CLOCK line is still open, that
clock is described, whether or not its file is in the allowed list.
A line closed since by a hand that left the Emacs clock pointing at
it, such as the user's own edit, leaves no clock running there.  With
no running clock, allowed files are scanned in order with
`org-find-open-clocks', each in full even where the user's buffer is
narrowed, see `org-records-mcp--with-wide-clock-buffer', and the first
dangling CLOCK line is described, which keeps clocks left unclosed by
an earlier session or another tool discoverable.

The value is an alist with keys `file', `heading', `start', `allowed'
and `marker'.  `allowed' is t when the clock's file is in the allowed
list and nil otherwise.  Start timestamps are read through the Org
element API."
  (or (when-let* ((buf (org-clock-is-active))
                  (file (buffer-file-name buf)))
        (with-current-buffer buf
          (org-with-wide-buffer
           (goto-char org-clock-marker)
           (let ((el (org-element-at-point)))
             (when (and (eq (org-element-type el) 'clock)
                        (eq
                         (org-element-property :status el) 'running))
               (list
                (cons 'file (expand-file-name file))
                (cons
                 'heading
                 (save-excursion
                   (org-back-to-heading t)
                   (org-records-mcp--title-at-point)))
                (cons
                 'start (org-records-mcp--clock-element-start-str el))
                (cons
                 'allowed
                 (and (org-records-mcp--find-allowed-file file) t))
                (cons 'marker org-clock-marker)))))))
      (catch 'found
        (dolist (file (org-records-mcp--expanded-allowed-files))
          (when (file-exists-p file)
            (org-records-mcp--with-wide-clock-buffer file
              (when-let* ((open (org-find-open-clocks file))
                          (marker (car (car open))))
                (with-current-buffer (marker-buffer marker)
                  (save-excursion
                    (goto-char marker)
                    (let* ((el (org-element-at-point))
                           (start-str
                            (org-records-mcp--clock-element-start-str
                             el))
                           (heading
                            (save-excursion
                              (org-back-to-heading t)
                              (org-records-mcp--title-at-point))))
                      (throw 'found
                             (list
                              (cons 'file (expand-file-name file))
                              (cons 'heading heading)
                              (cons 'start start-str)
                              (cons 'allowed t)
                              (cons 'marker marker))))))))))
        nil)))

(defun org-records-mcp--clock-describe-running (active)
  "Describe the running clock ACTIVE the way a refusal names it.
ACTIVE is the running clock as `org-records-mcp--clock-find-active' returns
it.  The text carries the heading's title, a link to that heading and
the clock's start, so a client refused for naming the wrong clock can
ask the user about this one and then name it back."
  (let ((marker (alist-get 'marker active)))
    (format "'%s' (%s) since %s"
            (alist-get 'heading active)
            (with-current-buffer (marker-buffer marker)
              (org-with-wide-buffer
               (goto-char marker)
               (org-back-to-heading t)
               (org-records-mcp--link-at-point)))
            (alist-get 'start active))))

(defun org-records-mcp--clock-names-running-p (active target)
  "Return non-nil when TARGET names the heading the clock ACTIVE runs on.
ACTIVE is the running clock as `org-records-mcp--clock-find-active' returns
it, and TARGET a link resolved by `org-records-mcp--link-target'.  The two
clock guards resolve an `id:' link differently, so each resolves its
own and this decides only what the result names.

The link `org-records-mcp--link-at-point' makes for the clock's heading names
it even when, as a title link, it finds an earlier heading of the same
title.  Every other link names the clock by landing on that heading,
so one naming a whole file, another heading, or no heading at all,
names no running clock."
  (let ((file (alist-get 'file active))
        (marker (alist-get 'marker active)))
    (with-current-buffer (marker-buffer marker)
      (org-with-wide-buffer
       (goto-char marker) (org-back-to-heading t)
       (let ((heading (point))
             (own-link (org-records-mcp--link-at-point)))
         (or
          ;; A title link org-records-mcp handed out for the running heading
          ;; finds the first heading of that title, which may be
          ;; another one.
          (equal
           (org-element-property
            :raw-link
            (org-records-mcp--link-parse (plist-get target :link)))
           own-link)
          (and (org-records-mcp--paths-equal-p
                (plist-get target :file) file)
               ;; A link that resolves to no heading in the file names
               ;; no running clock either.
               (ignore-error mcp-server-lib-tool-error
                 (org-records-mcp--goto-heading target)
                 (= (point) heading)))))))))

(defun org-records-mcp--clock-check-clock-out (active clock-out)
  "Refuse a clock-in unless CLOCK-OUT names the running clock ACTIVE.
ACTIVE is the running clock as `org-records-mcp--clock-find-active' returns
it, or nil when none runs.  CLOCK-OUT is the call's `clock_out'
parameter, a link to the heading of the running clock; a value
`org-records-mcp--optional-link-given' reads as blank counts as not sent.

With no clock running, a CLOCK-OUT is refused: it names no clock.  A
clock running outside the allowed files is refused whatever CLOCK-OUT
holds, since org-records-mcp tells a client nothing about that clock, not even
its heading.  Any other running clock needs a CLOCK-OUT that names its
heading, see `org-records-mcp--clock-names-running-p'; an `id:' CLOCK-OUT is
looked up in the running clock's file only, with no ID index and no
`files'.  A missing or wrong CLOCK-OUT is refused with that clock
described, see `org-records-mcp--clock-describe-running', so the client can
ask the user about it.  Nothing is changed.

A CLOCK-OUT that disagrees with the running clock is a conflict: the
client believed something about the world that no longer holds, and
reading the clock again is what puts it right."
  (let ((clock-out
         (org-records-mcp--optional-link-given
          clock-out "clock_out")))
    (cond
     ((not active)
      (when clock-out
        (org-records-mcp--tool-conflict-error
         "clock_out names a clock to close, but no clock is running: %s"
         clock-out)))
     ((not (alist-get 'allowed active))
      (org-records-mcp--tool-validation-error
       "A clock is running in a file outside the allowed files.  Ask the \
user to clock out of it before clocking in"))
     (t
      (unless clock-out
        (org-records-mcp--tool-conflict-error
         "A clock is running on %s.  Ask the user whether to \
clock out of it, then send its link as clock_out"
         (org-records-mcp--clock-describe-running active)))
      (unless (org-records-mcp--clock-names-running-p
               active
               (org-records-mcp--link-target
                clock-out "clock_out"
                nil (alist-get 'file active)))
        (org-records-mcp--tool-conflict-error
         "clock_out does not name the running clock: %s.  \
The clock runs on %s"
         clock-out
         (org-records-mcp--clock-describe-running active)))))))

(defun org-records-mcp--clock-save-closed
    (buf file preexisting-modified-p)
  "Save BUF, which holds the clock org-records-mcp closed, and report a failed save.
FILE is the file BUF visits.  A non-nil PREEXISTING-MODIFIED-P leaves
BUF unsaved with the user's own edits in it, see
`org-records-mcp--maybe-save-buffer'.

Closing the clock also stopped Emacs's own clock, which undo cannot
start again, so a failed save is not undone the way
`org-records-mcp--modify-and-save' undoes one.  The call fails instead with a
message saying that the clock was closed and whether the file holds
the close, so a client neither closes the clock a second time nor
takes it for still running."
  (condition-case err
      (org-records-mcp--maybe-save-buffer
       buf file preexisting-modified-p)
    (error
     (if (buffer-modified-p buf)
         (org-records-mcp--tool-validation-error
          "The running clock was closed but not saved: %s"
          (error-message-string err))
       (org-records-mcp--saved-then-failed-error
        "The running clock was closed and saved" err)))))

(defun org-records-mcp--clock-find-last-closed (&optional not-after)
  "Return the most recent closed-clock end time across allowed files.
Walks clock elements via `org-element-map' and picks the latest
`:value' end timestamp.  When NOT-AFTER, an Emacs time, is non-nil, a
clock ending after it is passed over, so the answer is the latest end
at or before NOT-AFTER.  Returns an Emacs time, or nil when no closed
clock qualifies."
  (let ((latest nil))
    (dolist (file (org-records-mcp--expanded-allowed-files))
      (when (file-exists-p file)
        (org-records-mcp--with-org-file file
          (org-element-map
           (org-element-parse-buffer 'element) 'clock
           (lambda (clock)
             (when (eq (org-element-property :status clock) 'closed)
               (let ((end-time
                      (org-records-mcp--clock-element-end-time
                       clock)))
                 (when (and end-time
                            (not
                             (and not-after
                                  (time-less-p not-after end-time)))
                            (or (not latest)
                                (time-less-p latest end-time)))
                   (setq latest end-time)))))))))
    latest))

(defmacro org-records-mcp--with-own-log-note (&rest body)
  "Run BODY with the log-note state bound to this call's own.
Org keeps one note in flight at a time, in one buffer and one set of
`org-log-note-*' variables: the marker saying where the entry goes,
the purpose saying what it is, the states it names.  They belong to
whoever is typing.  A user who has Org's note prompt open — from a
keyword logged with `note', or a clock-out under
`org-log-note-clock-out' — has their half-typed entry in exactly
those, and a write that set them would erase the text, send their
finishing key to the server's entry, and leave the marker nil so
that key errors instead.

Every one of them is therefore bound here, so what BODY sets up is
BODY's and the user's survives the call.  The two markers are bound
to fresh ones rather than to nil, because `org-add-log-setup' and
`org-records-mcp--insert-log-note' move them rather than assigning them, and
moving the global one is what would take the user's entry over.  They
are released on the way out: a marker left pointing into a buffer
slows every edit to it until it is collected.

`org-log-note-this-command' and `org-log-note-recursion-depth' are
among them because `org-add-log-note' compares against both before it
opens the prompt, so a write that set them would leave the user's
next command finding no note to take."
  (declare (indent 0) (debug t))
  `(let ((org-log-note-marker (make-marker))
         (org-log-note-return-to (make-marker))
         (org-log-note-purpose nil)
         (org-log-note-state nil)
         (org-log-note-previous-state nil)
         (org-log-note-extra nil)
         (org-log-note-how nil)
         (org-log-note-effective-time nil)
         (org-log-note-this-command this-command)
         (org-log-note-recursion-depth (recursion-depth))
         (org-log-note-window-configuration nil)
         (org-log-post-message nil)
         (org-note-abort nil)
         (org-log-setup nil))
     (unwind-protect
         (progn
           ,@body)
       (set-marker org-log-note-marker nil)
       (set-marker org-log-note-return-to nil))))

(defun org-records-mcp--store-log-note (note)
  "Write the log entry set up at point, with NOTE as its prose.
The `org-log-note-*' variables say what the entry is — its purpose,
the states it records, the time it happened — and
`org-store-log-note' formats and places it, honouring
`org-log-note-headings', `org-log-into-drawer' and a heading's own
`LOG_INTO_DRAWER'.  An empty NOTE writes the entry's heading line
alone, which is the entry Org writes for a setting that takes no
prose.

`org-store-log-note' takes the prose from whichever buffer is
current and kills it, so the prose goes in a buffer of this call's
own.  The interactive `org-add-log-note' uses `*Org Note*' for it,
and that one is the user's: it is where a note they are typing
lives, and erasing it to borrow it is how the text they had typed
would be lost.  Callers run inside `org-records-mcp--with-own-log-note',
which keeps the variables apart the same way.

The window configuration and the return marker are set because
`org-store-log-note' restores them when it is done and only
`org-add-log-note' would otherwise have set them."
  (move-marker org-log-note-return-to (point))
  (setq org-log-note-window-configuration
        (current-window-configuration))
  (let ((buffer (generate-new-buffer " *org-records-mcp-log-note*")))
    (unwind-protect
        (with-current-buffer buffer
          (insert note)
          (org-store-log-note))
      ;; `org-store-log-note' kills it itself; this is for the path
      ;; where it fails before reaching that.
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(defun org-records-mcp--insert-log-note
    (note purpose &optional state prev-state)
  "Insert NOTE at current heading via Org's log-note machinery.

NOTE is the user-supplied note text (may be multi-line).  An empty
NOTE writes the entry's heading line alone, which is the entry Org
writes for a purpose it takes no prose for.
PURPOSE is a symbol from `org-log-note-headings' (e.g. `note', `state').
STATE and PREV-STATE are the new and previous TODO state strings used
when PURPOSE is `state'.

This is the entry org-records-mcp decides on itself, where no Org command set
one up; `org-records-mcp--logging-note' is how an entry a command did set up
is written.  Both describe their entry inside
`org-records-mcp--with-own-log-note', so a note the user has in flight is not
what gets described."
  (org-records-mcp--with-own-log-note
    (move-marker org-log-note-marker (point))
    (setq
     org-log-note-purpose purpose
     org-log-note-state state
     org-log-note-previous-state prev-state
     org-log-note-extra nil
     org-log-note-effective-time (org-current-effective-time))
    (org-records-mcp--store-log-note note)))

(defmacro org-records-mcp--repeat-catching-up (&rest body)
  "Run BODY with Org's ten-interval question answered yes.
`org-auto-repeat-maybe' shifts a `++' date forward until it is past
today, and on the tenth shift it stops and asks a person whether to
keep going.  Inside an MCP call there is nobody to ask: in batch the
call dies reading an answer that never comes, and in the user's own
Emacs it opens a minibuffer prompt the server armed and waits at it.
That is the failure `org-records-mcp--logging-note' removed for
`org-add-log-setup', reached through a different function.

The answer is yes, and it is a decision rather than a default.  `++'
means shift forward until past today, and yes is the only answer that
carries that out; Org's question is a guard for a person who may have
mistyped a repeater, and a call has already named the heading and
asserted the state it is in, so there is no doubt here for a question
to resolve.  Refusing would fail the ordinary case instead — a
monthly task last done a year ago is twelve intervals behind — and
leave the client no recovery but rewriting the timestamp by hand.
Answering no is what Org turns into `user-error \"Abort\"', which
names nothing a client could act on.

It terminates: every shift moves the date forward by at least one
interval, and a repeater of no length never reaches the loop.

The binding is by scope and not by prompt, so it answers yes to any
question the Org command in BODY asks.  The repeater is the only one
reachable, and `org-records-mcp-test-a-write-asks-the-user-nothing' is what
keeps that true: it turns every reader Org asks with into a failure
and runs the write surface through them."
  (declare (indent 0) (debug t))
  `(cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
     ,@body))

(defmacro org-records-mcp--logging-note (note &rest body)
  "Run BODY, and write as NOTE the log entry BODY leaves Org waiting for.
Returns non-nil when BODY set such an entry up, so a caller holding a
note of its own can tell whether this entry took it.  NOTE may be nil,
which writes the entry's heading line alone.

An Org command records what a log setting asks it to record through
`org-add-log-setup', which pushes `org-add-log-note' onto the global
`post-command-hook' and returns.  Inside an MCP call there is no
command loop to run it: the entry is never written, the hook stays
armed, and the user's next unrelated command pops a note prompt for a
change the server made.  Every Org command org-records-mcp calls that can
reach `org-add-log-setup' runs inside this macro, which is what keeps
that prompt out of the user's session.

Taking the entry off the hook and writing it, rather than only
unhooking it, is what keeps the record the setting asked for:
`org-store-log-note' places it where Org would have.

A note the user has in flight comes through untouched, and it takes
all three of these to say so.  `org-records-mcp--with-own-log-note' binds the
buffer and variables their half-typed entry lives in, so BODY
describes this call's entry and not theirs.  `org-log-setup' is Org's
own flag for an entry set up and not yet written, bound to nil there
too, so what is taken off the hook is what BODY put on it.  And the
hook is left alone when `org-add-log-note' was on it before BODY ran:
Org's `add-hook' does nothing when it is already there, so removing
it would take away the user's entry rather than this call's, and
their next command would never be asked for the note they typed.

What the writing amounts to differs by caller, because it is
`org-log-note-headings' that decides whether there is an entry to
write.  `org-todo', `org-schedule', `org-deadline' and
`org-archive-subtree' set up purposes it gives a heading line to, so
an entry is written for each of them.  It gives `clock-out' an empty
heading, so a close with no NOTE has nothing to write and all this
does is take the prompt off the hook; a NOTE under that empty heading
is the whole of the entry, and a user who gives the purpose a heading
gets the prose under it, as they would from a clock-out by hand."
  (declare (indent 1) (debug (form body)))
  (let ((prose (gensym "prose"))
        (theirs (gensym "theirs")))
    `(let ((,prose (or ,note ""))
           (,theirs (memq 'org-add-log-note post-command-hook)))
       (org-records-mcp--with-own-log-note
         (unwind-protect
             (progn
               ,@body)
           ;; Take it off the hook even when BODY fails: the hook is
           ;; the user's, and a refused write that leaves it armed
           ;; pops the same prompt at their next command as one that
           ;; went through.
           (when (and org-log-setup (not ,theirs))
             (remove-hook 'post-command-hook #'org-add-log-note)))
         (when org-log-setup
           (org-records-mcp--store-log-note ,prose)
           t)))))

(defun org-records-mcp--clock-insert-entry (start &optional end)
  "Insert CLOCK line at current heading.
START is the clock start time.  END is optional clock end time.
If END is provided, inserts a closed clock entry with duration.

Placement is delegated to `org-clock-find-position', which respects
`org-clock-into-drawer' and `org-clock-drawer-name' the same way
`org-clock-in' would: a drawer (LOGBOOK or custom) is created when
configured, and CLOCK lines are inserted bare under the heading
when `org-clock-into-drawer' is nil and no drawer already exists.

Why this writes the CLOCK line by hand instead of calling
`org-clock-in' / `org-clock-out': `org-records-mcp--modify-and-save' may run
inside an existing user buffer, and those Org APIs start mode-line/idle
timers, set `org-clock-marker' and `org-clock-hd-marker', push to
`org-clock-history', and invoke `org-resolve-clocks' interactively
on dangling clocks -- all of which either leak timers, leave stale
global clock state behind, or block a non-TTY MCP server.
Formatting is delegated to Org via `org-records-mcp--clock-format-timestamp'
and `org-records-mcp--clock-duration-string', and the `CLOCK:' prefix uses
`org-clock-string' so the wire format tracks Org's own constant."
  (org-back-to-heading t)
  (org-clock-find-position nil)
  (if end
      (let* ((duration (float-time (time-subtract end start)))
             ;; `org-clock-out' writes the duration as `%2d:%02d', so
             ;; an hour count below ten is padded to two columns.  Org
             ;; exposes no helper for that padding, so mirror it here
             ;; and keep every closed CLOCK line of a file alike,
             ;; whichever writer made it.
             (dur-str
              (format "%5s"
                      (org-records-mcp--clock-duration-string
                       duration))))
        (insert
         (format "%s %s--%s => %s\n"
                 org-clock-string
                 (org-records-mcp--clock-format-timestamp start)
                 (org-records-mcp--clock-format-timestamp end)
                 dur-str)))
    (insert
     (format "%s %s\n"
             org-clock-string
             (org-records-mcp--clock-format-timestamp start)))))

(defun org-records-mcp--clock-resolve-dangling ()
  "Delete the unclosed CLOCK entries of the entry at point.
Point must be at a heading.  The search is bounded by
`org-entry-end-position', so it covers that heading's own entry and
not its subtree: a dangling CLOCK line under a descendant is that
descendant's, named by a link of its own, and a call naming an
ancestor is not the one entitled to cancel it.  The same bound holds
the clock lookups in `org-records-mcp--clock-entries-starting-at', and it is
the one `org-clock-find-position' places a new CLOCK line within.

Open clocks are discovered via `org-element-map', then each deletion
is delegated to Org's `org-clock-clock-cancel', which removes the
CLOCK line and collapses the containing drawer when it becomes
empty via `org-remove-empty-drawer-at'.  Returns count of deleted
entries, which is therefore a count for that heading alone.

`org-find-open-clocks' is deliberately not used here because another
buffer may already be visiting the same file (e.g. the buffer opened
earlier by `org-records-mcp--clock-find-active'). That API returns markers in
whichever buffer `get-file-buffer' finds first, which is not guaranteed
to be the buffer currently being edited. Element-map on the current
buffer guarantees the markers we operate on."
  (org-back-to-heading t)
  (let* ((entry-begin (point))
         (entry-end (org-entry-end-position))
         (clocks nil)
         (count 0))
    (save-restriction
      (narrow-to-region entry-begin entry-end)
      (org-element-map
       (org-element-parse-buffer 'element) 'clock
       (lambda (el)
         (when (eq (org-element-property :status el) 'running)
           ;; Build a (marker . start-time) cons matching the shape
           ;; `org-clock-clock-cancel' expects: marker positioned at
           ;; end-of-line of `CLOCK: [...]' so that
           ;; `org-clock-cancel's `looking-back' succeeds.
           (save-excursion
             (goto-char (org-element-property :begin el))
             (end-of-line)
             (push (cons
                    (copy-marker (point) t)
                    (org-records-mcp--clock-element-start-time el))
                   clocks))))))
    (dolist (clock clocks)
      (org-clock-clock-cancel clock)
      (cl-incf count))
    count))

(defun org-records-mcp--clock-remove-empty-logbook ()
  "Remove the clock drawer of the entry at point if it is empty.
Point must be at a heading.  The heading's own entry is swept and its
subtree is not, so a descendant's drawer is left to the call that
names that descendant; `org-records-mcp--clock-entries-starting-at' bounds
the clocks themselves the same way.  The drawer name comes from
`org-clock-drawer-name', which respects `org-clock-into-drawer'
(returns nil when clocks are not placed in a drawer; in that case
there is nothing to clean up).  When a custom drawer name is
configured we also sweep the legacy `LOGBOOK' name so previously
captured clocks are tidied alongside new ones.  Delegates to
`org-remove-empty-drawer-at', which is a no-op when the drawer has
any contents (additional CLOCK entries, state notes, plain notes,
etc.)."
  (save-excursion
    (org-back-to-heading t)
    (let* ((entry-begin (point))
           (entry-end (org-entry-end-position))
           (configured (org-clock-drawer-name))
           (names
            (delete-dups (delq nil (list configured "LOGBOOK")))))
      (save-restriction
        (narrow-to-region entry-begin entry-end)
        (dolist (name names)
          (let ((drawer-pos
                 (org-element-map
                  (org-element-parse-buffer 'element) 'drawer
                  (lambda (el)
                    (when (equal
                           (org-element-property
                            :drawer-name el)
                           name)
                      (org-element-property :begin el)))
                  nil t)))
            (when drawer-pos
              (org-remove-empty-drawer-at drawer-pos))))))))

(defun org-records-mcp--clock-entries-matching (predicate)
  "Return the CLOCK elements of the heading at point PREDICATE keeps.
Point must be at a heading and is not moved.  PREDICATE is called with
one CLOCK element at a time, and every element it keeps comes back, in
the order they are written.

The search is bounded by `org-entry-end-position', so it covers that
heading's own entry and not its subtree.  A CLOCK line under a
descendant is that descendant's, named by a link of its own, and a
call naming an ancestor is not the one entitled to destroy it.  That
bound is one fact about which lines are this heading's, so it is
asked in one place and every question about them is put through
here."
  (save-excursion
    (org-back-to-heading t)
    (let ((entry-begin (point))
          (entry-end (org-entry-end-position)))
      (save-restriction
        (narrow-to-region entry-begin entry-end)
        (org-element-map
         (org-element-parse-buffer 'element)
         'clock
         (lambda (clock) (and (funcall predicate clock) clock)))))))

(defun org-records-mcp--clock-entries-starting-at (start-time)
  "Return the CLOCK elements of the heading at point starting at START-TIME.
Point must be at a heading and is not moved.  START-TIME is an Emacs
time value.

Several CLOCK lines may share a start, so every match comes back, in
the order they are written; what an ambiguous START-TIME means is the
caller's to decide."
  (let ((target (float-time start-time)))
    (org-records-mcp--clock-entries-matching
     (lambda (clock)
       (=
        (float-time (org-records-mcp--clock-element-start-time clock))
        target)))))

(defun org-records-mcp--clock-closed-ends (start)
  "Return the end times of the heading's closed CLOCK lines at START.
Point must be at a heading and is not moved."
  (delq
   nil
   (mapcar
    #'org-records-mcp--clock-element-end-time
    (org-records-mcp--clock-entries-starting-at start))))

(defun org-records-mcp--clock-end-added (before after)
  "Return the one time in AFTER that BEFORE does not account for.
BEFORE and AFTER are lists of end times read on either side of a
write, and one time may appear in either more than once, so they are
compared as multisets rather than as sets.

Nil when AFTER adds none, and nil when it adds more than one: only
one clock runs at a time, so a second addition is not this call's to
claim, and saying nothing is the honest answer where saying which
would be a guess.

A matched time is dropped with `delq', which goes by identity, and
what it drops is the element `seq-find' has just returned, so one
match consumes one entry.  That is what keeps the comparison a
multiset where a list holds one instant twice: two such entries are
separate objects, `eq' between them being nil where `time-equal-p' is
t.  Times interned so that equal ones were one object would break
it, dropping both entries for one match and inventing an addition."
  (let ((unmatched (copy-sequence before))
        (added nil))
    (dolist (end after)
      (let ((seen
             (seq-find
              (lambda (time) (time-equal-p time end)) unmatched)))
        (if seen
            (setq unmatched (delq seen unmatched))
          (push end added))))
    (and (null (cdr added)) (car added))))

(defun org-records-mcp--clock-open-reading ()
  "Return what will find again the clock running in the heading at point.
Nil when no CLOCK line of the heading is open.  Otherwise a cons of
that line's start and the end times of the lines already closed at
the same start.  Point must be at a heading and is not moved.

A start does not name a CLOCK line.  `org-clock-rounding-minutes'
makes two lines of one heading beginning together ordinary, which is
why `org-clock-delete' refuses a start that names two.  So the
reading carries what was already closed there, and the line this call
closed is the one that reading cannot account for; see
`org-records-mcp--clock-closed-moves'."
  (when-let* ((open
               (org-records-mcp--clock-entries-matching
                (lambda (clock)
                  (eq
                   (org-element-property :status clock) 'running))))
              (start
               (org-records-mcp--clock-element-start-time
                (car open))))
    (cons start (org-records-mcp--clock-closed-ends start))))

(defun org-records-mcp--clock-closed-moves (reading)
  "Return the response field for the clock READING the call closed, or nil.
READING is `org-records-mcp--clock-open-reading' taken before the write, and
nil when no clock was running in the heading, which is most calls.
Point must be at the heading and is not moved.

The field is there only when this call closed that clock, so its
presence is the statement — the shape `org-records-mcp--planning-moves' uses
for a planning field a call moved without being asked to.  It reports
what `org-clock-out' reports, because a client that was clocking the
task it has just finished is owed what the call it did not have to
make would have told it.

The line is identified by being closed now and not then, never by its
start.  Reading the start alone would report a line closed long
before the call whenever one began at the same minute, and would
report a close on a keyword that closed nothing at all, which is the
statement the field's absence is supposed to make."
  (when-let* ((reading)
              (start (car reading))
              (end
               (org-records-mcp--clock-end-added
                (cdr reading)
                (org-records-mcp--clock-closed-ends start))))
    `((clock
       (start
        . ,(org-records-mcp--clock-format-timestamp start))
       (end . ,(org-records-mcp--clock-format-timestamp end))
       (duration
        .
        ,(org-records-mcp--clock-duration-string
          (float-time (time-subtract end start))))))))

(defun org-records-mcp--clock-describe-ends (clocks)
  "Describe CLOCKS by the ends that tell entries of one start apart.
CLOCKS is the ambiguous set, so it holds two or more.  Each becomes
\"one ending TIMESTAMP\", or \"one still open\" where it has no end
yet, and the clauses are joined as an English list, so whoever opens
the file can pick out the entry meant."
  (let ((clauses
         (mapcar
          (lambda (clock)
            (let ((end
                   (org-records-mcp--clock-element-end-time clock)))
              (if end
                  (format "one ending %s"
                          (org-records-mcp--clock-format-timestamp
                           end))
                "one still open")))
          clocks)))
    (format "%s and %s"
            (mapconcat #'identity (butlast clauses) ", ")
            (car (last clauses)))))

(defun org-records-mcp--clock-delete-entry (start-time)
  "Delete the CLOCK entry starting at START-TIME from the heading at point.
Point must be at a heading and is left there, so the response links
the heading whose CLOCK line went.  START-TIME is an Emacs time
value.  Only that heading's own entry is searched, see
`org-records-mcp--clock-entries-starting-at'; the LOGBOOK drawer goes if the
deletion empties it.  Returns an alist describing the entry deleted,
or nil when the entry holds none starting there.

Two entries of one start are refused rather than resolved.  START-TIME
is the whole of what names the entry, so neither reading the heading
again nor sending the call again picks one of them out, and deleting
whichever comes first destroys a clock the caller may never have
seen.  `org-clock-rounding-minutes' makes that ordinary rather than
exotic: it writes two distinct starts as one time.  The refusal names
both entries by their ends, for whoever can open the file and delete
the one meant, which is the `blocked:' class."
  (org-back-to-heading t)
  (pcase (org-records-mcp--clock-entries-starting-at start-time)
    ('nil nil)
    (`(,match)
     (let* ((begin (org-element-property :begin match))
            (end (org-element-property :end match))
            (end-time (org-records-mcp--clock-element-end-time match))
            (duration (org-element-property :duration match))
            (found
             `((start
                .
                ,(org-records-mcp--clock-format-timestamp start-time))
               ,@
               (when end-time
                 `((end
                    .
                    ,(org-records-mcp--clock-format-timestamp
                      end-time))))
               ,@
               (when duration
                 `((duration . ,duration))))))
       (delete-region begin end)
       (org-records-mcp--clock-remove-empty-logbook)
       found))
    (matches
     (org-records-mcp--tool-blocked-error
      "%d clock entries on this heading start at %s: %s.  start \
names no one of them, so delete the one you mean in Emacs"
      (length matches)
      (org-records-mcp--clock-format-timestamp start-time)
      (org-records-mcp--clock-describe-ends matches)))))

(defun org-records-mcp--file-todo-sequences ()
  "Return the TODO sequences the current buffer's own settings name.
The value has the shape of `org-todo-keywords': each element pairs a
sequence type with that sequence's keywords, every keyword in the raw
form the file wrote it in, and the `\"|\"' where the file put one.  A
file naming no sequence of its own answers nil, and its keywords are
the global ones.

The settings are read with `org-collect-keywords' and assembled the
way `org-set-regexps-and-options' assembles them, which is what makes
the answer the one Org itself reached: that call follows a
`#+SETUPFILE:', and `#+TYP_TODO:' comes before `#+TODO:' and
`#+SEQ_TODO:' there as it does here.

The settings are read rather than the buffer-local variables Org
derives from them because those variables answer a different
question.  `org-todo-keywords-1' drops each keyword's fast-access key
and logging directives, and `org-todo-key-alist' carries a key for
every keyword, the ones `org-assign-fast-keys' invented for a
sequence that named none included.  The lines carry what the file
says, which is what this tool reports."
  (let ((alist
         (org-collect-keywords '("SEQ_TODO" "TODO" "TYP_TODO"))))
    (append
     (mapcar
      (lambda (value) (cons 'type (split-string value)))
      (cdr (assoc "TYP_TODO" alist)))
     (mapcar
      (lambda (value) (cons 'sequence (split-string value)))
      (append
       (cdr (assoc "TODO" alist)) (cdr (assoc "SEQ_TODO" alist)))))))

(defun org-records-mcp--validate-todo-state (state)
  "Validate STATE is a valid TODO keyword.
Reads the buffer-local `org-todo-keywords-1', which Org populates
from the user customization merged with any per-file `#+TODO:'
directives.  Must be called from within an Org-mode buffer (e.g.
inside `org-records-mcp--modify-and-save').

Every STATE reaching here is a keyword the call asks for, so \"\" is
refused like any other text that names no keyword: a heading with no
keyword is asked for with null, which never reaches this."
  (unless (member state org-todo-keywords-1)
    (org-records-mcp--tool-validation-error
     "Invalid TODO state: '%s' - valid states: %s, or null for \
no keyword"
     state (mapconcat #'identity org-todo-keywords-1 ", "))))

(defun org-records-mcp--todo-null-text (state)
  "Return STATE, the TODO keyword a call asks for, with the text null read.
The text null is null, the keyword taken away, unless the current
buffer\\='s `org-todo-keywords-1' holds a keyword spelled null: there
the text names a state the file configures, and it stays that
keyword.  JSON null still takes the keyword away in such a file, so
only a client that cannot send null loses anything, and what it
loses is a removal in the one file that chose that spelling, never a
keyword.  Any other STATE is returned as it came.

This is `org-records-mcp--value-to-write' reading the text, deferred to
where the file is known, and it runs in the target buffer for the
reason `org-records-mcp--validate-todo-state' does."
  (if (and (org-records-mcp--null-text-p state)
           (not (member state org-todo-keywords-1)))
      nil
    state))

(defun org-records-mcp--todo-block-reason (from to)
  "Return what Org names for vetoing the change FROM to TO, or nil.
Point is on the heading.  FROM is its TODO keyword, or nil when it
has none; TO is the keyword the call asks for.  A non-nil result
means Org refuses the change: the blocker it names, as a string, or
t when it names none.

`org-todo' runs `org-blocker-hook' itself, but called from Lisp it
reports a veto only by leaving the entry alone and writing a
message, which no caller can read.  The hook is therefore asked here
first, with the change plist `org-todo' builds and under the same
`org-inhibit-blocking' and `NOBLOCKING' exemptions, so that the veto
is known before anything is written.  Org has no function that
answers for one named transition: `org-entry-blocked-p' asks only
whether the entry may be finished.  `org-todo' asks the hook again
for a change that goes through, which is why the hook is a predicate
and not a place for side effects."
  (when (and org-blocker-hook
             (not org-inhibit-blocking)
             (not (org-entry-get nil "NOBLOCKING")))
    (let ((org-blocked-by-checkboxes nil)
          (position
           (save-excursion
             (org-back-to-heading t)
             (point))))
      (unless (save-excursion
                (save-match-data
                  (org-with-wide-buffer
                   (run-hook-with-args-until-failure
                    'org-blocker-hook
                    (list
                     :type 'todo-state-change
                     :from from
                     :to to
                     :position position)))))
        (cond
         (org-blocked-by-checkboxes
          "contained checkboxes")
         ((org-string-nw-p org-block-entry-blocking)
          (format "\"%s\"" org-block-entry-blocking))
         (t
          t))))))

(defun org-records-mcp--set-todo-state (state &optional note)
  "Set the TODO state of the heading at point to STATE, recording NOTE.
STATE is the keyword to write, or nil to leave the heading with none,
so that it stops being a task.
Returns the state Org left the heading in, which is read back rather
than assumed: `org-auto-repeat-maybe' resets a repeating entry moved
to a done keyword to its not-done keyword, and `REPEAT_TO_STATE'
picks which one.

A change Org vetoes -- a TODO dependency, an unchecked checkbox, an
ordered subtree -- is refused before anything is written, so the
heading keeps the state it had and the caller saves nothing.  The
refusal carries Org's own reason for it where Org names one.

NOTE is prose to record with the change, or nil for none.  `org-todo'
reaches a log entry two ways -- `org-log-done' and
`org-todo-log-states' directly, `org-log-repeat' through
`org-auto-repeat-maybe' -- and where it does, NOTE becomes that
entry's prose, so one transition leaves one record under the heading
line Org chose for it.  Where no setting asks for an entry, a NOTE is
still recorded, as the state change org-records-mcp writes of its own accord."
  (let ((previous (org-get-todo-state)))
    (when-let* ((blocker
                 (org-records-mcp--todo-block-reason previous state)))
      (org-records-mcp--tool-blocked-error
       "TODO state change from %s to %s blocked%s"
       (or previous "(no state)")
       (or state "(no state)")
       (if (stringp blocker)
           (format " (by %s)" blocker)
         "")))
    (unless (org-records-mcp--logging-note note
              ;; `org-todo' cycles to the next keyword when its
              ;; argument is nil, so the ask for no keyword is spelled
              ;; as the `none' Org names it, never as a missing one.
              (org-records-mcp--repeat-catching-up
                (org-todo (or state 'none))))
      (when (org-string-nw-p note)
        (org-records-mcp--insert-log-note note 'state
                                          (or state "")
                                          (or previous ""))))
    ;; Read back through the accessor an assertion compares against,
    ;; so the state this response reports is one the client can send
    ;; straight back as the next call's `before'.
    (org-records-mcp--asserted-value :todo)))

(defun org-records-mcp--mutex-tag-groups (alist)
  "Return mutex tag groups from ALIST as a list of lists of tag strings.
A mutex group is delimited by `:startgroup' / `:endgroup' tokens.

Org's `org-tag-alist-to-groups' covers only the grouptag form
\(`:startgrouptag' / `:grouptags' / `:endgrouptag'); it does not
expose mutex (`:startgroup' / `:endgroup') groups, and Org has no
other public API that does.  Revisit if Org gains one."
  (let (groups
        current
        in-group)
    (dolist (entry alist)
      (let ((token
             (if (consp entry)
                 (car entry)
               entry)))
        (cond
         ((eq token :startgroup)
          (setq
           in-group t
           current nil))
         ((eq token :endgroup)
          (when (and in-group current)
            (push (nreverse current) groups))
          (setq
           in-group nil
           current nil))
         ((and in-group (stringp token))
          (push token current)))))
    (nreverse groups)))

(defun org-records-mcp--validate-tag-names (tags)
  "Refuse any of TAGS that Org could not write as a tag.  Returns TAGS.
Org permits free-form tags in headlines, so the test is `org-tag-re'
and nothing else: a name is not required to appear in
`org-tag-alist' or `org-tag-persistent-alist'.

This is the whole of what a call naming tags to take away has to
pass.  Mutual exclusivity is a rule about the tags a heading ends up
carrying, and a call that only removes tags cannot break it — two
tags from one group can always be removed together."
  (let ((tag-name-re (concat "\\`" org-tag-re "\\'")))
    (dolist (tag tags)
      (unless (string-match-p tag-name-re tag)
        (org-records-mcp--tool-validation-error "Invalid tag name: %s"
                                                tag))))
  tags)

(defun org-records-mcp--validate-and-normalize-tags (tags)
  "Validate and normalize TAGS.
TAGS can be a single tag string or list of tag strings.
Returns normalized tag list.

Org permits free-form tags in headlines, so any name matching
`org-tag-re' is accepted regardless of whether it appears in
`org-tag-alist' or `org-tag-persistent-alist'.  Mutual-exclusivity
groups (`:startgroup' / `:endgroup') in those alists are still
enforced because they express a conflict, not an allow-list.  They
are enforced over the tags the call names, not over the tags the
heading ends up with: a heading whose tags already break a group was
not written here, and refusing an unrelated call because of it
reports a conflict the caller did not cause."
  (let ((tag-list (org-records-mcp--normalize-tags-to-list tags)))
    (org-records-mcp--validate-tag-names tag-list)
    (when org-tag-alist
      (org-records-mcp--validate-mutex-tag-groups
       tag-list org-tag-alist))
    (when org-tag-persistent-alist
      (org-records-mcp--validate-mutex-tag-groups
       tag-list org-tag-persistent-alist))
    tag-list))

(defun org-records-mcp--validate-mutex-tag-groups (tags tag-alist)
  "Validate that TAGS don't violate mutex groups in TAG-ALIST.
TAGS is a list of tag strings.
Errors if multiple tags from same mutex group."
  (dolist (group (org-records-mcp--mutex-tag-groups tag-alist))
    (let ((conflict (cl-intersection tags group :test #'string=)))
      (when (> (length conflict) 1)
        (org-records-mcp--tool-validation-error
         "Tags %s are mutually exclusive (cannot use together)"
         (mapconcat (lambda (tag) (format "'%s'" tag)) conflict
                    ", "))))))

(defun org-records-mcp--headline-grammar-settings ()
  "Return the current buffer's headline grammar as `#+' setting lines.
A headline's grammar is decided by which words the file names as TODO
keywords and which characters its priority bounds admit, and a
`#+TODO:' or `#+PRIORITIES:' line moves either.  A check made in a
scratch buffer therefore has to be given them, or it answers for the
session instead of for the file being written to.

The lines are rebuilt from the values Org derived rather than copied
out of the file: the grammar asks only which words are keywords and
which characters are priorities, and one sequence carrying every
keyword answers that exactly as several sequences do.  A file naming
no keywords contributes no line, and Org's own defaults stand."
  (concat
   (when org-todo-keywords-1
     (let ((not-done
            (seq-remove
             (lambda (keyword)
               (member keyword org-done-keywords))
             org-todo-keywords-1)))
       (format "#+TODO: %s | %s\n"
               (string-join not-done " ")
               (string-join org-done-keywords " "))))
   (format "#+PRIORITIES: %c %c %c\n"
           org-priority-highest
           org-priority-lowest
           org-priority-default)))

(defun org-records-mcp--title-claimed-by-org (title)
  "Return what Org's headline grammar claims of TITLE, or nil.
The result is a clause naming what the heading would carry instead of
the title, for a refusal to finish.

A title is written raw into the headline line, and that line has a
grammar: a trailing `:word:' is tags, a leading `org-comment-string'
comments the heading out of export and the agenda, a leading keyword
is the TODO state and a leading `[#A]' is the priority.  Each of them
takes its part of the title away, and `org-heading-components' then
reports a title the call never asked for while the response says the
write succeeded.

So the line is built and Org is asked what it made of it, rather than
a regexp being written for each shape.  That is the whole of the
check: `org-tag-line-re' and `org-comment-string' are not restated
here because the parser that uses them answers directly, and a shape
nobody has named yet is caught by the last clause, which asks only
whether the title came back whole.

The line is built without a TODO keyword or a priority of its own, so
what claims those positions is the title's own text.

Which words are keywords and which characters are priorities is the
target file's answer, not the session's, so this runs with that
buffer current and carries its settings into the scratch buffer it
builds the line in; see `org-records-mcp--headline-grammar-settings'."
  (let ((settings (org-records-mcp--headline-grammar-settings)))
    (with-temp-buffer
      (let ((org-inhibit-startup t))
        (delay-mode-hooks
          (org-mode)))
      (insert settings)
      ;; Org derives the headline regexps from the lines just
      ;; inserted, as it does for a file it opens, so the grammar here
      ;; is the grammar there.
      (org-set-regexps-and-options)
      (let ((heading (point)))
        (insert "* " title "\n")
        (goto-char heading))
      (let* ((components (org-heading-components))
             (keyword (nth 2 components))
             (priority (nth 3 components))
             (parsed (nth 4 components)))
        (cond
         ((org-in-commented-heading-p)
          "would comment the heading out of export and the agenda")
         ((org-get-tags)
          (format "would become tags, leaving the title %S" parsed))
         (keyword
          (format
           "would become the TODO keyword %s, leaving the title %S"
           keyword parsed))
         (priority
          (format "would become the priority %c, leaving the title %S"
                  priority
                  parsed))
         ((not (equal parsed title))
          (format "would be read as the title %S" parsed)))))))

(defun org-records-mcp--validate-title-text (title)
  "Refuse TITLE unless it is text that could name a heading.
Throws an MCP tool error if it is not.

Nothing asked here depends on the file the title is going into, so
this runs before one is opened and a refusal reads nothing and
touches nothing.  Whether Org\\='s headline grammar would claim part of
the title is the file\\='s own answer and is asked later, by
`org-records-mcp--validate-title-grammar'.

A title has to be non-empty and hold no newline \u2014 one would make a
second line, and the headline is one line.  It also has to survive
the normalization every read and every precondition sees it through,
`org-link--normalize-string', with something left: that is what
`org-records-mcp--title-at-point' reports a heading as, and what a
`::*title' link matches against.  A statistics cookie is the case
that arises \u2014 Org takes one out of a heading, so `[0/0]' is a whole
title that reads as none, and the heading it would make has nothing
to address it by."
  (when (or (string-empty-p title)
            (string-match-p "^[[:space:]]*$" title)
            ;; Explicitly match NBSP for Emacs 27.2 compatibility
            ;; In Emacs 27.2, [[:space:]] doesn't match NBSP (U+00A0)
            (string-match-p "^[\u00A0]*$" title))
    (org-records-mcp--tool-validation-error
     "Title cannot be empty or contain only whitespace"))
  (when (string-match-p "[\n\r]" title)
    (org-records-mcp--tool-validation-error
     "Title cannot contain newlines"))
  (when (string-empty-p (org-link--normalize-string title))
    (org-records-mcp--tool-validation-error
     "Title reads as nothing: '%s'.  Org takes a \
statistics cookie out of a heading, so nothing would be left to \
name it by"
     title)))

(defun org-records-mcp--validate-title-grammar (title)
  "Refuse TITLE unless Org would keep the whole of it as a title.
Throws an MCP tool error if it would not.

Runs with the target buffer current, because which words are TODO
keywords and which characters are priorities is that file\\='s answer;
`org-records-mcp--title-claimed-by-org' asks it there.

A title Org would claim is refused rather than escaped.  Escaping
would let a call name a heading anything, at the cost of the file
holding something other than what was sent and a read handing back
something other than what was asked for, which is the failure this
refusal exists to prevent.  The refusal names what Org would make of
the title instead, so the client can spell that part another way: a
tag belongs in `org-node-add-tags', a TODO keyword in the call's own
`todo' or in `org-node-set-todo', a priority in
`org-node-set-priority', and the rest is reworded."
  (when-let* ((claimed (org-records-mcp--title-claimed-by-org title)))
    (org-records-mcp--tool-validation-error
     "Not a title: '%s'.  It %s"
     title claimed)))

(defun org-records-mcp--timestamp-parsed (date-str)
  "Return DATE-STR parsed by Org as a timestamp element, or nil.
Org reads a timestamp between brackets, so a bare `2026-03-27' is
offered to it wrapped in the active brackets Org writes it with.

The parse has to account for the whole of DATE-STR.  Org reads one
timestamp and stops, so text beside one would be dropped without
ever reaching the file, and a value carrying it names no timestamp."
  (let* ((wrapped (concat "<" date-str ">"))
         (bracketed (org-timestamp-from-string date-str))
         (source
          (if bracketed
              date-str
            wrapped))
         (timestamp
          (or bracketed (org-timestamp-from-string wrapped))))
    (and timestamp
         (equal (org-element-property :raw-value timestamp) source)
         timestamp)))

(defconst org-records-mcp--timestamp-moment
  '(:year-start :month-start :day-start :hour-start :minute-start)
  "The element properties saying which moment a timestamp names.
Two timestamps carrying the same values here name the same moment,
whatever repeater, warning period or day name they are written
with.")

(defun org-records-mcp--timestamp-parts (timestamp properties)
  "Return the PROPERTIES of TIMESTAMP, as a list to compare by."
  (mapcar
   (lambda (property)
     (org-element-property property timestamp))
   properties))

(defconst org-records-mcp--timestamp-day-name-re
  "\\`[^]+0-9>\r\n -]+\\'"
  "What Org\\='s timestamp grammar lets stand in the day-name slot.
`org-ts-regexp0' gives the day name a group of its own, matching a
run of characters carrying no digit, no sign and no bracket.  Org
reads nothing out of that group \u2014 the day it writes is the day the
date falls on \u2014 so a word standing there is not one a call loses by
sending it.")

(defun org-records-mcp--timestamp-unread-words (timestamp rendered)
  "Return the words of TIMESTAMP Org read past, or nil.
RENDERED is `org-element-interpret-data' on TIMESTAMP: what Org
writes for it, carrying the parts Org read and nothing else.

Org\\='s parser reads a timestamp\\='s parts and reads past whatever else
stands between them, keeping none of it.  A word the call sent and
Org dropped is therefore in the raw string and in no property of the
element, and which words those are has to be asked of the raw
string: each word is taken out in turn, and one whose absence leaves
the rendering as it was is a word Org read nothing from.  A word Org
did read cannot go without the rendering going with it.  That asks
Org\\='s own parser which words carried meaning, rather than reading
its timestamp grammar a second time here.  Each word is asked in its
own right, because a word Org reads past stands anywhere between the
brackets: a repeater typed wrong stands before the repeater it was
meant to be, not after everything.

A word is taken out of what the words before it were found to carry,
so where Org reads one thing out of two words — the second repeater
of `<2026-03-27 Fri +1w +2w>', which Org reads past — the one it
read nothing from is the one named.

The word after the date is exempt.  It stands in the day-name slot
`org-records-mcp--timestamp-day-name-re' describes, and Org writes the day
the date falls on whatever that slot holds, so the call loses no
date by putting something else there."
  (let* ((raw (org-element-property :raw-value timestamp))
         (words (split-string (substring raw 1 -1) nil t))
         (from
          (if (and (cdr words)
                   (string-match-p
                    org-records-mcp--timestamp-day-name-re
                    (nth 1 words)))
              2
            1))
         (kept (cl-subseq words 0 (min from (length words))))
         (unread nil))
    (dolist (n (number-sequence from (1- (length words))))
      (let* ((word (nth n words))
             (without (append kept (nthcdr (1+ n) words)))
             (head
              (org-records-mcp--timestamp-parsed
               (format "<%s>" (string-join without " ")))))
        (if (and head
                 (equal (org-element-interpret-data head) rendered))
            (push word unread)
          (setq kept (append kept (list word))))))
    (nreverse unread)))

(defun org-records-mcp--timestamp-moment-rendered (timestamp)
  "Return TIMESTAMP rendered as the moment it names and nothing else.
The date and the time of day are TIMESTAMP\\='s own; a repeater and a
warning period are left out.  TIMESTAMP is left as it was found.

This is the value a refusal names when what it is refusing is the
moment, and it is a timestamp this surface takes whatever TIMESTAMP
carried: it is Org\\='s own reading, so the day exists; its year is
TIMESTAMP\\='s, which a refusal about the moment is only reached with
once the year has been found readable; it is one active timestamp,
so it is neither inactive nor a range; Org rendered it, so there is
no word in it Org reads past; and it carries neither of the two
things whose pairing is refused.  Naming the whole of what Org read
instead would hand back a repeater and a delay the next refusal
rejects, on a date the call did not ask for."
  (let ((copy (org-element-copy timestamp)))
    (dolist (property
             '(:repeater-type
               :repeater-value
               :repeater-unit
               :warning-type
               :warning-value
               :warning-unit))
      (org-element-put-property copy property nil))
    (org-element-interpret-data copy)))

(defun org-records-mcp--timestamp-warning-retyped (timestamp type)
  "Return TIMESTAMP rendered with its warning period set to TYPE.
TYPE is `all', the warning that fires before every repeat, or nil
for no warning period at all.  The number and the unit are
TIMESTAMP\\='s own either way, so what comes back differs from
TIMESTAMP\\='s own rendering in the warning alone.  TIMESTAMP is left
as it was found.

Org spells a warning type in the hyphens before the period and
renders a timestamp from the element\\='s properties, so retyping a
copy and asking Org to render it is asking Org how the retyped form
is written, rather than spelling a timestamp out here."
  (let ((copy (org-element-copy timestamp)))
    (org-element-put-property copy :warning-type type)
    (unless type
      (org-element-put-property copy :warning-value nil)
      (org-element-put-property copy :warning-unit nil))
    (org-element-interpret-data copy)))

(defun org-records-mcp--date-normalized (date-str)
  "Return DATE-STR as the Org timestamp string to write.
Throws an MCP tool error when Org will not carry DATE-STR to the
file as it was sent.

Org\\='s own parser decides what a timestamp is, so a write takes the
vocabulary a read speaks: the shorthand `2026-03-27' and
`2026-03-27 09:00', a repeater, a warning period, and the raw string
a read returns, brackets and all.  There is no second definition of
a timestamp here to drift from Org\\='s.

Six things Org parses are refused, because writing them would put
something other than what the call sent into the file:

- a date whose fields name no day — `2026-02-30', `2026-13-45',
  `2026-03-27 25:99' — which Org rolls on to a day nobody asked for;
- a year below 100, which Org\\='s date reader reads as a two-digit
  year and answers with another century;
- an inactive timestamp, which a planning line does not carry;
- a date range — two timestamps joined by `--' — whose second half
  Org\\='s planning writer drops, however close the two fall;
- a first-only warning delay standing beside a repeater — the
  `--3d' of `<2026-03-27 Fri +1w --3d>' — which Org's planning
  writer takes off, writing the repeater by itself;
- text Org reads past — the `typo' of
  `<2026-03-27 Fri 09:00 +1w typo>' — which never reaches the file,
  so the call would be answered with the repeater it asked for and
  none of the word it got wrong.  This one is asked last of all, so
  the timestamp its message names is one every other check has
  passed.

Two forms carrying a doubled hyphen are not ranges.  A span of the
day, `2026-03-27 09:00-10:00', lives inside the one timestamp and
Org carries the whole of it, backwards hours and all, so it is
written.  A first-only warning delay, `--3d' against the `-3d' that
warns before every repeat, is Org\\='s own spelling and goes in as
sent while it stands alone; what it costs beside a repeater is the
fifth refusal above.

The day name is read past and not refused, because the day Org
writes is the day the date falls on and no date is lost by whatever
stands there; see `org-records-mcp--timestamp-day-name-re'.

The value returned is Org\\='s own rendering of what it parsed, the
form `org-schedule' and `org-deadline' carry through whole; see
`org-records-mcp--write-planning-timestamp'."
  (let ((timestamp (org-records-mcp--timestamp-parsed date-str)))
    (unless timestamp
      (org-records-mcp--tool-validation-error
       "Invalid date '%s' - expected 2026-03-27, 2026-03-27 09:00, \
an Org timestamp such as <2026-06-20 Sat +1w -3d>, or null for no \
date"
       date-str))
    (when (memq
           (org-element-property :type timestamp)
           '(inactive inactive-range))
      (org-records-mcp--tool-validation-error
       "Date '%s' is an inactive timestamp - SCHEDULED and DEADLINE \
carry an active one, written <...>"
       date-str))
    (let ((raw (org-element-property :raw-value timestamp))
          (rendered (org-element-interpret-data timestamp)))
      ;; A `--' is not a range by itself.  Between two bracketed
      ;; timestamps it is the range separator `org-tr-regexp-both'
      ;; reads, and Org's planning writer keeps the first half of
      ;; such a range however close the halves fall — one inside a
      ;; single day is cut as surely as one across a month.  After a
      ;; date it is the first-only warning delay, `--3d' against the
      ;; `-3d' that warns before every repeat, which is no range at
      ;; all; what it costs beside a repeater is settled below.
      ;; Inside one pair of brackets the separator is neither: Org's
      ;; parser reads up to it and stops, so the rendering comes back
      ;; without it, and that is what tells the two apart here rather
      ;; than a second reading of Org's timestamp syntax.
      (when (or (string-match-p org-tr-regexp-both raw)
                (and (string-search "--" raw)
                     (not (string-search "--" rendered))))
        (org-records-mcp--tool-validation-error
         "Date '%s' is a date range - name the one date the field is \
to carry"
         date-str))
      ;; `org-small-year-to-year' is the reading Org's date reader
      ;; applies, so the year it leaves alone is the year that
      ;; reaches the file.
      (let ((year (org-element-property :year-start timestamp)))
        (unless (= year (org-small-year-to-year year))
          (org-records-mcp--tool-validation-error
           "Date '%s' has a year below 100, which Org reads as a \
two-digit year"
           date-str)))
      ;; Org's parser reads the fields as written; its writer
      ;; resolves them against the calendar.  A day that does not
      ;; exist is one the two disagree about, and Org's answer is the
      ;; day the write would otherwise have landed on.
      ;;
      ;; What the message names is that day and the time on it, not
      ;; the whole of what Org read: this refusal is about the
      ;; moment, and a moment on its own is a timestamp this surface
      ;; takes, while the whole would carry a repeater and a delay
      ;; whose pairing the refusal below rejects.  See
      ;; `org-records-mcp--timestamp-moment-rendered'.
      (unless (equal
               (org-records-mcp--timestamp-parts
                timestamp org-records-mcp--timestamp-moment)
               (org-records-mcp--timestamp-parts
                (org-records-mcp--timestamp-parsed rendered)
                org-records-mcp--timestamp-moment))
        (org-records-mcp--tool-validation-error
         "Date '%s' does not exist - Org resolves it to '%s'"
         date-str
         (org-records-mcp--timestamp-moment-rendered timestamp)))
      ;; Org's planning writer carries a repeater and a warning
      ;; period together, and carries a first-only delay standing
      ;; alone, but writes the repeater by itself when the two
      ;; arrive together.  What goes is a warning rather than a
      ;; date, so the rule above does not reach it; a warning the
      ;; call asked for, gone from the file and answered with a
      ;; success, is the silent half-write a range is refused for.
      ;;
      ;; The loss happens inside the planning writer and not in the
      ;; parse, so the rendering carries the delay and cannot show
      ;; it.  The parsed element is where the evidence survives:
      ;; `first' is the doubled hyphen, and a repeater type is any
      ;; of Org's three repeater forms.
      ;;
      ;; This check runs after every check that asks about the
      ;; date, so the timestamps it names are ones those have
      ;; passed, leaving a client two values it can send rather
      ;; than a suggestion refused in its turn.
      (when (and (eq
                  (org-element-property :warning-type timestamp)
                  'first)
                 (org-element-property :repeater-type timestamp))
        (org-records-mcp--tool-validation-error
         "Date '%s' pairs a first-only warning delay with a \
repeater - Org's planning writer drops the delay and writes '%s'; \
'%s' warns before every repeat"
         date-str
         (org-records-mcp--timestamp-warning-retyped timestamp nil)
         (org-records-mcp--timestamp-warning-retyped timestamp 'all)))
      ;; Org's parser reads a timestamp's parts and reads past the
      ;; rest, so text it read past is text the call sent and the
      ;; file will not hold.  A repeater with a typo beside it is
      ;; the costly one: the repeater goes in, the typo does not,
      ;; and the heading comes out repeating on a schedule nobody
      ;; chose.
      ;;
      ;; This check runs last of all, because the value its message
      ;; names is the rendering, and the rendering is a value to
      ;; send only once every check above has passed the timestamp
      ;; it came from.  Named earlier it would hand back the very
      ;; thing the next check refuses: the rolled date of
      ;; `2026-02-30', offered as a date to send.
      (when-let* ((unread
                   (org-records-mcp--timestamp-unread-words
                    timestamp rendered)))
        (org-records-mcp--tool-validation-error
         "Date '%s' carries text that is no part of a timestamp: \
'%s' - Org would write '%s' without it"
         date-str (string-join unread " ") rendered))
      rendered)))

(defun org-records-mcp--validate-body-no-headlines (body level)
  "Validate that BODY doesn't contain headlines at LEVEL or higher.
LEVEL is the Org outline level (1 for *, 2 for **, etc).
Throws an MCP tool error if invalid headlines are found."
  ;; Build regex to match headlines at the current level or higher
  ;; For level 3, this matches ^*, ^**, or ^***
  ;; Matches asterisks + space/tab (headlines need content)
  (let ((regex (format "^\\*\\{1,%d\\}[ \t]" level)))
    (when (string-match regex body)
      (org-records-mcp--tool-validation-error
       "Body cannot contain headlines at level %d or higher"
       level))))

(defun org-records-mcp--validate-body-no-unbalanced-blocks (body)
  "Validate that BODY doesn't contain unbalanced blocks.
Each #+BEGIN_/#+END_ marker in BODY must be part of a balanced block
element as classified by Org's parser.  Org's block element types all
share the `-block' suffix (e.g. `example-block', `src-block',
`special-block'), so every #+BEGIN_X / #+END_X line whose enclosing
element does not end in `-block' is unbalanced.  Markers nested inside
another block are correctly ignored as literal text by
`org-element-at-point'.  A marker may be indented, as in a list item,
and a line Org reads as a heading inside a block leaves the block
unbalanced.
Throws an MCP tool error if unbalanced blocks are found."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (delay-mode-hooks
        (org-mode)))
    (insert body)
    (goto-char (point-min))
    ;; Org's parser has no element for an unbalanced block: it reads the
    ;; marker line as plain text, so no `org-element-map' finds it.  The
    ;; markers are therefore found by text and classified by the parser,
    ;; as `org-lint-invalid-block' does, with the leading whitespace
    ;; Org's block syntax allows.
    (while (re-search-forward
            "^[ \t]*#\\+\\(BEGIN\\|END\\|begin\\|end\\)_\\(\\S-+\\)"
            nil t)
      (let* ((marker-type (upcase (match-string 1)))
             (block-type (upcase (match-string 2)))
             (etype (org-element-type (org-element-at-point))))
        (unless (and etype
                     (string-suffix-p "-block" (symbol-name etype)))
          (cond
           ((string= marker-type "BEGIN")
            (org-records-mcp--tool-validation-error
             "Body contains unclosed %s block"
             block-type))
           ((string= marker-type "END")
            (org-records-mcp--tool-validation-error
             "Orphaned END_%s without BEGIN_%s"
             block-type block-type))))))))

(defun org-records-mcp--normalize-tags-to-list (tags)
  "Return TAGS, a call's tag set, as a list of tag strings.
One tag arrives as a string and several as a JSON array, which
decodes to a vector; null and the empty array are the empty set.  A
client that sends every argument as a string sends that array as its
text, and it is read back as the array first, see
`org-records-mcp--array-param'.  A list comes back as it stands, so a set a
tool has already read through `org-records-mcp--tag-set-given' passes here
unchanged when it is handed on for validation.

Every member is a string.  `org-tag-re' is a test on text, so a
number, a boolean, an object or a nested array among the members
would reach it as a wrong type and cross the MCP boundary as an
internal error, which names no parameter and tells a client nothing
it can act on.  A JSON object sent in place of the whole set is
refused the same way and for the same reason: it decodes to a list
of pairs, and a pair is no more a tag than a number is.

This is the one place that says what a tag set is, so every
parameter that takes one is covered by the check rather than each
growing a guard of its own."
  (let* ((tags (org-records-mcp--array-param tags "tags"))
         (tag-list
          (cond
           ((null tags)
            nil) ; No tags (nil or empty list)
           ((vectorp tags)
            (append tags nil)) ; Convert JSON array (vector) to list
           ((listp tags)
            tags) ; Already a list
           ((stringp tags)
            (list tags)) ; Single tag string
           (t
            (org-records-mcp--tool-validation-error
             "Invalid tags format: %s"
             (org-records-mcp--json-name tags))))))
    (dolist (tag tag-list)
      (unless (stringp tag)
        (org-records-mcp--tool-validation-error
         "A tag must be a string: %s"
         (org-records-mcp--json-name tag))))
    tag-list))

(defun org-records-mcp--navigate-to-parent-or-top (parent)
  "Navigate to the parent headline PARENT names, or to the file's top level.
PARENT is a target plist as from `org-records-mcp--link-target'; one that
names a whole file, see `org-records-mcp--target-heading-p', means top level.
Returns parent level (integer) if parent exists, nil for top-level.
At the top level, point goes to the start of the file's first heading,
or to the end of a file with none.  That is past the file's preamble,
everything before the first heading: a file-level property drawer,
keyword lines such as #+TITLE and any text, which a new heading must
neither split nor join.
Assumes point is in an Org buffer."
  (if (org-records-mcp--target-heading-p parent)
      (progn
        (org-records-mcp--goto-heading parent)
        ;; Save parent level before moving point
        ;; Ensure we're at the beginning of headline
        (org-back-to-heading t)
        (org-current-level))
    (goto-char (point-min))
    (when (org-before-first-heading-p)
      (outline-next-heading))
    nil))

(defun org-records-mcp--goto-after-child (target parent)
  "Move point past the subtree of the child of PARENT that TARGET names.
TARGET comes from `org-records-mcp--link-target'.  PARENT is the position of
the parent heading in the current buffer, or nil for the top level of
the file, where the child is a heading with no parent.  Throws a
validation error unless TARGET names such a heading in the current
buffer's file.  An ID this buffer does not hold, such as one in
another file, is such an error too, not an unknown ID: the sibling
is only ever looked for here."
  (unless (and (org-records-mcp--paths-equal-p
                (plist-get target :file) (buffer-file-name))
               (or (not (plist-get target :id))
                   (org-with-wide-buffer
                    (org-find-entry-with-id (plist-get target :id))))
               (progn
                 (org-records-mcp--goto-heading target)
                 (save-excursion
                   (if parent
                       (and (org-up-heading-safe) (= (point) parent))
                     (not (org-up-heading-safe))))))
    (org-records-mcp--tool-validation-error
     "Sibling %s not found under parent"
     (plist-get target :link)))
  (org-end-of-subtree t t))

(defun org-records-mcp--position-for-new-child
    (previous-sibling parent-level)
  "Position point where a new heading goes under its parent.
PARENT-LEVEL is the parent's level, with point at the parent heading,
or nil for the top level of the file, with point past the file's
preamble, where the heading goes when PREVIOUS-SIBLING is nil.
PREVIOUS-SIBLING is nil or the target, from `org-records-mcp--link-target',
of the sibling to insert after: a direct child of the parent, or a
heading with no parent at the top level.
If PREVIOUS-SIBLING is non-nil, positions after that sibling's subtree.
If nil, positions at end of parent's subtree.
Throws validation error if the sibling is not found under the parent."
  (cond
   (previous-sibling
    (org-records-mcp--goto-after-child
     previous-sibling
     (and parent-level
          (progn
            (org-back-to-heading t)
            (point)))))
   (parent-level
    ;; No sibling named: insert at end of parent's subtree.  With
    ;; TO-HEADING, `org-end-of-subtree' stops at the start of the next
    ;; heading or at the end of the buffer.  At a heading, go back one
    ;; char to be at the end of the parent's content.  No heading
    ;; predicate is asked: at the end of the buffer, the last line may
    ;; be the parent's own heading, with no newline after it.
    (org-end-of-subtree t t)
    (unless (eobp)
      (backward-char 1)))))

(defun org-records-mcp--ensure-newline ()
  "Ensure there is a newline or buffer start before point."
  (unless (or (bobp) (looking-back "\n" 1))
    (insert "\n")))

(defun org-records-mcp--insert-heading (title parent-level)
  "Insert a new Org heading at the appropriate level.
TITLE is the headline text to insert.
PARENT-LEVEL is the parent's heading level (integer) if inserting
as a child, or nil if inserting at top-level.
Assumes point is positioned where the heading should be inserted.
After insertion, point is left on the heading line at end-of-line."
  (if parent-level
      ;; We're inside a parent.  Pass the explicit LEVEL argument to
      ;; `org-insert-heading' so the new heading lands at parent + 1
      ;; regardless of what heading point currently sits inside (e.g.
      ;; at the end of a sibling subtree positioned via previous_sibling).
      ;; This is what avoids the "creates a sibling of the parent
      ;; instead of a child" pitfall of bare `org-insert-heading' when
      ;; the parent has no children.
      ;;
      ;; INVISIBLE-OK says that point is where the caller means even
      ;; when it is inside a folded region.  Without it
      ;; `org-insert-heading' walks back to the nearest *visible*
      ;; heading and inserts at the end of that one's subtree, so a
      ;; parent the user has folded hands its new child to whichever
      ;; heading the fold ends on.
      (progn
        (org-records-mcp--ensure-newline)
        (org-insert-heading nil t (1+ parent-level))
        (insert title))
    ;; Top-level heading
    ;; Check if there are no headlines yet (empty buffer or only
    ;; headers before us).  `outline-next-heading' moves past a
    ;; heading at point, so the first line is asked on its own.
    (let ((has-headline
           (save-excursion
             (goto-char (point-min))
             (or (org-at-heading-p) (outline-next-heading)))))
      (if (not has-headline)
          (progn
            (org-records-mcp--ensure-newline)
            (insert "* "))
        ;; Has headlines - use `org-insert-heading'
        ;; Ensure proper spacing before inserting
        (org-records-mcp--ensure-newline)
        (org-insert-heading nil t t))
      (insert title))))

(defmacro org-records-mcp--with-private-kill-ring (&rest body)
  "Run BODY with a kill ring of its own, leaving the user's alone.
Org relocates a subtree through the kill ring: `org-cut-subtree'
pushes the text onto it and `org-paste-subtree' reads it back, and
`org-archive-subtree' uses both.  That ring is the user's, and a tool
call is not a yank of theirs, so BODY works on a binding of its own
and neither the ring nor the system clipboard behind it keeps what
BODY cut."
  (declare (indent 0) (debug (body)))
  `(let ((kill-ring kill-ring)
         (kill-ring-yank-pointer kill-ring-yank-pointer)
         (interprogram-cut-function nil)
         (interprogram-paste-function nil))
     ,@body))

(declare-function org-inlinetask-remove-END-maybe "org-inlinetask" ())

(defun org-records-mcp--cut-subtree-at-point ()
  "Cut the subtree of the heading at point, and return its text.
Everything under the heading goes with it, its drawers and its
LOGBOOK included, because `org-cut-subtree' takes the region Org
gives the headline rather than one measured here.  The text comes
back, so that a caller putting the subtree down elsewhere pastes what
it cut and a caller that only removes it lets it go.  It is read from
`org-subtree-clip', the variable `org-cut-subtree' and
`org-paste-subtree' hand text through by contract; `org-cut-subtree'
is `(interactive)' and no Org version promises what it returns.

The cut ends the way Org ends its own: `org-archive-subtree' and
`org-refile' both call `org-inlinetask-remove-END-maybe' after
removing a subtree, guarded by `featurep' so the feature is not
loaded for a user who does not use inline tasks.  org-node-archive
reaches that cleanup through `org-archive-subtree'; org-node-delete
and org-node-refile reach it here, so the three verbs leave a file
in the same state."
  (prog1 (org-records-mcp--with-private-kill-ring
           (org-cut-subtree)
           org-subtree-clip)
    (when (featurep 'org-inlinetask)
      (org-inlinetask-remove-END-maybe))))

(defun org-records-mcp--goto-next-heading-start ()
  "Move point to the start of the next heading, or to the end of the buffer.
Point stays where it is when it already starts one.  The search reads
the buffer's text and not its visibility, so a heading the user has
folded is a heading here."
  (unless (and (bolp) (org-at-heading-p))
    (outline-next-heading)))

(defun org-records-mcp--paste-subtree-under
    (text parent-target sibling-target)
  "Paste TEXT, a subtree cut from this buffer, under PARENT-TARGET.
SIBLING-TARGET, when non-nil, is the child of that parent the subtree
is to follow; without one the subtree becomes the parent's last
child, or, when PARENT-TARGET names a whole file, the first heading
in it.  Both are resolved by the functions org-node-create resolves
them with, so `parent' and `previous_sibling' put a node that is
refiled where they put a node that is made.

Org shifts the pasted subtree to the level of its new place, every
descendant under it with it, and leaves point on its heading.  An
`ID' anywhere in TEXT is re-registered against this buffer's file,
which `org-paste-subtree' does through `org-id-paste-tracker', so an
`id:' link to the node or to a descendant resolves to where it now
is."
  (let ((parent-level
         (org-records-mcp--navigate-to-parent-or-top parent-target)))
    (org-records-mcp--position-for-new-child
     sibling-target parent-level)
    ;; `org-paste-subtree' pastes before the heading point starts, and
    ;; walks to the next *visible* heading when point starts none.
    ;; Point goes to the start of that heading here, so the paste never
    ;; begins that walk: a heading the user has folded would carry the
    ;; subtree past it and make the node a child of the wrong parent.
    (org-records-mcp--goto-next-heading-start)
    (org-paste-subtree
     (if parent-level
         (1+ parent-level)
       1)
     text)))

(defun org-records-mcp--log-refile-at-point ()
  "Record the refile of the node at point, as `org-log-refile' asks.
Nothing is written when `org-log-refile' is nil, and the entry goes
where `org-log-note-headings' and `org-log-into-drawer' put it, so a
node carrying `LOG_INTO_DRAWER' gets its own drawer.  Called at the
node's new heading, in the buffer of the file it landed in, which is
where `org-refile' both reads the setting and writes the entry.

Org's own path to it, `org-add-log-setup', cannot be used here: it
hangs the write on `post-command-hook', and with `org-log-refile' set
to `note' that hook opens a `*Org Note*' buffer and waits for a
person to type in it.  An MCP call has no person and no command loop
to return to, so the entry is written through
`org-records-mcp--insert-log-note', which is this server's non-interactive
way to the same `org-store-log-note'.

The entry therefore carries the heading line alone, with no note body
under it, whether `org-log-refile' is `time' or `note'.  That is the
entry Org itself writes for a refile nobody can be asked about: a
bulk refile from the agenda forbids `note' and records the timestamp
instead.  A caller with something to say about the move says it with
org-node-add-note, which is the tool for prose in a LOGBOOK."
  (when org-log-refile
    (org-records-mcp--insert-log-note "" 'refile)))

(defun org-records-mcp--refile-subtree-to
    (text parent-target sibling-target)
  "Put TEXT, a subtree just cut from this buffer, under PARENT-TARGET.
Returns the link to the node where it lands.  SIBLING-TARGET is the
child of that parent the node is to follow, or nil; see
`org-records-mcp--paste-subtree-under', which places it.

The parent may be in another file, which is where the subtree then
goes.  That file's buffer is written like the file the node left and
saved through `org-records-mcp--maybe-save-buffer', so a buffer the user has
edits in is left for the user to save; `org-records-mcp--unsaved-change-p'
says when it is, and the response's `saved' answers for both files.

The subtree is cut before it is put down, and only the buffer it was
cut from is inside the calling change group.  A destination that does
not resolve therefore refuses with both files as they were, because
nothing has been written when the search fails; a failure after the
subtree is down leaves it in both files rather than in neither.

The node's arrival is recorded where Org records it, see
`org-records-mcp--log-refile-at-point'.  What is not run is
`org-after-refile-insert-hook': it is arbitrary user code, and the
place `org-refile' runs it from is, here, the middle of a change
group over two files.  A hook that moves point, edits either buffer
or signals leaves the call unable to say what it wrote, and an error
raised after the subtree is down cannot be undone back to a file the
client would recognise.  Running one is a decision for a caller who
knows what is on the hook; org-records-mcp declines it for everyone."
  (let* ((destination (plist-get parent-target :file))
         (elsewhere
          (not
           (org-records-mcp--paths-equal-p
            destination (buffer-file-name (buffer-base-buffer)))))
         (context
          (and elsewhere
               (org-records-mcp--file-buffer-context destination)))
         (buffer
          (if elsewhere
              (plist-get context :buffer)
            (current-buffer)))
         (link nil))
    (with-current-buffer buffer
      (org-with-wide-buffer
       (org-records-mcp--paste-subtree-under
        text parent-target sibling-target)
       (setq link (org-records-mcp--link-at-point))
       ;; Last in the buffer's own form: `org-store-log-note' ends by
       ;; restoring a window configuration, which leaves whichever
       ;; buffer that configuration shows current.  Nothing here reads
       ;; the buffer after it, and the enclosing `save-excursion'
       ;; hands the right one back to the caller.
       (org-records-mcp--log-refile-at-point)))
    (when elsewhere
      (org-records-mcp--maybe-save-buffer
       buffer destination (plist-get context :modified-p))
      (when (buffer-modified-p buffer)
        (setq org-records-mcp--unsaved-change-p t)))
    link))

(defun org-records-mcp--archive-location-at-point ()
  "Return the file `org-archive-subtree' would move the node at point to.
The location is the `ARCHIVE' property in force at point, or
`org-archive-location' when no node above it carries one, and Org's
own `org-archive--compute-location' reads it, so the answer is the
location Org acts on.  Org publishes no other accessor for it, and
working the file out here a second way is how a report comes to
disagree with what happened.  The value is the node's own file when
the archive is a heading inside it."
  (car
   (org-archive--compute-location
    (or (org-entry-get nil "ARCHIVE" 'inherit)
        org-archive-location))))

(defun org-records-mcp--archive-subtree-at-point ()
  "Archive the subtree of the heading at point, and return the file it went to.
`org-archive-subtree' relocates the subtree whole and writes into it
where it came from — the file, the outline path, the category, the
TODO state it held, its inherited tags, whichever of them
`org-archive-save-context-info' names.  That record is what makes an
archive the one relocation a reader can follow backwards.

Org copies into the archive before it cuts from here, so a failure in
between leaves the node in both files rather than in neither.

The archive file's buffer is saved here rather than by Org, through
`org-records-mcp--maybe-save-buffer', so that a buffer the user already has
edits in is left for the user to save, as every other write here
leaves one.  When it is, `org-records-mcp--unsaved-change-p' says so and the
response's `saved' answers for the archive file too."
  (let* ((archive-file (org-records-mcp--archive-location-at-point))
         (elsewhere
          (not
           (org-records-mcp--paths-equal-p
            archive-file (buffer-file-name (buffer-base-buffer)))))
         (context
          (and elsewhere
               (org-records-mcp--file-buffer-context archive-file))))
    (org-records-mcp--with-private-kill-ring
      ;; Org saves the archive file itself, without asking whether the
      ;; buffer it saves was the user's to save.
      ;;
      ;; `org-archive-mark-done' makes Org mark the archived subtree
      ;; done through `org-todo', which reaches a log entry through
      ;; `org-auto-repeat-maybe' on a repeating entry; Org marks it in
      ;; the archive buffer, so that is where the entry goes.
      (let ((org-archive-subtree-save-file-p nil))
        (org-records-mcp--logging-note nil
          (org-records-mcp--repeat-catching-up
            (org-archive-subtree)))))
    (when elsewhere
      (let ((buffer (plist-get context :buffer)))
        (org-records-mcp--maybe-save-buffer
         buffer archive-file (plist-get context :modified-p))
        (when (buffer-modified-p buffer)
          (setq org-records-mcp--unsaved-change-p t))))
    archive-file))

(defun org-records-mcp--assert-destination-outside
    (bounds parent-target sibling-target)
  "Refuse a refile whose destination lies inside the subtree BOUNDS covers.
PARENT-TARGET and SIBLING-TARGET come from `org-records-mcp--link-target'; a
nil SIBLING-TARGET names no sibling, and a PARENT-TARGET naming a
whole file is always outside.

A node cannot become a child of itself or of one of its own
descendants, and it cannot be asked to follow itself: the heading the
call is addressed to goes away with the node, and the paste is left
with nowhere to land.  Both headings are found before anything is
cut, so the refusal leaves the file as it was.

A destination in another file is outside the subtree by construction
and is not looked for here, where only this buffer can be searched."
  (pcase-dolist (`(,name . ,target)
                 `(("parent" . ,parent-target)
                   ("previous_sibling" . ,sibling-target)))
    (when (and target
               (org-records-mcp--paths-equal-p
                (plist-get target :file)
                (buffer-file-name (buffer-base-buffer))))
      (let ((position
             (save-excursion
               (when (org-records-mcp--target-heading-p target)
                 (org-records-mcp--goto-heading target)
                 (point)))))
        (when (and position
                   (>= position (car bounds))
                   (< position (cdr bounds)))
          (org-records-mcp--tool-validation-error
           "%s %s is the node being refiled, or a node under it"
           name (plist-get target :link)))))))

;; Tool handlers

(defun org-records-mcp--todo-config (sequences)
  "Return the TODO keyword configuration SEQUENCES describes.
SEQUENCES has the shape of `org-todo-keywords', and is walked
directly rather than through the parsed `org-todo-keywords-1' /
`org-done-keywords' so the response can preserve each keyword's raw
form (the fast-access key plus state-logging directives, e.g.
\"TODO(t!)\" = fast key `t' and log a timestamp on entry) along with
the explicit `\"|\"' separator position.  Clients of this tool depend
on those fields, and the parsed siblings discard them.

One walk serves the global sequences and a file's own, so the two
answer in the same shape by construction; `org-records-mcp--tool-config-todo'
is where they are chosen between."
  (let ((seq-list '())
        (sem-list '()))
    (dolist (seq sequences)
      (let* ((type (car seq))
             (keywords (cdr seq))
             (type-str (symbol-name type))
             (keyword-vec [])
             (before-bar t))
        (dolist (kw keywords)
          (if (string= kw "|")
              (setq before-bar nil)
            ;; Check if this is the last keyword and no "|" seen
            (let ((is-last-no-bar
                   (and before-bar (equal kw (car (last keywords))))))
              (when is-last-no-bar
                (setq keyword-vec (vconcat keyword-vec ["|"])))
              (push `((state
                       .
                       ,(car (org-remove-keyword-keys (list kw))))
                      (isFinal
                       .
                       ,(if (or is-last-no-bar (not before-bar))
                            t
                          :json-false))
                      (sequenceType . ,type-str))
                    sem-list)))
          (setq keyword-vec (vconcat keyword-vec (vector kw))))
        (push
         `((type . ,type-str) (keywords . ,keyword-vec)) seq-list)))
    (json-encode
     `((sequences . ,(vconcat (nreverse seq-list)))
       (semantics . ,(vconcat (nreverse sem-list)))))))

(defun org-records-mcp--tool-config-todo (&optional link files)
  "Return the TODO keyword configuration, LINK's file's or the global one.
LINK, when the call sends one, names the file to answer for: the
keywords a write to a heading in it is held to, which are the ones
Org reached there from its `#+TODO:', `#+SEQ_TODO:' and
`#+TYP_TODO:' settings.  Those settings are file-wide, so a link
naming a heading answers for the heading's file rather than being
refused, and the heading itself is never looked up.  A file naming no
sequence of its own inherits the global ones and is answered with
them, which is what Org does with it; see
`org-records-mcp--file-todo-sequences'.

Without a link the answer is the global `org-todo-keywords', which is
what a client asking nothing about a file gets.

FILES, when non-nil, names the files an `id:' LINK is looked up in;
see `org-records-mcp--link-target'.  Sent without a LINK it is refused rather
than ignored: the answer would be the global one while the call named
a file, which is the very confusion this parameter is here to end.

MCP Parameters:
  link - Link to the file to answer for, or to a heading in it
         (string, optional); left out, or \"\" or
         whitespace, the global configuration
  files - Files and directories to look up an id: link in, in order,
          instead of Emacs's ID index (array of strings, optional);
          refused with any other link, and with no link"
  (let ((link (org-records-mcp--optional-link-given link "link")))
    (when (and (not link) (org-records-mcp--files-given files))
      (org-records-mcp--tool-validation-error
       "files names where to look up an id: link, and this call sent \
no link"))
    (org-records-mcp--todo-config
     (or (when-let* ((target
                      (and link
                           (org-records-mcp--link-target link "link"
                                                         files))))
           (org-records-mcp--with-org-file (plist-get target :file)
             (org-records-mcp--file-todo-sequences)))
         org-todo-keywords))))

(defun org-records-mcp--tool-config-tags ()
  "Return the tag configuration as literal Elisp strings."
  (json-encode
   `((org-use-tag-inheritance
      .
      ,(prin1-to-string org-use-tag-inheritance))
     (org-tags-exclude-from-inheritance
      . ,(prin1-to-string org-tags-exclude-from-inheritance))
     (org-tag-alist . ,(prin1-to-string org-tag-alist))
     (org-tag-persistent-alist
      . ,(prin1-to-string org-tag-persistent-alist)))))

(defun org-records-mcp--tool-config-tag-candidates (&optional files)
  "Return the union of all candidate tags across a set of files.
The files are the ones FILES names, see `org-records-mcp--with-file-set',
or the allowed files when FILES is nil.
Mirrors the set Org's interactive tag completion offers via
`org-global-tags-completion-table': configured tags from
`org-tag-alist' / `org-tag-persistent-alist', any per-file
`#+TAGS:' / `#+FILETAGS:', plus every tag actually present on
nodes in those files.  Group keywords (`:startgroup' etc.)
are filtered out.  Tags are returned sorted and deduplicated.

MCP Parameters:
  files - Files and directories to collect tags from, replacing the
          allowed files (array of strings, optional)"
  (org-records-mcp--with-file-set files
    (let* ((table
            (append
             ;; The files are passed explicitly, and none means no
             ;; call: given none, Org takes them from the function
             ;; `org-agenda-files', which while the agenda is
             ;; restricted returns the file it is restricted to,
             ;; whether or not the call may reach it.
             (and org-agenda-files
                  (org-global-tags-completion-table org-agenda-files))
             org-tag-alist org-tag-persistent-alist))
           (tags
            (delete-dups
             (delq
              nil
              (mapcar
               (lambda (entry)
                 (let ((token
                        (if (consp entry)
                            (car entry)
                          entry)))
                   (and (stringp token) token)))
               table)))))
      (json-encode `((tags . ,(vconcat (sort tags #'string<))))))))

(defun org-records-mcp--tool-config-priority ()
  "Return the priority configuration."
  (json-encode
   `((highest . ,(char-to-string org-priority-highest))
     (lowest . ,(char-to-string org-priority-lowest))
     (default . ,(char-to-string org-priority-default)))))

(defun org-records-mcp--tool-config-allowed-files ()
  "Return the allowed Org files and the scope override policy.
Each file is returned as an absolute path; relative entries in
`org-records-mcp-allowed-files' are resolved against `org-directory'.
`override_allowed' reports whether `org-records-mcp-file-scope-override'
permits naming files outside them: it is t, or a list with at least
one local root.  `override_roots', present only in the second case,
lists those roots as absolute paths."
  (let ((roots (org-records-mcp--override-roots)))
    (json-encode
     `((files . ,(vconcat (org-records-mcp--expanded-allowed-files)))
       (override_allowed
        .
        ,(if (or (eq org-records-mcp-file-scope-override t) roots)
             t
           :json-false))
       ,@
       (when roots
         `((override_roots . ,(vconcat roots))))))))

(defun org-records-mcp--tool-node-set-todo
    (link before after &optional before_planning note files)
  "Move the TODO state of the node LINK names, or take it off.
Returns the link to the updated node, and as the response's
`after' the state Org left it in, which is the state asked for
unless Org made another of it: a repeating entry moved to a done
keyword comes back in its not-done keyword.  The same repeat moves
the node\\='s planning dates, and a `scheduled' or `deadline' field
reports the one it moved, with the state that field was in and the
state it is in now; see `org-records-mcp--planning-moves'.  A change Org
vetoes is refused and nothing is written; see
`org-records-mcp--set-todo-state'.
BEFORE is the TODO state the node is asserted to hold, \"\" for
a node that has none.  A node in any other state is a
conflict and nothing is written.
AFTER is the new TODO state to set, or null to take the keyword off
so that the node stops being a task.  It names the keyword only:
the planning fields are Org's to decide and no parameter writes them
here.
BEFORE_PLANNING is what the call asserts the node\\='s planning
fields hold, naming a field it says holds a timestamp and leaving out
one it says holds nothing; see `org-records-mcp--planning-map-given'.  A
field holding anything else is a conflict and nothing is written.
It is optional, and a heading whose state change would move a
planning value is refused without it, which is the whole of what
makes an optional guard a guard here; see
`org-records-mcp--planning-assertion-required-p'.
NOTE, when provided, is stored in LOGBOOK as part of the state change entry.
FILES, when non-nil, names the files an `id:' LINK is looked up in;
see `org-records-mcp--link-target'.

MCP Parameters:
  link - Link to the node
         Formats:
           - id:{id}
           - file:{absolute-path}::#{custom-id}
           - file:{absolute-path}::*{title} (first match)
           - any of these as [[link]] or [[link][description]]
  before - The TODO state the node holds now (string, required)
           Send \"\" to assert that it has no TODO keyword; any
           other state is refused and nothing is written
  after - New TODO state (must be in `org-todo-keywords')
          null takes the keyword off, so the heading stops being a
          task; \"\" names no keyword and is refused, and false is
          the parameter left out
          A client that cannot send null sends the text null,
          which is read as null unless the file names a keyword
          null
          It sets the keyword only: a planning date this call moves
          is Org's doing, and the response reports it
  before_planning - What the node's planning fields hold now
           (object, optional):
             {\"scheduled\": \"<2026-06-20 Sat +1w>\"}
           Each value is the raw Org timestamp a read returns,
           brackets, repeater and delay included.  A field holding
           nothing is left out of the map, which asserts that it
           holds nothing; \"\" and null are refused, so one state
           keeps one spelling.  A field holding something else is a
           conflict and nothing is written
           Required for a heading whose state change would move a
           planning value, which is a repeating heading carrying
           one, and refused there when it is missing.  The refusal
           names what the heading holds, so the call can be sent
           again without reading it first
           A client that sends every argument as a string sends the
           object as its JSON text, those characters in a string
  note - Optional note to attach to this state transition (string, optional)
         When provided, stored in LOGBOOK as the prose of the state
         change entry
         \"\" or whitespace alone is the parameter left
         out: the state change is made and no
         prose recorded
  files - Files and directories to look up an id: link in, in order,
          instead of Emacs's ID index (array of strings, optional);
          refused with any other link"
  (setq before (org-records-mcp--text-param-given before "before"))
  (org-records-mcp--assert-field-value before "State")
  ;; The text null is left for the file to read, which may name a
  ;; keyword null; see `org-records-mcp--todo-null-text'.
  (unless (org-records-mcp--null-text-p after)
    (setq after (org-records-mcp--value-to-write after "after")))
  ;; Before the link is resolved and before the change group opens:
  ;; the note is written inside the change the state change is made
  ;; in, so a note this call cannot write is refused while there is
  ;; still nothing to take back.
  (setq note (org-records-mcp--optional-text-given note "note"))
  ;; Read before the link is resolved, with the note, so a malformed
  ;; assertion is refused while there is still nothing to take back.
  (setq before_planning
        (org-records-mcp--planning-map-given
         before_planning "before_planning"))

  (let* ((target (org-records-mcp--link-target link "link" files))
         (file-path (plist-get target :file))
         (actual-prev nil)
         (actual-new nil)
         (clock-reading nil)
         (planning-prev nil)
         (planning-new nil))
    (org-records-mcp--modify-and-save
        file-path "update"
        (append
         `((before . ,actual-prev) (after . ,actual-new))
         (org-records-mcp--planning-moves planning-prev planning-new)
         (org-records-mcp--clock-closed-moves clock-reading))
      ;; Validate inside the Org buffer so `org-todo-keywords-1'
      ;; reflects merged user-customization + per-file `#+TODO:'.
      (setq after (org-records-mcp--todo-null-text after))
      (when after
        (org-records-mcp--validate-todo-state after))
      (org-records-mcp--goto-heading target)

      ;; Capture actual previous state
      (setq actual-prev (org-records-mcp--asserted-value :todo))
      ;; And the planning dates, which Org may decide to move on the
      ;; way to the keyword the call asked for; see
      ;; `org-records-mcp--planning-moves'.
      (setq planning-prev (org-records-mcp--planning-at-point))
      ;; A clock running in this heading is the other thing the
      ;; keyword can take with it: `org-clock-out-when-done' closes
      ;; one when the heading reaches a done keyword.  What is read
      ;; here is the open line's start and the ends already closed at
      ;; it, so that afterwards the close this call made can be told
      ;; from the closes that were there before;
      ;; see `org-records-mcp--clock-closed-moves'.
      (setq clock-reading (org-records-mcp--clock-open-reading))

      ;; Check current state matches
      (unless (string= actual-prev before)
        (org-records-mcp--state-mismatch-error
         before
         (if (string-empty-p actual-prev)
             "(no state)"
           actual-prev)
         "State"))

      ;; Both assertions are checked before either is acted on: the
      ;; keyword first, because it is the field the call is addressed
      ;; to and the likelier of the two to have moved.  The planning
      ;; one also decides whether the call had to carry an assertion
      ;; at all, which needs the heading in front of it.
      (org-records-mcp--assert-planning before_planning planning-prev)

      ;; Update the state, refusing a change Org vetoes and reading
      ;; back what Org made of the one it took.  The note rides the
      ;; change, so the transition leaves one entry however the log
      ;; settings stand.
      (setq actual-new (org-records-mcp--set-todo-state after note))
      (setq planning-new (org-records-mcp--planning-at-point)))))

(defun org-records-mcp--tool-node-create
    (title
     parent
     &optional
     todo
     content
     tags
     previous_sibling
     properties
     files)
  "Add a new TODO item to an Org file.
Returns the new node\\='s link; no identifier is created, so the
link is `id:' only when PROPERTIES sets an ID.
TITLE is the new node\\='s title.
TODO is the TODO state from `org-todo-keywords'.  It is optional, and
a blank one, see `org-records-mcp--blank-param-p', makes a heading carrying no
keyword — a node that is not a task, which is the node a read reports
by carrying no TODO state for it.  A value that is no keyword is
refused, as it is on `org-records-mcp--tool-node-set-todo'.
A state Org vetoes for the new heading, such as a done keyword under
an ordered parent whose earlier siblings are unfinished, is refused
and no heading is added; see `org-records-mcp--set-todo-state'.
CONTENT is the optional body text.  A creation destroys nothing, and
a body is the one thing a new heading plausibly has none of, so a
blank CONTENT, see `org-records-mcp--blank-param-p', writes no body, as
leaving it out does.  Anything else has to be text.
PARENT is the link to the parent item, or to a whole file for
its top level.
TAGS is an optional single tag string or list of tag strings.  A
blank TAGS, see `org-records-mcp--blank-param-p', sets none: a creation has
no tags to take away, so no blank can ask for more than that.
PREVIOUS_SIBLING is an optional link to the sibling to insert after: a
direct child of the parent, or a heading with no parent when
PARENT names a whole file.  An `id:' PREVIOUS_SIBLING is looked up in
the parent's file.
PROPERTIES is an optional alist of property names and values, checked
by `org-records-mcp--validate-properties' like those of `org-node-set-properties'.
A blank PROPERTIES, see `org-records-mcp--blank-param-p', sets none.  PROPERTIES
sent as the text of a JSON object is read back as that object first,
see `org-records-mcp--object-param'.
FILES, when not blank, names the files an `id:' PARENT is looked
up in; see `org-records-mcp--link-target'.  It applies to PARENT only.

MCP Parameters:
  title - The new node's title, and text Org reads as a title: a
          trailing :tag:, a leading COMMENT, a leading TODO
          keyword and a leading [#A] are each refused, because
          Org would take them out of the title
  todo - TODO state from `org-todo-keywords', or blank for a
         heading that is not a task
  parent - Link to the parent item
           Formats:
             - id:{id}
             - file:{absolute-path}::#{custom-id}
             - file:{absolute-path}::*{title} (first match)
             - file:{absolute-path} (top level of the file)
             - id:{id} of the file-level property drawer (top level
               of the file)
             - any of these as [[link]] or [[link][description]]
  content - Optional body text; \"\" writes no body,
            as leaving it out does
  tags - Tags to add (optional, single string or array of strings,
         or the JSON text of such an array); \"\"
         and [] add none, as leaving it out does
  previous_sibling - Link to the sibling to insert after (optional),
                     a direct child of the parent, or a top-level
                     heading of the file when parent names a whole
                     file
                     Formats:
                       - id:{id}
                       - file:{absolute-path}::#{custom-id}
                       - file:{absolute-path}::*{title} (first match)
                       - any of these as [[link]] or
                         [[link][description]]
  properties - JSON object of properties for the new node
               (optional), such as ID or CUSTOM_ID
               Values take the three states a drawer line has, as
               in org-node-set-properties: a single-line string or
               number is written as given, \"\" writes a line
               carrying no value, and null writes nothing at all,
               there being no line on a new node to take away.
               true or false writes the text t or nil
               Special properties (TODO, TAGS, PRIORITY, etc.) are
               forbidden
               properties left out means no properties; an
               empty object is refused
               A client that sends every argument as a string sends
               the object as its JSON text, those characters in a
               string
  files - Files and directories to look up an id: link of parent
          in, in order, instead of Emacs's ID index (array of
          strings, optional); refused with any other parent"
  (setq title (org-records-mcp--text-param-given title "title"))
  (org-records-mcp--validate-title-text title)
  (setq todo
        (unless (org-records-mcp--blank-param-p todo)
          (org-records-mcp--text-param-given todo "todo")))
  (let*
      ((written nil)
       (tag-list
        (unless (org-records-mcp--blank-param-p tags)
          (org-records-mcp--validate-and-normalize-tags tags)))
       ;; The body is inserted and checked as text, so a number, an
       ;; object or a non-empty array would reach that as a wrong type
       ;; and cross the MCP boundary as an internal error, which names
       ;; no parameter and tells a client nothing it can act on.
       (body
        (unless (org-records-mcp--blank-param-p content)
          (unless (stringp content)
            (org-records-mcp--tool-validation-error
             "content must be a string: %s"
             (org-records-mcp--json-name content)))
          content))
       (property-list
        (let ((properties
               (org-records-mcp--object-param
                properties "properties")))
          (unless (org-records-mcp--blank-param-p properties)
            (org-records-mcp--validate-properties
             properties "properties"))))
       ;; A link that names a whole file means top level.
       (parent-target
        (org-records-mcp--link-target parent "parent" files))
       (file-path (plist-get parent-target :file))
       ;; The sibling can only be a child of the parent, or a heading
       ;; with no parent at the top level, so its `id:' link is taken
       ;; to be in the parent's file: no ID index is consulted, and
       ;; neither are FILES.  Resolving it here refuses a bad link
       ;; before the parent's buffer is changed.
       (sibling-target
        (when-let* ((sibling
                     (org-records-mcp--optional-link-given
                      previous_sibling "previous_sibling")))
          (org-records-mcp--link-target sibling "previous_sibling"
                                        nil
                                        file-path))))

    ;; Add the TODO item
    (org-records-mcp--modify-and-save file-path "add TODO"
                                      `((file
                                         .
                                         ,(file-name-nondirectory
                                           file-path))
                                        (title . ,written))
      ;; Validate inside the Org buffer so `org-todo-keywords-1' and
      ;; the priority bounds are the file's, per-file `#+TODO:' and
      ;; `#+PRIORITIES:' lines included.  What the title has to be
      ;; whatever file it lands in was asked before any of this.
      ;; Nothing is written until both pass, so a refusal leaves the
      ;; file as it was.
      (when todo
        (org-records-mcp--validate-todo-state todo))
      (org-records-mcp--validate-title-grammar title)
      (let ((parent-level
             (org-records-mcp--navigate-to-parent-or-top
              parent-target)))

        ;; Handle positioning after navigation to parent
        (org-records-mcp--position-for-new-child
         sibling-target parent-level)

        ;; Validate body before inserting heading
        ;; Calculate the target level for validation
        (let ((target-level
               (if parent-level
                   ;; Child heading - parent level + 1
                   (1+ parent-level)
                 ;; Top-level heading
                 1)))

          ;; Validate body content if provided
          (when body
            (org-records-mcp--validate-body-no-headlines
             body target-level)
            (org-records-mcp--validate-body-no-unbalanced-blocks
             body)))

        ;; Insert the new heading
        (org-records-mcp--insert-heading title parent-level)

        ;; The response states the file rather than the call: Org
        ;; normalizes a headline's whitespace as it reads one back, so
        ;; the title here is the one a read returns and the one the
        ;; `link' beside it names.
        (setq written (org-records-mcp--asserted-value :title))

        ;; A new heading carries no keyword, so naming no state asks
        ;; for the state it is already in.
        (when todo
          (org-records-mcp--set-todo-state todo))

        (when tag-list
          (org-set-tags tag-list))

        ;; Add body if provided
        (if body
            (progn
              (end-of-line)
              (insert "\n" body)
              (unless (string-suffix-p "\n" body)
                (insert "\n"))
              ;; Move back to the heading, where the properties go
              (org-back-to-heading t))
          ;; No body - ensure newline after heading
          (end-of-line)
          (unless (looking-at "\n")
            (insert "\n")))

        ;; Set properties once the body is in place; Org puts the
        ;; drawer between the heading and the body.  A client-set ID
        ;; is not added to Org's ID locations, as when a user types
        ;; the property by hand.
        (pcase-dolist (`(,name . ,value) property-list)
          (when value
            (org-set-property name value)))))))

;; Resource handlers

(defun org-records-mcp--read-structured
    (link &optional fields depth properties computed files)
  "Return structured JSON for what LINK, a native Org link, points to.
The org-node-read tool and the org://{link} resource both read through
here, so they resolve a link the same way.  A file and a heading come
back as the same node, `org-records-mcp--node-at-point' builds both, and the
file is the one at level 0.

FIELDS is the org-node-read tool's `fields' parameter, defaulting to
`org-records-mcp--node-read-fields'.  PROPERTIES is its `properties'
parameter and COMPUTED its `computed' one, both defaulting to `all':
a read is the call that returns the whole node, drawer and computed
fields included, where a match list returns an overview.  All three are
resolved before the link is, so a misspelled name is refused without
opening a file.  The resource passes none of them and takes every
default: a resource is picked from a client's UI, which has nowhere
to say how much of the node it wants.

DEPTH is the org-node-read tool's `depth' parameter, see
`org-records-mcp--depth-given', and is resolved before the link is for the
same reason.  The resource passes none and takes the node alone: a
join is a client's decision about how much to fetch, and a resource
is picked from a UI where an unbounded expansion is a surprise.

FILES is the org-node-read tool's `files' parameter; see
`org-records-mcp--link-target'.  The resource passes none."
  (let ((fields
         (org-records-mcp--node-fields-given
          fields org-records-mcp--node-read-fields))
        (depth (org-records-mcp--depth-given depth))
        (properties
         (org-records-mcp--node-properties-given properties 'all))
        (computed
         (org-records-mcp--node-computed-given computed 'all)))
    (org-records-mcp--read-link
     link "link"
     (lambda ()
       (json-encode
        (org-records-mcp--projected-node-at-point
         fields properties computed
         depth)))
     (lambda (_file)
       (json-encode
        (org-records-mcp--projected-node-at-point
         fields properties computed
         depth t)))
     files)))

(defun org-records-mcp--handle-org-resource (params)
  "Handler for the org://{link} template.
PARAMS holds `link', the rest of the URI after `org://' as the client
sent it: mcp-server-lib does not decode template variables.  Its
percent-encoding is undone here, exactly once, by
`org-records-mcp--percent-decode', so a URI that mixes raw non-ASCII
characters with encoded ones decodes to the same link.

The link is then read as the org-node-read tool reads it, and a tool error,
such as the refusal of a link, becomes a resource error with the same
message."
  (let ((link
         (org-records-mcp--percent-decode
          (alist-get "link" params nil nil #'string=))))
    (condition-case err
        (org-records-mcp--read-structured link)
      (mcp-server-lib-tool-error
       (mcp-server-lib-resource-signal-error
        mcp-server-lib-jsonrpc-error-invalid-params (cadr err))))))

(defun org-records-mcp--tool-node-set-title
    (link before after &optional files)
  "Rename the node LINK names from BEFORE to AFTER.
Preserves the current TODO state and tags.
Returns the link to the renamed node.
FILES, when non-nil, names the files an `id:' LINK is looked up in;
see `org-records-mcp--link-target'.

MCP Parameters:
  link - Link to the node
         Formats:
           - id:{id}
           - file:{absolute-path}::#{custom-id}
           - file:{absolute-path}::*{title} (first match)
           - any of these as [[link]] or [[link][description]]
  before - Current title without TODO state or tags, compared as Org
           compares titles: letter case, runs of whitespace and
           statistics cookies make no difference, so the title a
           read returned is always accepted
  after - New title without TODO state or tags (required), and
          text Org reads as a title: a trailing :tag:, a leading
          COMMENT, a leading TODO keyword and a leading [#A] are
          each refused, because Org would take them out of the
          title.  A statistics cookie on the node is kept
          unless after names one of its own.  Null, false and []
          are the parameter left out; a title cannot be taken
          away, so there is nothing a blank could ask for
  files - Files and directories to look up an id: link in, in order,
          instead of Emacs's ID index (array of strings, optional);
          refused with any other link"
  (setq before (org-records-mcp--text-param-given before "before"))
  (setq after (org-records-mcp--text-param-given after "after"))
  (org-records-mcp--validate-title-text after)
  (org-records-mcp--assert-field-value before "Title")

  (let* ((target (org-records-mcp--link-target link "link" files))
         (file-path (plist-get target :file))
         (found nil)
         (written nil))

    ;; Rename the headline in the file
    (org-records-mcp--modify-and-save file-path "rename"
                                      `((before . ,found)
                                        (after . ,written))
      ;; Navigate to the headline
      (org-records-mcp--goto-heading target)

      ;; The file's own keywords and priority bounds decide what its
      ;; headline grammar claims, so that half of the check is made
      ;; here rather than before the buffer exists.  Nothing is
      ;; written yet, so a refusal leaves the file as it was.
      (org-records-mcp--validate-title-grammar after)

      ;; Verify current title matches
      (setq found (org-records-mcp--asserted-value :title))
      (unless (org-records-mcp--titles-equal-p found before)
        (org-records-mcp--state-mismatch-error before found "Title"))

      (org-edit-headline
       (org-records-mcp--title-keeping-cookie after))
      (setq written (org-records-mcp--asserted-value :title)))))

(defun org-records-mcp--sole-occurrence (text body)
  "Return where TEXT begins in BODY, refusing unless it is there once.
Letter case matters, so a body and an assertion differing only in
case are two different strings here.  Finding the one occurrence and
refusing the calls that have none or several is the same pass over
BODY, so what a caller receives is the place to splice at.

Both refusals answer a `before' the client believed it read — the
part it named has gone, or something has been written that repeats
it — so both are conflicts."
  (let ((case-fold-search nil)
        (at nil)
        (count 0)
        (from 0))
    (while (string-match (regexp-quote text) body from)
      (unless at
        (setq at (match-beginning 0)))
      (setq count (1+ count))
      (setq from (match-end 0)))
    (cond
     ((= count 0)
      (org-records-mcp--tool-conflict-error "Body text not found: %s"
                                            text))
     ((> count 1)
      (org-records-mcp--tool-conflict-error
       "Text appears %d times (must be unique)"
       count)))
    at))

(defun org-records-mcp--replace-whole-body (bounds digest after)
  "Replace the body region BOUNDS covers with AFTER, asserting DIGEST.
DIGEST is the `content_digest' a read of the node returned.  What
the call replaces is the region entire, so what it asserts is the
region entire: a client that read the body holds a token over it and
needs no part of it echoed back.

The refusal names the token the call sent and not the one the body
carries now, for the reason `org-records-mcp--assert-subtree' gives at the
other radius: the current token is the one value that would make the
same call succeed, and a caller asserting a token it never read
asserts nothing."
  (unless (string= digest (org-records-mcp--digest bounds))
    (org-records-mcp--tool-conflict-error
     "Content mismatch: expected '%s'; the body has changed since that read, so read the node again for a current content_digest; nothing was written"
     digest))
  (delete-region (car bounds) (cdr bounds))
  (goto-char (car bounds))
  (org-records-mcp--insert-body-text after))

(defun org-records-mcp--replace-body-substring (bounds before after)
  "Replace the one occurrence of BEFORE in the body BOUNDS covers.
AFTER takes its place.  BEFORE is the part of the body the client
read and means to change, asserted to occur exactly once; \"\"
asserts the body holds nothing, which is how initial content reaches
a node that has none.

Every refusal here answers a `before' the client believed it read,
so every one of them is a conflict: the body the call was planned
against is not the body the file holds, and the recovery is to read
the node again and send the replacement against what is there."
  (let* ((begin (car bounds))
         (end (cdr bounds))
         (body (buffer-substring-no-properties begin end))
         (blank (string-match-p "\\`[[:space:]]*\\'" body)))
    (cond
     ((string= before "")
      (unless blank
        (org-records-mcp--tool-conflict-error
         "An empty before asserts the node has no content, \
and this node has some; send the part of the content to replace"))
      (delete-region begin end)
      (goto-char begin)
      (org-records-mcp--insert-body-text after))
     (blank
      (org-records-mcp--tool-conflict-error
       "Node has no body content"))
     (t
      (let ((at (org-records-mcp--sole-occurrence before body)))
        (delete-region begin end)
        (goto-char begin)
        (insert
         (substring body 0 at)
         after
         (substring body (+ at (length before)))))))))

(defun org-records-mcp--write-body (link before after files)
  "Replace part or all of the body of the node LINK names with AFTER.
BEFORE says what the client believed the body held, in one of the
two forms it takes, and which form it takes picks what the call
replaces: the `content_digest' a read returned replaces the body
entire, and anything else is a substring of the body and replaces
that substring.  The prefix is the whole of the discrimination, so a
client that means to rewrite the body says so by asserting the
region rather than by setting a flag.

BEFORE and AFTER both reach the file through
`org-records-mcp--text-param-given', so a body is asserted, and written, by
the rule every other text parameter follows: \"\" is the text naming
an empty body, and the rest of `org-records-mcp--blank-param-p' is a
parameter the call did not send.  AFTER is read first, so a call
carrying no body to write is refused before the node is found.
Every body write comes here, so no body changes unguarded.
FILES, when non-nil, names the files an `id:' LINK is looked up in;
see `org-records-mcp--link-target'."
  (setq after (org-records-mcp--text-param-given after "after"))
  (org-records-mcp--validate-body-no-unbalanced-blocks after)

  (let* ((asserted
          (org-records-mcp--text-param-given before "before"))
         (target (org-records-mcp--link-target link "link" files))
         (file-path (plist-get target :file))
         ;; The replacement leaves point at the end of the new body,
         ;; which is the first child's heading when there is one; the
         ;; response links to the heading whose body changed.
         (heading nil))

    (org-records-mcp--modify-and-save file-path "edit body" nil
      (org-records-mcp--goto-heading target)
      (setq heading (point-marker))

      (org-records-mcp--validate-body-no-headlines
       after (org-current-level))

      (let ((bounds (org-records-mcp--body-bounds)))
        (if (org-records-mcp--digest-form-p asserted)
            (org-records-mcp--replace-whole-body
             bounds asserted after)
          (org-records-mcp--replace-body-substring
           bounds asserted after)))

      (goto-char heading)
      (set-marker heading nil))))

(defun org-records-mcp--tool-node-set-content
    (link before after &optional files)
  "Replace the body content of an Org node with AFTER.
LINK is the link to the node to edit.
BEFORE is what the client believed the body held: the node's
`content_digest', which replaces the body entire, or a substring of
the body, asserted unique, which replaces that substring.
AFTER is the replacement text.
FILES, when non-nil, names the files an `id:' LINK is looked up in;
see `org-records-mcp--link-target'.

MCP Parameters:
  link - Link to the node
         Formats:
           - id:{id}
           - file:{absolute-path}::#{custom-id}
           - file:{absolute-path}::*{title} (first match)
           - any of these as [[link]] or [[link][description]]
  before - What the body holds now, in one of two forms.  A
           substring of the body, which must be unique, replaces
           that substring; the content_digest a read of this node
           returned replaces the body entire.  Use \"\" to add to
           empty nodes.
  after - Replacement text
  files - Files and directories to look up an id: link in, in order,
          instead of Emacs's ID index (array of strings, optional);
          refused with any other link"
  (org-records-mcp--write-body link before after files))

(defun org-records-mcp--property-name-text (name)
  "Return NAME, a key of a property map, as a string.
A JSON object decodes with symbols for keys, and a refusal names the
property the way the call spelled it."
  (if (symbolp name)
      (symbol-name name)
    name))

(defun org-records-mcp--validate-properties (properties what)
  "Validate PROPERTIES and return them as (NAME . VALUE) pairs.
WHAT names the parameter PROPERTIES arrived in, so that a call
carrying two property maps says which of them is malformed.
PROPERTIES is the alist a JSON object decodes to.  NAME is a string.
VALUE is nil for a JSON null, the property absent, and the string the
property holds otherwise, \"\" among them; a JSON number becomes its
decimal text, and JSON true and false become \"t\" and \"nil\".  Throws a validation error when PROPERTIES is not a
non-empty object, when a name is not a valid Org property name or is
a special property, which has its own tool, or when a value is an
array or object or spans several lines.  Org property values are
single lines, and a line break would add structure such as a heading
to the file.  Values are otherwise taken as given, the strings \"t\"
and \"nil\" included; `ID' and `CUSTOM_ID' are ordinary properties
here."
  (unless (and properties (listp properties))
    (org-records-mcp--tool-validation-error
     "%s must be a non-empty JSON object"
     what))
  (mapcar
   (lambda (pair)
     (let ((name (org-records-mcp--property-name-text (car pair)))
           (value (cdr pair)))
       ;; Org has no public predicate for property names.  This is the
       ;; check `org-set-property' and `org-entry-put' make themselves,
       ;; but only once the heading is being edited; making it first
       ;; keeps a refused call from touching the buffer.  It matches
       ;; whitespace by syntax class, so it runs under Org's syntax
       ;; table rather than that of whichever buffer is current.
       (unless (with-syntax-table org-mode-syntax-table
                 (org--valid-property-p name))
         (org-records-mcp--tool-validation-error
          "Invalid property name: '%s'"
          name))
       (org-records-mcp--assert-not-accumulating name)
       (when (member
              (upcase name) org-records-mcp--special-properties)
         (org-records-mcp--tool-validation-error
          "Cannot set special property '%s' - use the dedicated tool"
          name))
       (cons
        name
        (cond
         ;; mcp-server-lib decodes JSON with `json-read-from-string':
         ;; true is t, false is :json-false and null is nil.  Null is
         ;; the only value carrying no text, and "" falls through to
         ;; the last clause, because a line carrying nothing is a
         ;; state of its own.  `org-entry-put' writes the text "nil"
         ;; as given, and `org-entry-get' reads it back as nil.
         ((null value)
          nil)
         ((eq value t)
          "t")
         ((eq value :json-false)
          "nil")
         ((numberp value)
          (number-to-string value))
         ((not (stringp value))
          (org-records-mcp--tool-validation-error
           "Property '%s' must be a string, a number, a boolean or null"
           name))
         ((string-match-p "[\n\r]" value)
          (org-records-mcp--tool-validation-error
           "Property '%s' must be a single line"
           name))
         (t
          value)))))
   properties))

(defun org-records-mcp--property-map-given (map what)
  "Return MAP, the required property-map parameter WHAT, as pairs.
The result is (NAME . VALUE) pairs, VALUE nil where the entry is JSON
null and the string the entry carries otherwise, \"\" among them.

A drawer entry has three states where a field has two, and the map
spells all three, on either side of the call.  Null is the property
absent: as an `after' it takes the line away, as a `before' it
asserts there is none.  \"\" is a line carrying nothing, `:FOO:' with
nothing after the name, which `org-entry-properties' reads back as
\"\" and which a call can therefore assert as readily as write.  Any
other string is the text the line holds, so long as it is one line.

Each field spells its own emptiness, and a property has one more
state to spell than a deadline has; see `org-records-mcp--text-param-given'
for the two-state form the fields take.  A property value\\='s
vocabulary is wider still, so `false' is not blank here: with `true'
it writes the text Org stores, `nil', which is a value like any
other.  `org-records-mcp--validate-properties' refuses what no property
value may be: an array, an object with anything in it, and a string
spanning several lines.  `{}' is none of those, decoding to the nil
that takes the line away.

The map is itself the call\\='s statement of what it means to touch,
which is what makes a destructive null safe here where an unfilled
parameter would not be: a key carrying null is a key the call chose
to send, and `org-records-mcp--asserted-property-values' requires `before'
to name every property `after' writes, so the deletion still asserts
what it destroys.  A blank MAP, see `org-records-mcp--blank-param-p', is the
parameter left out.

A MAP sent as the text of a JSON object is read back as that object
first, see `org-records-mcp--object-param'."
  (let ((map (org-records-mcp--object-param map what)))
    (when (org-records-mcp--blank-param-p map)
      (org-records-mcp--missing-param-error what))
    (org-records-mcp--validate-properties map what)))

(defun org-records-mcp--properties-touched (written drawer)
  "Return what a property write sets and what it takes away.
WRITTEN is the (NAME . VALUE) pairs the call writes, nil for a
property it takes away, and DRAWER is what `org-records-mcp--drawer-at-point'
read before the change.  The result is (SET . REMOVED), each the
names in the order the call gave them, which is what the response
reports.

A name carrying a string is set, \"\" among them: writing `:FOO:'
puts a line in the drawer as surely as writing a value does.  A name
carrying nil takes its line away, and is removed when the drawer
carried one, in neither list when it did not — the call is accepted,
an honest assertion of absence being no conflict, and it takes
nothing away.

The drawer decides that last part, not the value `before' asserted,
because what a write took away is a fact about the file rather than
about the call."
  (let ((set nil)
        (removed nil))
    (pcase-dolist (`(,name . ,value) written)
      (cond
       (value
        (push name set))
       ((assoc (upcase name) drawer)
        (push name removed))))
    (cons (nreverse set) (nreverse removed))))

(defun org-records-mcp--asserted-property-values (before after)
  "Return what BEFORE asserts, in the order AFTER writes it.
BEFORE and AFTER are the two property maps of one call, each read
through `org-records-mcp--property-map-given'.  The result holds one pair per property AFTER
writes, NAME as AFTER spells it and VALUE what BEFORE says that
property held: nil for absent, \"\" for a line carrying nothing, and
the text otherwise.

A call asserts exactly what it changes: a property AFTER writes and
BEFORE does not name is refused, because the write would destroy a
value nobody vouched for, and so is one BEFORE names and AFTER does
not write, because asserting it misstates what the call can touch.
Names compare without regard to case, as Org reads them."
  (let ((unwritten (copy-sequence before)))
    (prog1 (mapcar
            (lambda (pair)
              (let* ((name (car pair))
                     (asserted
                      (assoc name unwritten
                             (lambda (a b)
                               (string= (upcase a) (upcase b))))))
                (unless asserted
                  (org-records-mcp--tool-validation-error
                   "before does not name the property '%s' this \
call writes"
                   name))
                (setq unwritten (delq asserted unwritten))
                (cons name (cdr asserted))))
            after)
      (when unwritten
        (org-records-mcp--tool-validation-error
         "before names the property '%s', which this call does not \
write"
         (caar unwritten))))))

(defun org-records-mcp--property-state-text (value)
  "Return VALUE, one state of a drawer entry, as a refusal names it.
VALUE is nil for a property the drawer does not carry and the text
the line holds otherwise.  An absent property is named rather than
shown as an empty value, because \"\" is the neighbouring state: a
line carrying nothing.  A refusal that showed both as '' would tell
a client its assertion failed without telling it what it read."
  (if value
      (format "'%s'" value)
    "(absent)"))

(defun org-records-mcp--assert-property (asserted drawer name)
  "Refuse the call unless DRAWER holds for NAME what ASSERTED says.
ASSERTED is one of the three states `org-records-mcp--property-map-given'
reads: nil for the property absent, \"\" for a line carrying nothing,
and the text the line holds otherwise.  DRAWER is what
`org-records-mcp--drawer-at-point' read.

Absence is compared by whether the drawer carries the name at all,
and not by the value read for it: a name the drawer lacks and a line
carrying nothing read alike, and those are the two states this
assertion exists to keep apart.

A disagreement is a conflict, the drawer not being as the client
believed, so the recovery is to read the node again.  A digest in
`before' is a malformed call instead, which
`org-records-mcp--assert-field-value' refuses on behalf of every assertion
that names one value."
  (let ((context (format "Property '%s'" name))
        (found (cdr (assoc (upcase name) drawer))))
    (org-records-mcp--assert-field-value asserted context)
    (unless (equal asserted found)
      (org-records-mcp--tool-conflict-error
       "%s mismatch: expected %s, found %s"
       context
       (org-records-mcp--property-state-text asserted)
       (org-records-mcp--property-state-text found)))))

(defun org-records-mcp--goto-node-drawer (target file-node)
  "Move point to the property drawer of the node TARGET names.
FILE-NODE non-nil means TARGET names a whole file, see
`org-records-mcp--target-heading-p'; otherwise it names a heading, which
`org-records-mcp--goto-heading' goes to and which always has a drawer to
read and to write.

A file's own drawer is the one Org reads at the top of the buffer,
so point goes to `point-min'.  The value is non-nil when the node has
a region there: a file whose first line is a heading has none, see
`org-records-mcp--file-drawer-region-p', and `point-min' is inside that
heading, where neither its drawer nor a write belongs."
  (if file-node
      (progn
        (goto-char (point-min))
        (org-records-mcp--file-drawer-region-p))
    (org-records-mcp--goto-heading target)
    t))

(defun org-records-mcp--make-file-drawer ()
  "Make the region a file's own property drawer lives in, at point-min.
The two lines `org-insert-property-drawer' writes are written here
instead of by it: its placement rule starts at
`org-back-to-heading-or-point-min', which in a file whose first line
is a heading is that heading, so Org has no call that makes a file
one.  They go above everything, which is the only place Org reads a
file's own drawer, see `org-records-mcp--file-drawer-region-p'.  Point is
left at `point-min', in the drawer's entry."
  (goto-char (point-min))
  (insert ":PROPERTIES:\n:END:\n")
  (goto-char (point-min)))

(defun org-records-mcp--write-properties
    (link files action response asserted sets apply)
  "Change the properties ASSERTED names on the node LINK names.
LINK names a heading or a whole file, and a file's own drawer is
written the way a heading's is; see `org-records-mcp--goto-node-drawer'.
ASSERTED is the (NAME . VALUE) pairs the call vouches for, VALUE the
three states a drawer line has: nil for no line, \"\" for a line
carrying nothing, and the text the line holds otherwise.  Every one
is checked before APPLY runs, so that a property named later in the
call cannot be refused after an earlier one has already been
changed.  A name the drawer writes twice is refused before any of
them, see `org-records-mcp--doubled-drawer-names'.  APPLY is then called at
the node, inside the change, and writes the properties.
ACTION names what the call does, for the call site to read.
RESPONSE is called with the drawer as it stood before the change and
returns the fields the call adds to its own response: the names it
touched, and, for a removal, the values it destroyed.  It takes the
drawer rather than a ready-made alist because what a write took away
is a fact about the file and not about the call: only the drawer
tells a property carried with nothing in it from one the drawer never
carried.
SETS is non-nil when APPLY writes a property rather than only taking
properties away.  It decides what happens to a file that opens on a
heading and so has nowhere to keep a drawer: a set makes the region
first, as `org-set-property' makes a drawer, and a removal makes
nothing, as `org-entry-delete' makes nothing.  The removal has
nothing to take away either — every assertion it passed was of
absence — so the call succeeds having left the file alone.
FILES, when non-nil, names the files an `id:' LINK is looked up in;
see `org-records-mcp--link-target'.

This is the whole of what writing properties and removing them
share, and they differ only in what APPLY does."
  (let* ((target (org-records-mcp--link-target link "link" files))
         (file-path (plist-get target :file))
         (drawer nil)
         (file-node nil))

    ;; A file node names its own link, read after the write, which
    ;; may have given the file an ID or taken one away.  The link
    ;; `org-records-mcp--link-at-point' makes before the first heading can
    ;; be a `file:PATH::LINE' search, which org-records-mcp cannot resolve.
    (org-records-mcp--modify-and-save file-path
        action
        (append
         (funcall response drawer)
         (when file-node
           (list (cons 'link (org-records-mcp--file-link)))))
      (setq file-node
            (not (org-records-mcp--target-heading-p target)))
      (let ((in-drawer
             (org-records-mcp--goto-node-drawer target file-node)))

        (setq drawer
              (and in-drawer (org-records-mcp--drawer-at-point)))
        (let ((doubled
               (and in-drawer
                    (org-records-mcp--doubled-drawer-names))))
          (pcase-dolist (`(,key . ,val) asserted)
            (when (member (upcase key) doubled)
              (org-records-mcp--tool-blocked-error
               "Property '%s' is written twice in this drawer, so it \
holds no one value; repair the drawer in Emacs"
               key))
            (org-records-mcp--assert-property val drawer key)))

        (when (or in-drawer sets)
          (unless in-drawer
            (org-records-mcp--make-file-drawer))
          (funcall apply))))))

(defun org-records-mcp--tool-node-set-properties
    (link before after &optional files)
  "Set or remove properties on the node LINK names.
LINK names a heading or a whole file: a file's own drawer, the one
before its first heading, is a drawer like any other and takes the
same three states on either side of the call.
BEFORE is an alist naming each property AFTER writes and the state it
was in: null for no line, \"\" for a line carrying nothing, and the
text the line holds otherwise.
AFTER is an alist of property name-value pairs; null takes that
property away, guarded by what BEFORE says it holds.  The response
carries the asserted map back under `before', because once the call
returns nothing in the file records what a removed property held,
and a reader of the response other than the client that sent it has
no other copy.
FILES, when non-nil, names the files an `id:' LINK is looked up in;
see `org-records-mcp--link-target'.

MCP Parameters:
  link - Link to a heading, or to a whole file for its own
         property drawer
         Formats:
           - id:{id}
           - file:{absolute-path}::#{custom-id}
           - file:{absolute-path}::*{title} (first match)
           - file:{absolute-path} (the file's own drawer)
           - id:{id} of a file's own drawer (that file)
           - any of these as [[link]] or [[link][description]]
  before - JSON object of the values these properties hold now
           (required)
           One entry per property after writes, and no other:
           a property after writes and before omits is refused,
           and so is one before names and after leaves alone
           null asserts the drawer carries no such line
           \"\" asserts a line carrying no value
           Any other string asserts the line holds that text
  after - JSON object of property name-value pairs (required)
          String or number value: set property to that value;
          it must be a single line
          true or false: set property to the text t or nil
          Empty string writes a line carrying no value, which a
          read returns as \"\"
          null takes the property line away, guarded by what
          before says it holds
          A property the drawer spreads over a NAME and a NAME+
          line holds the lines joined; a set writes the value
          given and takes the NAME+ lines with the old one
          ID and CUSTOM_ID are accepted and written as given
          Special properties (TODO, TAGS, PRIORITY, etc.) are
          forbidden, and so is a name ending in +, which adds to
          another property rather than naming one
          A client that sends every argument as a string sends
          the object as its JSON text, those characters in a
          string, and before the same way
  files - Files and directories to look up an id: link in, in order,
          instead of Emacs's ID index (array of strings, optional);
          refused with any other link"
  (let* ((written (org-records-mcp--property-map-given after "after"))
         (asserted
          (org-records-mcp--asserted-property-values
           (org-records-mcp--property-map-given before "before")
           written))
         (sets (and (cl-find-if #'cdr written) t)))
    (org-records-mcp--write-properties
     link files "set properties"
     (lambda (drawer)
       (let ((touched
              (org-records-mcp--properties-touched written drawer)))
         (list
          (cons 'properties_set (vconcat (car touched)))
          (cons 'properties_deleted (vconcat (cdr touched)))
          (cons 'before asserted))))
     asserted sets
     (lambda ()
       (pcase-dolist (`(,key . ,val) written)
         ;; `org-delete-property' takes the `NAME+' lines with the
         ;; plain one, and `org-records-mcp--set-property' supersedes them, so
         ;; a property ends up holding what the call said either way.
         (if (null val)
             (org-delete-property key)
           (org-records-mcp--set-property key val)))))))

;; In-buffer settings

(defconst org-records-mcp--file-settings
  '("TITLE" "TODO" "ARCHIVE" "CATEGORY" "FILETAGS" "STARTUP")
  "The in-buffer settings org-records-mcp reads and writes, upcased.
Each is a value about the file it stands in — its title, the
workflow its headings are held to, where a subtree of it is
archived, the category its entries carry in the agenda, the tags
every heading in it inherits, and how it opens.  They are the
settings a client driving a workflow has to be able to set and
whose effect on what is already written org-records-mcp can account for.

Everything else Org reads from a `#+' line is outside this tool,
and two kinds are outside it on purpose.  A setting that reaches
another file — `#+SETUPFILE:', `#+INCLUDE:' — would change what
this file means by naming a file the call never named and the
scope rules never saw.  And `#+PROPERTY:' sets properties
file-wide: it belongs to the property surface, where a drawer
line already has a guard spelling the three states it can be in,
and one construct with two writers would have two vocabularies
for one assertion.

`#+CATEGORY:' is here although Org files its value under
`org-keyword-properties' beside the `#+PROPERTY:' ones, because it
names one thing rather than an arbitrary key: it is the file's
category, which `org-get-category' answers with.")

(defun org-records-mcp--setting-lines ()
  "Return the lines the current buffer writes an in-buffer setting on.
Each element is (KEY VALUE BEGIN): the upcased name of a setting
`org-records-mcp--file-settings' holds, the text Org reads off the line,
and where the line starts.  They come in document order, and a
setting written on no line is absent from the list rather than
present with nothing.

`org-element' is asked rather than a regexp over the buffer
because Org asks it too: `org-collect-keywords' checks every `#+'
it finds with `org-element-at-point', so a `#+TODO:' inside an
example block is a line of that block to both of them, and one
written below the first heading is a setting to both.

The value is the parser's, which is the line with the space around
it gone.  Org reads the line that way, so that text is what a
later call can assert and what a write can put back."
  (let ((lines '()))
    (org-element-map
     (org-element-parse-buffer 'element) 'keyword
     (lambda (keyword)
       (let ((key (org-element-property :key keyword)))
         (when (member key org-records-mcp--file-settings)
           (push (list
                  key
                  (org-element-property :value keyword)
                  (org-element-property :begin keyword))
                 lines)))))
    (nreverse lines)))

(defun org-records-mcp--setting-lines-of (key lines)
  "Return the entries of LINES that write setting KEY, in document order.
LINES comes from `org-records-mcp--setting-lines'."
  (cl-remove-if-not (lambda (line) (equal (car line) key)) lines))

(defun org-records-mcp--setting-values (key lines)
  "Return the values the LINES of setting KEY carry, in document order.
LINES comes from `org-records-mcp--setting-lines'."
  (mapcar #'cadr (org-records-mcp--setting-lines-of key lines)))

(defun org-records-mcp--settings-in-preamble (lines)
  "Return the entries of LINES that stand before the file\\='s first heading.
LINES comes from `org-records-mcp--setting-lines'.  Org honours a settings
line wherever it stands, below a heading included, so a file may
write one inside a heading\\='s body — and a line written there is
part of that heading\\='s content."
  (let ((first-heading
         (save-excursion
           (goto-char (point-min))
           (and (re-search-forward org-outline-regexp-bol nil t)
                (match-beginning 0)))))
    (if first-heading
        (cl-remove-if-not
         (lambda (line) (< (nth 2 line) first-heading)) lines)
      lines)))

(defun org-records-mcp--settings-insert-position (lines)
  "Return where a settings line is written, given the LINES it joins.
LINES is entries of `org-records-mcp--setting-lines': the lines of the
setting being written when the file has any, and every settings
line it writes otherwise, so that a line replacing others lands
where they stood and a new one joins the settings already there.

A line the file does not yet write goes in the preamble, and only
there.  Org honours a settings line below a heading, so a file may
have one there and the answer would otherwise join it — writing a
`#+' line into that heading's body, which changes a node the call
never named and invalidates the `content_digest' a client holds for
it.  A line already written is replaced where it stands, because
that is the line the call asserted.

A file writing none in its preamble takes the line at the top of
it, below the two things Org keeps above the settings: a leading
comment line, which is where a file-local variables line is
written, and the file\\='s own property drawer, which Org reads only
above the settings, see `org-records-mcp--file-drawer-region-p'.  A file
whose first line is a heading has no preamble, and the line goes
above that heading, where `org-records-mcp--make-file-drawer' puts a
drawer.

Point does not move."
  (save-excursion
    (if lines
        (progn
          (goto-char (nth 2 (car lines)))
          (line-beginning-position))
      (goto-char (point-min))
      (let ((element (org-element-at-point)))
        (while (and (not (eobp))
                    (memq
                     (org-element-type element)
                     '(comment property-drawer)))
          (goto-char (org-element-property :end element))
          (setq element (org-element-at-point))))
      (point))))

(defun org-records-mcp--setting-given (setting)
  "Return SETTING, a call\\='s `setting' parameter, as the name it gives.
The name is upcased, as Org upcases the key of a `#+' line it
reads, so a call asking after `todo' asks after `#+TODO:'.  A name
outside `org-records-mcp--file-settings' is refused with the names that are
in it: the boundary is this tool\\='s subject, and a client that
guessed at one outside it is told which are there rather than left
to guess again.  They are named as this parameter takes them, so
that the refusal hands back a value that can be sent — `#+TODO:' is
how the line reads and `TODO' is what the call carries."
  (let* ((text (org-records-mcp--text-param-given setting "setting"))
         (key (upcase (string-trim text))))
    (unless (member key org-records-mcp--file-settings)
      (org-records-mcp--tool-validation-error
       "No such setting: '%s' - this tool writes %s"
       text
       (mapconcat #'identity org-records-mcp--file-settings ", ")))
    key))

(defun org-records-mcp--setting-set-given (value name)
  "Return VALUE, the settings-lines parameter NAME of a call, as a list.
One line arrives as a string and several as an array; `[]' is the
empty set, which is the file writing the setting on no line, and a
value like any other here.  Every other blank — null, false, \"\" —
is the parameter left out and is refused as one, as it is in a tag
set: nothing a client fills a parameter with absent-mindedly takes
a settings line away.

A member is the text Org reads off the line.  `org-element' drops
the space around that text and stops at the end of the line, so a
member carrying either would assert a line no file can hold and
write one no read could give back."
  (when (and (org-records-mcp--blank-param-p value)
             (not (equal value [])))
    (org-records-mcp--missing-param-error name))
  (let* ((value (org-records-mcp--array-param value name))
         (lines
          (cond
           ((null value)
            nil)
           ((vectorp value)
            (append value nil))
           ((listp value)
            value)
           ((stringp value)
            (list value))
           (t
            (org-records-mcp--tool-validation-error
             "%s must be a string or an array of strings, not %s"
             name (org-records-mcp--json-name value))))))
    (dolist (line lines)
      (unless (stringp line)
        (org-records-mcp--tool-validation-error
         "A settings line must be a string: %s"
         (org-records-mcp--json-name line)))
      (unless (equal line (string-trim line))
        (org-records-mcp--tool-validation-error
         "A settings line carries no space around its value: '%s'"
         line))
      (when (string-match-p "\n" line)
        (org-records-mcp--tool-validation-error
         "A setting is one line, and this value is two or more: '%s'"
         line)))
    lines))

(defun org-records-mcp--settings-for-message (values)
  "Return VALUES, the lines of one setting, as the text of a refusal.
A setting written on no line reads as such rather than as nothing,
so that a comparison of two sets names both sides."
  (if values
      (mapconcat (lambda (value) (format "'%s'" value)) values ", ")
    "(no line)"))

(defun org-records-mcp--setting-text (key value)
  "Return the line setting KEY carrying VALUE is written as.
A VALUE of no text is written with nothing after the colon, which
is the line `org-element' reads back as no text: a trailing space
would make a line no read returns."
  (if (string-empty-p value)
      (format "#+%s:\n" key)
    (format "#+%s: %s\n" key value)))

(defun org-records-mcp--headline-states ()
  "Return what Org reads each heading of this buffer as, in document order.
Each element is (KEYWORD . TITLE): the TODO state Org finds on the
heading, nil when it finds none, and the title it is left with.

Org is asked rather than told, because whether the first word of a
heading is a keyword or the start of its title is Org\\='s reading of
the whole headline and not a question about that word.  A word the
sequences name is a keyword only in the slot before the priority
cookie, so `* [#A] WAIT it' keeps `WAIT' in its title however the
sequences read; and the match is on the whole word, so `WAITING'
is untouched by a sequence naming `WAIT'.  Re-deriving either rule
here would be a second grammar beside Org\\='s."
  (org-element-map
   (org-element-parse-buffer 'headline) 'headline
   (lambda (headline)
     (cons
      (org-element-property :todo-keyword headline)
      (org-element-property :raw-value headline)))))

(defun org-records-mcp--headline-keywords-changed (before after)
  "Return the keywords whose reading changed between BEFORE and AFTER.
Both come from `org-records-mcp--headline-states' over the same buffer, so
the two line up heading by heading.  The value is (LOST . GAINED),
each an alist of (KEYWORD . COUNT) in the order the keywords first
appear: LOST is the keywords headings stop carrying, GAINED the
keywords headings start carrying."
  (let ((lost '())
        (gained '()))
    (cl-mapc
     (lambda (was is)
       (unless (equal was is)
         (dolist (entry
                  (list
                   (cons (car was) 'lost) (cons (car is) 'gained)))
           (when (car entry)
             (let* ((counts
                     (if (eq (cdr entry) 'lost)
                         lost
                       gained))
                    (found (assoc (car entry) counts)))
               (cond
                (found
                 (setcdr found (1+ (cdr found))))
                ((eq (cdr entry) 'lost)
                 (push (cons (car entry) 1) lost))
                (t
                 (push (cons (car entry) 1) gained))))))))
     before after)
    (cons (nreverse lost) (nreverse gained))))

(defun org-records-mcp--headline-change-text (changes)
  "Return CHANGES, from `org-records-mcp--headline-keywords-changed', as refusal text."
  (mapconcat #'identity
             (append
              (mapcar
               (lambda (entry)
                 (format "%s stops being a keyword on %d heading%s"
                         (car entry) (cdr entry)
                         (if (= (cdr entry) 1)
                             ""
                           "s")))
               (car changes))
              (mapcar
               (lambda (entry)
                 (format "%s becomes the keyword of %d heading%s"
                         (car entry) (cdr entry)
                         (if (= (cdr entry) 1)
                             ""
                           "s")))
               (cdr changes)))
             ", "))

(defun org-records-mcp--assert-headings-unchanged (before)
  "Refuse the `#+TODO:' write when it changed what a heading is.
BEFORE is `org-records-mcp--headline-states' as it stood before the write,
which has been made and whose settings Org has read again, so this
buffer now shows what the call would leave behind.

The guard runs in both directions because the two are one thing.
Org takes a heading\\='s first word for its keyword when the sequences
name that word and for the start of its title when they do not, so
sequences that stop naming a word retitle `* WAIT ship it' to the
keywordless heading titled `WAIT ship it', and sequences that start
naming one retitle `* WAIT for the parts' to a WAIT heading titled
`for the parts'.  Each rewrites headings the call named none of,
each leaves nothing in the file saying what they were, and each is
undone only by writing the sequences back.

The refusal is unmarked, the validation class: the client\\='s belief
about the file is not stale — a read of the file shows those
headings — and Org vetoed nothing, since Org would go through with
it.  What has to change is the call."
  (let ((changes
         (org-records-mcp--headline-keywords-changed
          before (org-records-mcp--headline-states))))
    (when (or (car changes) (cdr changes))
      (org-records-mcp--tool-validation-error
       "#+TODO: would change what Org reads headings in this file as: %s.  Org takes a heading's first word for its keyword when the sequences name that word and for the start of its title when they do not, so these headings are rewritten by a call that names none of them.  Write sequences that leave them as they are, or move each heading first -- org-node-set-todo off a keyword that is going, org-node-set-title off a title that would become one -- and write the sequences again"
       (org-records-mcp--headline-change-text changes)))))

(defun org-records-mcp--reread-settings (key values)
  "Make Org read this buffer\\='s settings again, KEY having been set to VALUES.
The buffer stays open after the write, and what Org acts on there is
what it derived from the settings when it read the file: the keywords
a write to a heading is held to, the tags the file gives every
heading, where a subtree of it is archived.
`org-set-regexps-and-options' is the call that derives them again,
and it is Org\\='s own, so the buffer ends up where a fresh visit would
put it.

Two of them need one thing more.  `org-archive-location' and
`org-category' are set from a line Org finds and left alone when it
finds none, so a call that takes the last `#+ARCHIVE:' or
`#+CATEGORY:' line away would leave the value that line set standing
in the buffer.  Killing the local first lets the global answer for a
file that now names nothing, which is again what a fresh visit
gives."
  (when (null values)
    (pcase key
      ("ARCHIVE" (kill-local-variable 'org-archive-location))
      ("CATEGORY" (kill-local-variable 'org-category))))
  (org-set-regexps-and-options))

(defun org-records-mcp--tool-file-settings (link &optional files)
  "Return the in-buffer settings the file LINK names writes.
LINK names the file, or a heading in it: these settings are
file-wide, so the heading decides nothing about the answer and is
never looked up.
FILES, when non-nil, names the files an `id:' LINK is looked up in;
see `org-records-mcp--link-target'.

MCP Parameters:
  link - Link to the file to answer for, or to a heading in it
         (string, required)
  files - Files and directories to look up an id: link in, in order,
          instead of Emacs's ID index (array of strings, optional);
          refused with any other link"
  (let* ((target (org-records-mcp--link-target link "link" files))
         (file (plist-get target :file)))
    (org-records-mcp--with-org-file file
      (let ((lines (org-records-mcp--setting-lines)))
        (json-encode
         `((link . ,(org-records-mcp--file-link))
           (settings
            .
            ,(mapcar
              (lambda (key)
                (cons
                 (intern key)
                 (vconcat
                  (org-records-mcp--setting-values key lines))))
              org-records-mcp--file-settings))))))))

(defun org-records-mcp--tool-file-set-setting
    (link setting before after &optional files)
  "Write the in-buffer setting SETTING of the file LINK names.
LINK names the file, or a heading in it, as it does for a read of
these settings.
SETTING names one of `org-records-mcp--file-settings'.
BEFORE is every line the file writes that setting on now, in the
order it writes them, and `[]' asserts that it writes none.  The
assertion covers the whole set because the call takes away every
line it does not list; it is ordered because the order of these
lines is read — Org joins two `#+TITLE:' lines in the order they
stand, and the first `#+TODO:' sequence is the one a heading with
no keyword enters first.
AFTER is the lines to write, `[]' to leave the file writing none.
FILES, when non-nil, names the files an `id:' LINK is looked up in;
see `org-records-mcp--link-target'.

The response carries BEFORE back, because once the call returns
nothing in the file records what the lines it replaced held.

MCP Parameters:
  link - Link to the file, or to a heading in it (string, required)
  setting - The setting to write, such as TITLE or TODO
            (string, required)
  before - The lines the file writes that setting on now (string or
           array, required); the array a read of these settings
           returns for it.  Send [] to assert that it writes none
  after - The lines to write (string or array, required); [] leaves
          the file writing none
  files - Files and directories to look up an id: link in, in order,
          instead of Emacs's ID index (array of strings, optional);
          refused with any other link"
  (let* ((key (org-records-mcp--setting-given setting))
         (asserted
          (org-records-mcp--setting-set-given before "before"))
         (wanted (org-records-mcp--setting-set-given after "after"))
         (target (org-records-mcp--link-target link "link" files))
         (file-path (plist-get target :file)))
    (dolist (value asserted)
      (org-records-mcp--assert-field-value
       value (concat "#+" key ":")))
    (condition-case err
        (org-records-mcp--settings-written
         file-path key asserted wanted)
      (error
       ;; The change group has put the text back, and Org's reading of
       ;; it has to follow: the checks above run with the settings the
       ;; call wrote, so the buffer is left holding a workflow its file
       ;; no longer names unless the restored lines are read again.  A
       ;; second failure must not replace the first refusal.
       (ignore-errors
         (org-records-mcp--with-org-file file-path
           (org-records-mcp--reread-settings key asserted)))
       (signal (car err) (cdr err))))))

(defun org-records-mcp--settings-written
    (file-path key asserted wanted)
  "Write the lines of setting KEY in FILE-PATH, from ASSERTED to WANTED.
ASSERTED is every line the file is vouched for writing that setting
on and WANTED every line it is to write instead; both come from
`org-records-mcp--setting-set-given'.

This is the whole of what the write does to the file, so that its
caller is left with the one thing it has to do around it: put Org\\='s
reading of the settings back when a refusal puts the text back."
  (org-records-mcp--modify-and-save file-path "set file setting"
                                    (list
                                     (cons 'setting key)
                                     (cons 'before (vconcat asserted))
                                     (cons 'after (vconcat wanted))
                                     (cons
                                      'link
                                      (org-records-mcp--file-link)))
    (let* ((states nil)
           (lines (org-records-mcp--setting-lines))
           (own-lines (org-records-mcp--setting-lines-of key lines))
           (own (mapcar #'cadr own-lines))
           (starts (mapcar (lambda (line) (nth 2 line)) own-lines)))
      (unless (equal asserted own)
        (org-records-mcp--tool-conflict-error
         "#+%s: mismatch: expected %s, found %s"
         key
         (org-records-mcp--settings-for-message asserted)
         (org-records-mcp--settings-for-message own)))
      (when (string= key "TODO")
        (setq states (org-records-mcp--headline-states)))
      (let ((position
             (org-records-mcp--settings-insert-position
              (or own-lines
                  (org-records-mcp--settings-in-preamble lines)))))
        ;; Backwards, so that a line still to be deleted keeps the
        ;; position read off the buffer before any deletion.
        (dolist (start (reverse starts))
          (goto-char start)
          (delete-region
           (line-beginning-position) (line-beginning-position 2)))
        (goto-char position)
        (dolist (value wanted)
          (insert (org-records-mcp--setting-text key value))))
      (org-records-mcp--reread-settings key wanted)
      ;; After the write and after Org has read the settings again,
      ;; because what a heading is is Org's reading of it and this
      ;; buffer is the only place that reading can be taken.  The
      ;; change group puts the text back when this refuses, and the
      ;; caller puts Org's reading of it back with it.
      (when (string= key "TODO")
        (org-records-mcp--assert-headings-unchanged states)))))

(defun org-records-mcp--write-planning-timestamp (writer value)
  "Write VALUE on the entry at point through WRITER.
WRITER is `org-schedule' or `org-deadline', which carry a repeater
and a warning period through to the file; `org-add-planning-info'
takes the date alone and would drop both.  One pairing they do not
carry is a repeater beside a first-only warning delay: given
`<2026-03-27 Fri +1w --3d>' both write `<2026-03-27 Fri +1w>'.
`org-records-mcp--date-normalized' refuses that pairing, so no VALUE
reaching here has a warning to lose.

VALUE is a timestamp Org itself rendered, by
`org-records-mcp--date-normalized', so the date is settled before this runs.
`org-read-date-force-compatible-dates' would nonetheless pull a year
outside 1970-2037 into that range — it guards a 32-bit `time_t',
which the Emacs this package requires does not have — and a deadline
in 2050 would land in 2037.  The year the call named is the year
written, so that guard is off here."
  (let ((org-read-date-force-compatible-dates nil))
    (funcall writer nil value)))

(defun org-records-mcp--activate-planning-timestamp (key)
  "Make the planning timestamp KEY of the heading at point active.
KEY is `:scheduled' or `:deadline', the headline property holding it.
A field holding an active timestamp, or none, is left as it is.

Org finds the SCHEDULED or DEADLINE it replaces or removes by the
keyword followed by `<', so `org-add-planning-info' passes over an
inactive one: a write puts a second keyword in front of it, which the
parser reads past in favour of the old one, and a removal takes
nothing away.  No Org function replaces an inactive planning
timestamp, so it is turned active with `org-toggle-timestamp-type'
first, and Org then replaces it as it would any other.  Its first half is enough for a date range, because
Org clears the entry up to the next keyword."
  (let ((timestamp (org-element-property key (org-element-at-point))))
    (when (memq
           (org-element-property :type timestamp)
           '(inactive inactive-range))
      (save-excursion
        (goto-char (org-element-property :begin timestamp))
        (org-toggle-timestamp-type)))))

(defconst org-records-mcp--field-scheduled
  (list
   :label "SCHEDULED"
   :key
   :scheduled
   ;; `org-schedule' with a `(4)' prefix removes a planning entry by
   ;; matching one timestamp, so it leaves the second half of a date
   ;; range behind as body text.  `org-add-planning-info' is the
   ;; function it removes through, and it clears the whole entry up to
   ;; the next planning keyword.  It records nothing, so the entry
   ;; `org-log-reschedule' asks for is written here, the one
   ;; `org-schedule' would have set up for the same removal.
   :remove
   (lambda (previous)
     (org-records-mcp--activate-planning-timestamp :scheduled)
     (org-add-planning-info nil nil 'scheduled)
     (when org-log-reschedule
       (org-records-mcp--insert-log-note "" 'delschedule
                                         nil
                                         previous)))
   :write
   (lambda (value)
     (org-records-mcp--activate-planning-timestamp :scheduled)
     (org-records-mcp--write-planning-timestamp
      #'org-schedule value)))
  "The SCHEDULED field, for `org-records-mcp--write-field'.
`:label' names it in a refusal, `:key' is the field of
`org-records-mcp--heading-metadata-at-point' that holds it, which
`org-records-mcp--asserted-value' reads it through, `:write' puts a value
there and `:remove' takes away the value passed to it.

A field record names its metadata key rather than carrying a reader
of its own, so the value a write asserts is the value a read
returns, with no second accessor to drift from it.")

(defconst org-records-mcp--field-deadline
  (list
   :label "DEADLINE"
   :key
   :deadline
   ;; See `org-records-mcp--field-scheduled' for why not `org-deadline'.
   :remove
   (lambda (previous)
     (org-records-mcp--activate-planning-timestamp :deadline)
     (org-add-planning-info nil nil 'deadline)
     (when org-log-redeadline
       (org-records-mcp--insert-log-note "" 'deldeadline
                                         nil
                                         previous)))
   :write
   (lambda (value)
     (org-records-mcp--activate-planning-timestamp :deadline)
     (org-records-mcp--write-planning-timestamp
      #'org-deadline value)))
  "The DEADLINE field, for `org-records-mcp--write-field'.
Shaped like `org-records-mcp--field-scheduled'.")

(defconst org-records-mcp--field-closed
  (list :label "CLOSED" :key :closed)
  "The CLOSED field, for the planning report.
Shaped like `org-records-mcp--field-scheduled' but for its `:write' and
`:remove': no tool writes CLOSED.  Org writes it when a heading
reaches a done keyword and clears it when the heading leaves one, so
what it holds is Org\\='s record of the transition rather than anything
a client chose.  Having no writer is what keeps it out of
`org-records-mcp--write-field' and out of every assertion.

Calls destroy it all the same, which is why it is in the report: a
planning write rebuilds the planning line without it, and a state
change out of a done keyword takes it away.  Neither names it, and
after either the response is the only record of what it held.")

(defconst org-records-mcp--planning-fields
  (list
   (cons 'scheduled org-records-mcp--field-scheduled)
   (cons 'deadline org-records-mcp--field-deadline)
   (cons 'closed org-records-mcp--field-closed))
  "Org\\='s planning fields, under the names the wire spells them by.
Each entry pairs that name with the field record holding the metadata
key it is read through and the label a refusal names it by, so the
parameter, the assertion and the response reach one field through one
record.

The response reports all three; `before_planning' asserts the two a
client could have chosen, which `org-records-mcp--planning-asserted-p' picks
out.  You assert what you could have destroyed, and you are told
everything that moved.")

(defun org-records-mcp--planning-asserted-p (record)
  "Return non-nil when planning field RECORD is one a call asserts.
A field this server writes is a field whose value a client chose and
can hold a belief about, so `:write' is what decides it.  CLOSED has
no writer: asking a client to assert it would ask it to vouch for a
value Org picked and it never saw a reason for."
  (plist-get record :write))

(defun org-records-mcp--planning-asserted ()
  "Return the `org-records-mcp--planning-fields' entries a call asserts."
  (seq-filter
   (lambda (entry)
     (org-records-mcp--planning-asserted-p (cdr entry)))
   org-records-mcp--planning-fields))

(defun org-records-mcp--planning-at-point ()
  "Return the planning states of the heading at point.
An alist of `org-records-mcp--planning-fields' names, each holding what that
field holds as a `before' asserts it, \"\" for a field holding
nothing.  Reading through `org-records-mcp--asserted-value' is what makes a
value reported here one the client can send straight back, and it is
where the dates a repeat moved are read from: Org decides them, and
neither this server nor a client works them out for itself."
  (mapcar
   (lambda (entry)
     (cons
      (car entry)
      (org-records-mcp--asserted-value (plist-get (cdr entry) :key))))
   org-records-mcp--planning-fields))

(defun org-records-mcp--planning-field-names ()
  "Return the planning field names a call may assert, for a refusal."
  (mapconcat (lambda (entry) (format "'%s'" (car entry)))
             (org-records-mcp--planning-asserted)
             " and "))

(defun org-records-mcp--planning-holdings (found)
  "Return what FOUND says the asserted planning fields hold, as a clause.
FOUND is an `org-records-mcp--planning-at-point' reading.  The clause names
each field and its value, so a refusal for a missing assertion hands
back what the next call has to assert and costs no second read."
  (mapconcat (lambda (entry)
               (let ((value (alist-get (car entry) found))
                     (label (plist-get (cdr entry) :label)))
                 (if (org-string-nw-p value)
                     (format "%s '%s'" label value)
                   (format "no %s" label))))
             (org-records-mcp--planning-asserted)
             " and "))

(defun org-records-mcp--planning-value-given (value label)
  "Return VALUE, the state a planning assertion says LABEL was in.
A string with a timestamp in it is that state.  \"\" is refused: a
map says a field holds nothing by leaving its name out, so the empty
string would be a second spelling of an assertion that already has
one.  Null is refused for the same reason.  A digest is refused by
`org-records-mcp--assert-field-value', as it is wherever a field is asserted
by its value."
  (unless (stringp value)
    (org-records-mcp--tool-validation-error
     "%s is asserted with the timestamp it holds, and a field holding none is left out of the map, not %s"
     label (org-records-mcp--json-name value)))
  (when (string-empty-p value)
    (org-records-mcp--tool-validation-error
     "%s holding nothing is asserted by leaving it out of before_planning, not by \"\""
     label))
  (org-records-mcp--assert-field-value value label)
  value)

(defun org-records-mcp--planning-map-given (map what)
  "Return MAP, the optional planning assertion WHAT, as pairs.
The result is one (NAME . VALUE) pair per asserted field, in
`org-records-mcp--planning-fields' order, VALUE the timestamp the call says
that field held and \"\" where the map left the name out.  A blank
MAP, see `org-records-mcp--blank-param-p', is nil: the call asserts nothing.

*Two absences, two meanings, and the difference is the design.*  A
name missing from a map the call built is a positive act, so it
asserts that the field holds nothing, and a heading that does hold
something there refuses the call.  That is what spares a client
spelling out an empty DEADLINE on every heading that never had one.
The whole parameter missing is not a positive act -- it reads the same
whether the client meant it or forgot it -- so it asserts nothing at
all.

*An optional parameter is not an off guard here*, which the rule that a guard is required is
otherwise right to refuse.  `org-records-mcp--planning-assertion-required-p'
refuses the call in exactly the case where a planning value would
move, so the guard cannot be off where it would have caught
something.  A reader who does not find this sentence will make the
parameter required and tax every ordinary transition for a guard that
can only fire on a repeating heading.

A name this call does not assert is refused rather than dropped,
CLOSED among them: a client that asked for CLOSED to be guarded has
misread the surface, and a quietly ignored key would leave it
believing otherwise.

A MAP sent as the text of a JSON object is read back as that object
first, see `org-records-mcp--object-param'."
  (setq map (org-records-mcp--object-param map what))
  (unless (org-records-mcp--blank-param-p map)
    (unless (and (listp map) (consp (car-safe map)))
      (org-records-mcp--tool-validation-error
       "%s must be an object naming %s, not %s"
       what
       (org-records-mcp--planning-field-names)
       (org-records-mcp--json-name map)))
    (dolist (pair map)
      (let ((name (intern (format "%s" (car pair)))))
        (unless (assq name (org-records-mcp--planning-asserted))
          (org-records-mcp--tool-validation-error
           (if (assq name org-records-mcp--planning-fields)
               "%s does not assert '%s': the response reports it, and no call writes it.  It takes %s"
             "%s names no planning field: '%s'.  It takes %s")
           what name (org-records-mcp--planning-field-names)))))
    (mapcar
     (lambda (entry)
       (let ((pair (assq (car entry) map)))
         (cons
          (car entry)
          (if pair
              (org-records-mcp--planning-value-given
               (cdr pair) (plist-get (cdr entry) :label))
            ""))))
     (org-records-mcp--planning-asserted))))

(defun org-records-mcp--planning-assertion-required-p (found)
  "Return non-nil when the heading at point needs a planning assertion.
FOUND is an `org-records-mcp--planning-at-point' reading.  A state change
moves a planning value only when Org repeats the entry, and only when
there is a value there to move, so those two together are what makes
the assertion necessary -- and a call without one is refused exactly
there.

Whether the entry repeats is Org\\='s question and `org-get-repeat'
answers it, over the whole entry rather than over the planning line.
That is wider than it looks and has to be: a repeater on a plain
timestamp in the body makes Org take away a SCHEDULED that carries no
repeater of its own, so a heading whose planning line holds no
repeater at all can still lose its SCHEDULED to one.  A repeater
Org would decline to act on, `+0d', still counts as one here; the
assertion it asks for is a value the client has already read."
  (and (org-get-repeat)
       (seq-some
        (lambda (entry)
          (org-string-nw-p (alist-get (car entry) found)))
        (org-records-mcp--planning-asserted))))

(defun org-records-mcp--assert-planning (asserted found)
  "Refuse the call unless FOUND is what ASSERTED says the fields hold.
ASSERTED comes from `org-records-mcp--planning-map-given' and is nil when the
call sent no assertion; FOUND comes from `org-records-mcp--planning-at-point'.
A call that asserted nothing is refused when the heading is one whose
state change would move a planning value, and the refusal names what
the heading holds so the next call can assert it without reading
again.  Otherwise the first field the two disagree on is a conflict,
named by its record\\='s label."
  (if (null asserted)
      (when (org-records-mcp--planning-assertion-required-p found)
        (org-records-mcp--tool-validation-error
         "before_planning is required here: this node repeats, so the state change moves or removes its planning dates.  It holds %s"
         (org-records-mcp--planning-holdings found)))
    (pcase-dolist (`(,name . ,value) asserted)
      (let ((holds (alist-get name found)))
        (unless (equal value holds)
          (org-records-mcp--state-mismatch-error
           value holds
           (plist-get
            (alist-get name org-records-mcp--planning-fields)
            :label)))))))

(defun org-records-mcp--planning-moves
    (before after &optional written)
  "Return response fields for each planning field BEFORE and AFTER differ on.
BEFORE and AFTER are `org-records-mcp--planning-at-point' readings taken on
either side of a write.  A field reading the same in both is left
out: nothing moved under the client, so what it last read still
holds.

WRITTEN, when non-nil, is the field record the call writes itself,
and it is left out however it moved: the response already reports
that field at the top, as the `before' and `after' of the call.  What
is named here is what the call moved without being asked to, which is
what a client has no other way to learn.  A field that moved is named, carrying the state it was in and
the state it is in now, the way every write answers about the field
it writes, so the response\\='s value is the next call's `before'.

Naming only what moved is what makes the report a statement rather
than something to infer.  A write asks Org for a keyword and Org may
decide a date as well -- a repeating entry moved to a done keyword
comes back in its not-done keyword with its dates carried on, Org
takes away a SCHEDULED that carries no repeater while it is there,
and CLOSED comes and goes with the done keyword.  All three are
reported, although only two of them are asserted: what a client may
have destroyed and what it is told about are different questions."
  (delq
   nil
   (mapcar
    (lambda (entry)
      (let* ((name (car entry))
             (was (alist-get name before))
             (now (alist-get name after)))
        (unless (or (equal was now) (eq (cdr entry) written))
          `(,name (before . ,was) (after . ,now)))))
    org-records-mcp--planning-fields)))

(defconst org-records-mcp--field-priority
  (list
   :label "Priority"
   :key
   :priority
   ;; `org-priority' has no log setting and records nothing, so the
   ;; value it takes away is of no use to it.
   :remove (lambda (_previous) (org-priority 'remove))
   :write
   (lambda (value)
     (org-records-mcp--assert-priority-in-range value)
     (org-priority (string-to-char value))))
  "The priority field, for `org-records-mcp--write-field'.
Shaped like `org-records-mcp--field-scheduled'.")

(defun org-records-mcp--write-field
    (link files field before after action)
  "Move FIELD of the heading LINK names from BEFORE to AFTER.
FIELD is a field record — `org-records-mcp--field-scheduled' and its two
siblings — naming the field, the metadata key it is read through and
how to write and remove it.
BEFORE is what the call believes the field holds, checked before
anything is written, so a refused call leaves the file as it was.
AFTER is the value to put there, or nil to take the field away.
ACTION names what the call does, for the call site to read.
FILES, when non-nil, names the files an `id:' LINK is looked up in;
see `org-records-mcp--link-target'.

The response reports the value the field held as `before' and the
value it holds afterwards as `after', both read through the one
accessor a client\\='s next `before' will be compared against, so the
response is the record of what the call destroyed.

A planning field the call did not name is reported under its own name
when the write moved it; see `org-records-mcp--planning-moves'.  Org rebuilds
the planning line when it writes a date to it and does not carry
CLOSED onto the new one, so a heading loses its closing timestamp to
a reschedule.  org-records-mcp reports that rather than putting it back:
repairing what an Org primitive does to the line would part the file
from what the same command produces in the user's own Emacs.

A field that holds nothing already is left alone rather than written
to: a nil AFTER on it asks for what is there, and Org\\='s removers are
written for a value that exists — `org-priority' refuses a heading
with no cookie to take off."
  (let* ((target (org-records-mcp--link-target link "link" files))
         (file-path (plist-get target :file))
         (key (plist-get field :key))
         (previous nil)
         (current nil)
         (planning-prev nil)
         (planning-new nil))

    (org-records-mcp--modify-and-save
        file-path action
        (append
         `((before . ,previous) (after . ,current))
         (org-records-mcp--planning-moves planning-prev planning-new
                                          field))
      (org-records-mcp--goto-heading target)

      (setq previous (org-records-mcp--asserted-value key))
      ;; The other planning fields, which this call does not name and
      ;; Org may move on its way to the one it does; see
      ;; `org-records-mcp--planning-moves'.
      (setq planning-prev (org-records-mcp--planning-at-point))
      (org-records-mcp--assert-before
       before previous (plist-get field :label))

      ;; `org-schedule' and `org-deadline' set up the entry
      ;; `org-log-reschedule' and `org-log-redeadline' ask for; it is
      ;; written here rather than left waiting on `post-command-hook'.
      (org-records-mcp--logging-note nil
        (if after
            (funcall (plist-get field :write) after)
          (unless (string-empty-p previous)
            (funcall (plist-get field :remove) previous))))
      (setq current (org-records-mcp--asserted-value key))
      (setq planning-new (org-records-mcp--planning-at-point)))))

(defun org-records-mcp--date-to-write (value name)
  "Return VALUE, the date parameter NAME of a call, validated, or nil.
An Org timestamp is a date to write, and it comes back as Org
renders it; see `org-records-mcp--date-normalized' for what that takes.
Null is nil, and takes the timestamp away; the required `before'
says what that destroys.  \"\" is not a date and is refused as one,
because a timestamp has no empty value to press into service as a
command; see `org-records-mcp--value-to-write'."
  (let ((date (org-records-mcp--value-to-write value name)))
    (and date (org-records-mcp--date-normalized date))))

(defun org-records-mcp--priority-to-write (value name)
  "Return VALUE, the priority parameter NAME of a call, as one character.
Null is nil, and takes the priority away, guarded by the required
`before'.  \"\" is no character and is refused as one; see
`org-records-mcp--date-to-write' for the same line drawn on a date.

Whether the character is one the file admits is asked later, by
`org-records-mcp--assert-priority-in-range', where the file's own bounds are
in force."
  (let ((priority (org-records-mcp--value-to-write value name)))
    (when priority
      (unless (= (length priority) 1)
        (org-records-mcp--tool-validation-error
         "Invalid priority '%s' - expected a single character, or \
null for no priority"
         priority)))
    priority))

(defun org-records-mcp--assert-priority-in-range (priority)
  "Refuse PRIORITY unless the current buffer's own range admits it.
This runs with the target buffer current, so `org-priority-highest'
and `org-priority-lowest' are the file's, as a `#+PRIORITIES:' line
may have set them, and not the session's.  Org answers a character
outside the range by signalling from `org-priority', which reaches a
client as an internal error naming no parameter, so the range is
asked here first."
  (let ((char (string-to-char priority)))
    (unless (and (>= char org-priority-highest)
                 (<= char org-priority-lowest))
      (org-records-mcp--tool-validation-error
       "Priority '%s' out of range ('%c' to '%c')"
       priority org-priority-highest org-priority-lowest))))

(defun org-records-mcp--tool-node-set-scheduled
    (link before after &optional files)
  "Move SCHEDULED on the node LINK names from BEFORE to AFTER.
BEFORE is the raw Org timestamp the heading carries, or \"\" when it
carries none; the call is refused when the heading says otherwise.
AFTER is an ISO date string, or null to take the timestamp away.
FILES, when non-nil, names the files an `id:' LINK is looked up in;
see `org-records-mcp--link-target'.

MCP Parameters:
  link - Link to the node
         Formats:
           - id:{id}
           - file:{absolute-path}::#{custom-id}
           - file:{absolute-path}::*{title} (first match)
           - any of these as [[link]] or [[link][description]]
  before - The SCHEDULED timestamp the heading carries now, as a
           read returns it, repeater and delay included (required)
           Example: \"<2026-06-20 Sat +1w -3d>\"
           Empty string asserts the heading has no SCHEDULED
  after - ISO date string or null (required), naming a date that exists:
          2026-02-30 and 2026-13-45 are refused rather than
          rolled over to another date
          Examples: \"2026-03-27\", \"2026-03-27 09:00\"
          null takes the timestamp away, guarded by before;
          \"\" is no date and is refused, and false is the
          parameter left out
          A client that cannot send null sends the text null,
          which is read as null
  files - Files and directories to look up an id: link in, in order,
          instead of Emacs's ID index (array of strings, optional);
          refused with any other link"
  (org-records-mcp--write-field
   link
   files
   org-records-mcp--field-scheduled
   before
   (org-records-mcp--date-to-write after "after")
   "set scheduled"))

(defun org-records-mcp--tool-node-set-deadline
    (link before after &optional files)
  "Move DEADLINE on the node LINK names from BEFORE to AFTER.
BEFORE is the raw Org timestamp the heading carries, or \"\" when it
carries none; the call is refused when the heading says otherwise.
AFTER is an ISO date string, or null to take the timestamp away.
FILES, when non-nil, names the files an `id:' LINK is looked up in;
see `org-records-mcp--link-target'.

MCP Parameters:
  link - Link to the node
         Formats:
           - id:{id}
           - file:{absolute-path}::#{custom-id}
           - file:{absolute-path}::*{title} (first match)
           - any of these as [[link]] or [[link][description]]
  before - The DEADLINE timestamp the heading carries now, as a
           read returns it, repeater and delay included (required)
           Example: \"<2026-06-20 Sat +1w -3d>\"
           Empty string asserts the heading has no DEADLINE
  after - ISO date string or null (required), naming a date that exists:
          2026-02-30 and 2026-13-45 are refused rather than
          rolled over to another date
          Examples: \"2026-03-27\", \"2026-03-27 09:00\"
          null takes the timestamp away, guarded by before;
          \"\" is no date and is refused, and false is the
          parameter left out
          A client that cannot send null sends the text null,
          which is read as null
  files - Files and directories to look up an id: link in, in order,
          instead of Emacs's ID index (array of strings, optional);
          refused with any other link"
  (org-records-mcp--write-field
   link
   files
   org-records-mcp--field-deadline
   before
   (org-records-mcp--date-to-write after "after")
   "set deadline"))

(defun org-records-mcp--tag-set-given (value name)
  "Return VALUE, the tag-set parameter NAME of a call, as a list.
One tag arrives as a string and several as an array; `[]' is the
empty set, the tag set of a heading that carries none, and a value
like any other here.

The rest of `org-records-mcp--blank-param-p' — \"\", null, false — is what a
client sends for a parameter it is not using.  Every tag-set
parameter is required, so such a value is a parameter left out
rather than a set to act on, and it is refused with the message an
omitted parameter gets, so that the two spellings of one mistake
read alike.  Blank therefore names no set at all, and in particular
never means the empty one: nothing a client fills a parameter with
absent-mindedly can take a tag away."
  (when (and (org-records-mcp--blank-param-p value)
             (not (equal value [])))
    (org-records-mcp--missing-param-error name))
  (org-records-mcp--normalize-tags-to-list value))

(defun org-records-mcp--tag-set-asserted (before)
  "Return BEFORE, the set of tags a call asserts a heading carries.
Every member is a tag name, by `org-records-mcp--validate-tag-names' — the
one test of what a tag is, and the one the tags a call writes pass
as well.  A member outside `org-tag-re' names a tag no heading
could carry, so no version of the file satisfies the assertion: the
refusal is unmarked, the validation class, and what has to change
is the call.  A set of real names the heading does not carry is the
other case and stays a conflict, since there is a heading to read
again and a set to read off it.

Mutual exclusivity is not checked here.  It is a rule about the
tags a heading ends up carrying, and this set is what it carries
already: a heading whose tags break a group was not written here,
and refusing to assert what it plainly holds would report a
conflict the caller did not cause.

A digest is looked for first and refused in its own words by
`org-records-mcp--assert-field-value'.  It is no tag name either, so the
general refusal would reach it, and reaching it there would cost a
client the sentence that says which of the two forms of `before'
this tool takes."
  (let ((asserted (org-records-mcp--tag-set-given before "before")))
    (dolist (tag asserted)
      (org-records-mcp--assert-field-value tag "Tags"))
    (org-records-mcp--validate-tag-names asserted)))

(defun org-records-mcp--tags-for-message (tags)
  "Return TAGS as the text of a refusal, or `(no tags)' when empty.
Sorted, because what the message reports is a comparison of sets: a
reader who sees one order here and another in the file should not go
looking for a difference that is not there."
  (if tags
      (mapconcat #'identity (sort (copy-sequence tags) #'string<)
                 ", ")
    "(no tags)"))

(defun org-records-mcp--tag-inherited-from (tag)
  "Return where TAG, in effect on the heading at point, is written.
The heading itself does not carry it, so the answer is the nearest
ancestor whose own tags include it, named by its title — or the
file, when no ancestor does, since that is where `#+FILETAGS:' puts
one.  Point does not move."
  (save-excursion
    (let ((source nil))
      (while (and (not source) (org-up-heading-safe))
        (when (member tag (org-get-tags nil t))
          (setq source
                (format "'%s'" (org-records-mcp--title-at-point)))))
      (or source "the file's #+FILETAGS:"))))

(defun org-records-mcp--tags-after-add (added own effective)
  "Return the tags a heading carries itself once ADDED are added.
OWN is what it carries now and EFFECTIVE what is in effect on it,
inherited tags included.  A tag already in EFFECTIVE is left out:
the heading has it, and writing it on the heading as well would make
a local copy of an inherited tag rather than add anything.  The
result therefore differs from OWN only by tags the heading did not
have, which is what makes the call a no-op when it asks for nothing
new and lets two clients adding different tags both keep theirs.
A tag ADDED names twice is added once, as a set has it."
  (cl-remove-duplicates
   (append
    own (cl-remove-if (lambda (tag) (member tag effective)) added))
   :test #'string=
   :from-end t))

(defun org-records-mcp--tags-after-remove (removed own effective)
  "Return the tags a heading carries itself once REMOVED are gone.
OWN is what it carries now and EFFECTIVE what is in effect on it.  A
tag in neither is nothing to take away, and the call passes over it.
Runs at the heading, so a refusal can say where an inherited tag is
written.

A tag the heading only inherits is refused.  Taking it away means
editing the heading it is written on, which this call does not name,
and writing an empty local override here is not a thing Org has: the
tag would stay in effect while the call claimed to have removed it.

The refusal is the unmarked validation class.  The client's belief is
not stale — a read showing the tag under `tags' and not under
`local_tags' said exactly this — so reading again resolves nothing,
and Org vetoed nothing either.  What has to change is the call:
drop the tag from it, or address the heading that carries it."
  (dolist (tag removed)
    (when (and (member tag effective) (not (member tag own)))
      (org-records-mcp--tool-validation-error
       "Cannot remove tag '%s': the heading inherits it from %s and \
does not carry it itself"
       tag (org-records-mcp--tag-inherited-from tag))))
  (cl-remove-if (lambda (tag) (member tag removed)) own))

(defun org-records-mcp--write-own-tags (link files tags-of)
  "Write on the heading LINK names the tags TAGS-OF chooses.
FILES, when non-nil, names the files an `id:' LINK is looked up in;
see `org-records-mcp--link-target'.

TAGS-OF is called at the heading, inside the change, with the tags
the heading carries itself and the tags in effect on it, and returns
the tags to write on it.  A refusal it raises is raised before
anything is written, and a set it returns unchanged writes nothing
at all.  `org-set-tags' writes a heading's own tags and nothing
above it, so this is the whole of what the three tag tools share,
and they differ only in the set TAGS-OF returns.

The response reports that heading's own tags as `before' and
`after', and the tags it has from elsewhere as `inherited', so a
client sees the same partition a read gives it under `local_tags'
and `tags'."
  (let* ((target (org-records-mcp--link-target link "link" files))
         (file-path (plist-get target :file))
         (own-before nil)
         (own-after nil)
         (inherited nil))
    (org-records-mcp--modify-and-save file-path "write tags"
                                      `((before
                                         . ,(vconcat own-before))
                                        (after . ,(vconcat own-after))
                                        (inherited
                                         . ,(vconcat inherited)))
      (org-records-mcp--goto-heading target)
      (let* ((sets (org-records-mcp--tag-sets-at-point))
             (wanted (funcall tags-of (cdr sets) (car sets))))
        (setq own-before (cdr sets))
        ;; A call asking for the tags the heading already carries
        ;; writes nothing: `org-set-tags' would rewrite the heading
        ;; to align the tag column, and a change to the file is not
        ;; what a heading that is already as asked for deserves.
        (when (cl-set-exclusive-or wanted (cdr sets) :test #'string=)
          (org-set-tags wanted)))
      (let ((sets (org-records-mcp--tag-sets-at-point)))
        (setq own-after (cdr sets))
        (setq inherited
              (cl-remove-if
               (lambda (tag) (member tag (cdr sets))) (car sets)))))))

(defun org-records-mcp--tool-node-add-tags
    (link after &optional files)
  "Add tags to the node LINK names.
AFTER is the tags to add, one as a string or several as an array.
A tag the node already has, written on it or inherited, is left
alone.  Nothing is taken away, so the call destroys nothing and
asserts nothing: it takes no `before'.
FILES, when non-nil, names the files an `id:' LINK is looked up in;
see `org-records-mcp--link-target'.

MCP Parameters:
  link - Link to the node
         Formats:
           - id:{id}
           - file:{absolute-path}::#{custom-id}
           - file:{absolute-path}::*{title} (first match)
           - any of these as [[link]] or [[link][description]]
  after - Tags to add (string or array, required)
          Single tag: \"work\"
          Multiple tags: [\"work\", \"urgent\"]
          A client that sends every argument as a string sends the
          array as its JSON text, those characters in a string
          A tag the node already has or inherits is left alone
          Validated against org-tag-alist if configured
  files - Files and directories to look up an id: link in, in order,
          instead of Emacs's ID index (array of strings, optional);
          refused with any other link"
  (let ((added
         (org-records-mcp--validate-and-normalize-tags
          (org-records-mcp--tag-set-given after "after"))))
    (org-records-mcp--write-own-tags
     link files
     (lambda (own effective)
       (org-records-mcp--tags-after-add added own effective)))))

(defun org-records-mcp--tool-node-remove-tags
    (link after &optional files)
  "Remove tags from the node LINK names.
AFTER is the tags to remove, one as a string or several as an array.
Every other tag is left alone, so a tag the client never saw
survives and the call destroys nothing unseen: it takes no `before'.
A tag the node does not have is nothing to take away; a tag it
only inherits is refused, since this call writes nowhere but on the
node.
FILES, when non-nil, names the files an `id:' LINK is looked up in;
see `org-records-mcp--link-target'.

MCP Parameters:
  link - Link to the node
         Formats:
           - id:{id}
           - file:{absolute-path}::#{custom-id}
           - file:{absolute-path}::*{title} (first match)
           - any of these as [[link]] or [[link][description]]
  after - Tags to remove (string or array, required)
          Single tag: \"work\"
          Multiple tags: [\"work\", \"urgent\"]
          A client that sends every argument as a string sends the
          array as its JSON text, those characters in a string
          A tag the node does not have is passed over
          A tag it only inherits is refused
  files - Files and directories to look up an id: link in, in order,
          instead of Emacs's ID index (array of strings, optional);
          refused with any other link"
  (let ((removed
         (org-records-mcp--validate-tag-names
          (org-records-mcp--tag-set-given after "after"))))
    (org-records-mcp--write-own-tags
     link files
     (lambda (own effective)
       (org-records-mcp--tags-after-remove removed own effective)))))

(defun org-records-mcp--tool-node-set-tags
    (link before after &optional files)
  "Replace the tags written on the node LINK names.
BEFORE is the entire set of tags the node is asserted to carry
itself, `[]' for one that carries none, compared as a set since Org
tag order carries no meaning.  Any other set is a conflict and
nothing is written.  The assertion covers the whole set because the
call destroys every tag it does not list, including tags the client
never saw; a client that knows which tags it means to change reaches
for `org-node-add-tags' or `org-node-remove-tags' and asserts
nothing.

The assertion is over the node\\='s own tags, never the set in
effect on it: `org-set-tags' writes local tags only, so asserting
the effective set would assert values this call cannot change and
would refuse because an ancestor was edited.

A digest is refused wherever it turns up in BEFORE, by the same rule
and in the same words as on every other setter.  One tag arrives as
a string and several as an array, and `org-records-mcp--tag-set-given' has
made both a list by the time the check runs, so a token sent as the
whole value and a token sent among real tags are one mistake with
one refusal.  The reason is the one that keeps the assertion local:
a token covers a region, and a region takes in what this call
cannot write — a descendant, an ancestor's tags, a clock line.

Every other member of BEFORE is a tag name, checked as the tags in
AFTER are; `org-records-mcp--tag-set-asserted' says why a value that is not
one is a malformed call rather than a stale belief about the file.

AFTER is the tags to write, `[]' to leave the node carrying none
of its own.  Inherited tags are untouched either way.
FILES, when non-nil, names the files an `id:' LINK is looked up in;
see `org-records-mcp--link-target'.

MCP Parameters:
  link - Link to the node
         Formats:
           - id:{id}
           - file:{absolute-path}::#{custom-id}
           - file:{absolute-path}::*{title} (first match)
           - any of these as [[link]] or [[link][description]]
  before - The tags the node carries itself now (string or
           array, required); the `local_tags' of a read, not its
           `tags'.  Send [] to assert that it carries none.  Order
           makes no difference; any other set of tag names is
           refused as a conflict and nothing is written.  A value
           that is no tag name is a malformed call instead, and a
           digest is no tag wherever in the set it appears
  after - Tags to write (string or array, required)
          Single tag: \"work\"
          Multiple tags: [\"work\", \"urgent\"]
          A client that sends every argument as a string sends the
          array as its JSON text, those characters in a string
          [] leaves the node carrying no tags of its own
          Validated against org-tag-alist if configured
  files - Files and directories to look up an id: link in, in order,
          instead of Emacs's ID index (array of strings, optional);
          refused with any other link"
  (let ((asserted (org-records-mcp--tag-set-asserted before))
        (wanted
         (org-records-mcp--validate-and-normalize-tags
          (org-records-mcp--tag-set-given after "after"))))
    (org-records-mcp--write-own-tags
     link files
     (lambda (own _effective)
       (when (cl-set-exclusive-or asserted own :test #'string=)
         (org-records-mcp--state-mismatch-error
          (org-records-mcp--tags-for-message asserted)
          (org-records-mcp--tags-for-message own)
          "Tags"))
       wanted))))

(defun org-records-mcp--tool-node-set-priority
    (link before after &optional files)
  "Move the priority of the node LINK names from BEFORE to AFTER.
BEFORE is the priority character the heading carries, or \"\" when it
carries none; the call is refused when the heading says otherwise.
AFTER is a single-character string, or null to take the priority
away.
FILES, when non-nil, names the files an `id:' LINK is looked up in;
see `org-records-mcp--link-target'.

MCP Parameters:
  link - Link to the node
         Formats:
           - id:{id}
           - file:{absolute-path}::#{custom-id}
           - file:{absolute-path}::*{title} (first match)
           - any of these as [[link]] or [[link][description]]
  before - The priority character the heading carries now, without
           the [# ] around it (required)
           Empty string asserts the heading has no priority
  after - Priority character (string or null, required)
          Must be within org-priority-highest to org-priority-lowest
          null takes the priority away, guarded by before; \"\"
          is no character and is refused, and false is the
          parameter left out
          A client that cannot send null sends the text null,
          which is read as null
  files - Files and directories to look up an id: link in, in order,
          instead of Emacs's ID index (array of strings, optional);
          refused with any other link"
  (org-records-mcp--write-field
   link
   files
   org-records-mcp--field-priority
   before
   (org-records-mcp--priority-to-write after "after")
   "set priority"))

(defun org-records-mcp--tool-node-add-note (link note &optional files)
  "Add a timestamped note to the LOGBOOK of the node LINK names.
FILES, when non-nil, names the files an `id:' LINK is looked up in;
see `org-records-mcp--link-target'.

MCP Parameters:
  link - Link to the node
         Formats:
           - id:{id}
           - file:{absolute-path}::#{custom-id}
           - file:{absolute-path}::*{title} (first match)
           - any of these as [[link]] or [[link][description]]
  note - Note text to add (string, required)
         Cannot be empty or whitespace-only
         Multi-line notes are indented properly in the LOGBOOK
  files - Files and directories to look up an id: link in, in order,
          instead of Emacs's ID index (array of strings, optional);
          refused with any other link"
  ;; The note is what this call is for, so a blank is the call with
  ;; nothing in it rather than a note it does without: `note' is read
  ;; as the required parameter it is, and "" then says the note
  ;; itself was empty.
  (setq note (org-records-mcp--text-param-given note "note"))
  (when (string-match-p "\\`[[:space:]]*\\'" note)
    (org-records-mcp--tool-validation-error
     "Note cannot be empty or whitespace-only"))

  (let* ((target (org-records-mcp--link-target link "link" files))
         (file-path (plist-get target :file)))

    (org-records-mcp--modify-and-save file-path "add logbook note" nil
      (org-records-mcp--goto-heading target)
      (org-records-mcp--insert-log-note note 'note))))

;; The whole-node verbs
;;
;; Each of the three takes the node away from where it is, so each
;; asserts the subtree it is about to take with `before', the digest
;; token a read of the node handed the client.  There is no `after' to
;; go with it: the verb is the change.  The guard is not graded by how
;; recoverable the verb is — an optional guard is an off guard, and it
;; would be off at archive, the one whose damage goes unnoticed
;; longest.  What recoverability does govern is what each tool's
;; description tells a client it is about to cost.

(defun org-records-mcp--tool-node-delete (link before &optional files)
  "Delete the node LINK names, and every descendant under it.
BEFORE is the digest of the subtree, as a read of the node returned
it; the call is refused when the subtree no longer carries it, see
`org-records-mcp--assert-subtree'.
FILES, when non-nil, names the files an `id:' LINK is looked up in;
see `org-records-mcp--link-target'.

The text is gone from the file and org-records-mcp keeps no copy of it.  The
response carries the link the node had, read while it was still
there, so a client can say which node it lost.

A node the running clock is in is refused rather than deleted, see
`org-records-mcp--assert-clock-outside-subtree': the open CLOCK line would go
with the text and leave Emacs clocking a node that is not there.
Call org-clock-out first, then delete it.

MCP Parameters:
  link - Link to the node to delete
         Formats:
           - id:{id}
           - file:{absolute-path}::#{custom-id}
           - file:{absolute-path}::*{title} (first match)
           - any of these as [[link]] or [[link][description]]
  before - The node's digest, as the digest field of a read of it
           returned it, prefix included (string, required)
  files - Files and directories to look up an id: link in, in order,
          instead of Emacs's ID index (array of strings, optional);
          refused with any other link"
  (let ((target (org-records-mcp--link-target link "link" files))
        (digest (org-records-mcp--digest-given before))
        (deleted nil))
    (org-records-mcp--modify-and-save (plist-get target :file)
        "delete"
        `((link . ,deleted))
      (org-records-mcp--goto-heading target)
      (org-records-mcp--assert-subtree digest "nothing was deleted")
      (org-records-mcp--assert-clock-outside-subtree)
      (setq deleted (org-records-mcp--link-at-point))
      (org-records-mcp--cut-subtree-at-point))))

(defun org-records-mcp--tool-node-archive
    (link before &optional files)
  "Archive the node LINK names, and every descendant under it.
BEFORE is the digest of the subtree, as a read of the node returned
it; the call is refused when the subtree no longer carries it, see
`org-records-mcp--assert-subtree'.
FILES, when non-nil, names the files an `id:' LINK is looked up in;
see `org-records-mcp--link-target'.

The node moves to the archive file with a record of where it came
from written into it, see `org-records-mcp--archive-subtree-at-point'.  The
response names that file and carries the link the node had in the
file it left.

MCP Parameters:
  link - Link to the node to archive
         Formats:
           - id:{id}
           - file:{absolute-path}::#{custom-id}
           - file:{absolute-path}::*{title} (first match)
           - any of these as [[link]] or [[link][description]]
  before - The node's digest, as the digest field of a read of it
           returned it, prefix included (string, required)
  files - Files and directories to look up an id: link in, in order,
          instead of Emacs's ID index (array of strings, optional);
          refused with any other link"
  (let ((target (org-records-mcp--link-target link "link" files))
        (digest (org-records-mcp--digest-given before))
        (archived nil)
        (archive-file nil)
        ;; Archiving writes the archive file's buffer as well as this
        ;; one; `saved' covers that write too.
        (org-records-mcp--unsaved-change-p nil))
    (org-records-mcp--modify-and-save (plist-get target :file)
        "archive"
        `((link . ,archived)
          (archive_file . ,(abbreviate-file-name archive-file)))
      (org-records-mcp--goto-heading target)
      (org-records-mcp--assert-subtree digest "nothing was archived")
      (setq archived (org-records-mcp--link-at-point))
      (setq archive-file
            (org-records-mcp--archive-subtree-at-point)))))

(defun org-records-mcp--tool-node-refile
    (link before parent &optional previous_sibling files)
  "Refile the node LINK names under PARENT, its whole subtree with it.
The call names where the node goes; it does not shift the node one
step from where it is.
BEFORE is the digest of the subtree, as a read of the node returned
it; the call is refused when the subtree no longer carries it, see
`org-records-mcp--assert-subtree'.
PARENT is the link to the node's new parent, or to a whole file for
its top level.  It may name a node in any file a call reaches, and
the node goes to that file; see `org-records-mcp--refile-subtree-to'.
PREVIOUS_SIBLING is an optional link to the child of that parent the
node is to follow, looked up in the parent's file; see
`org-records-mcp--paste-subtree-under'.
FILES, when non-nil, names the files an `id:' LINK is looked up in;
see `org-records-mcp--link-target'.  It applies to LINK only, as on every
other write tool: it says where to find the node the call acts on.
PARENT and PREVIOUS_SIBLING are resolved without it.  A `file:' link
names its own file; an `id:' PARENT is looked up in Emacs's ID index
and refused by name when the index does not hold it, and an `id:'
PREVIOUS_SIBLING is looked for in the parent's file alone, since a
sibling that is not a child of that parent is no sibling.

The subtree arrives whole, its LOGBOOK with it, and nothing in it
records where it was: a refile is undone by refiling it back, by a
caller that knows where back is.  What the LOGBOOK does gain is the
entry `org-log-refile' asks for, a timestamp and no note body; see
`org-records-mcp--log-refile-at-point'.

MCP Parameters:
  link - Link to the node to refile
         Formats:
           - id:{id}
           - file:{absolute-path}::#{custom-id}
           - file:{absolute-path}::*{title} (first match)
           - any of these as [[link]] or [[link][description]]
  before - The node's digest, as the digest field of a read of it
           returned it, prefix included (string, required)
  parent - Link to the node's new parent, in any of the forms link
           takes, or file:{absolute-path} for the file's top level
  previous_sibling - Link to the child of parent the node is to
                     follow (string, optional); omitted, the node
                     becomes the parent's last child
  files - Files and directories to look up an id: link in, in order,
          instead of Emacs's ID index (array of strings, optional);
          refused with any other link"
  (let* ((target (org-records-mcp--link-target link "link" files))
         (file-path (plist-get target :file))
         (digest (org-records-mcp--digest-given before))
         ;; FILES says where to find the node, not where to put it.
         (parent-target
          (org-records-mcp--link-target parent "parent"))
         ;; The sibling is a child of the parent, so it is looked for
         ;; in the parent's file, wherever that is: no ID index is
         ;; consulted for it, which lets it be any link the parent's
         ;; children answer to.
         (sibling-target
          (when-let* ((sibling
                       (org-records-mcp--optional-link-given
                        previous_sibling "previous_sibling")))
            (org-records-mcp--link-target sibling "previous_sibling"
                                          nil
                                          (plist-get
                                           parent-target
                                           :file))))
         (refiled nil)
         ;; A refile into another file writes that file's buffer too;
         ;; `saved' covers that write as well.
         (org-records-mcp--unsaved-change-p nil))
    (org-records-mcp--modify-and-save file-path "refile"
                                      `((link . ,refiled))
      (org-records-mcp--goto-heading target)
      (org-records-mcp--assert-subtree digest "nothing was refiled")
      (org-records-mcp--assert-destination-outside
       (org-records-mcp--subtree-bounds) parent-target sibling-target)
      (setq refiled
            (org-records-mcp--refile-subtree-to
             (org-records-mcp--cut-subtree-at-point)
             parent-target
             sibling-target)))))

;; org-ql integration

(defun org-records-mcp--projected-node-at
    (element fields properties computed)
  "Return the node ELEMENT stands for, carrying FIELDS.
ELEMENT is one match `org-ql-select' returned.  Its buffer is read
widened: a heading outside the user's own narrowing would otherwise
be read at the wrong place."
  (with-current-buffer (org-element-property :buffer element)
    (org-with-wide-buffer
     (goto-char (org-element-property :begin element))
     (org-records-mcp--projected-node-at-point
      fields properties computed))))

(defun org-records-mcp--run-query
    (query-sexp fields properties computed sort)
  "Return the JSON answer to QUERY-SEXP, each match carrying FIELDS.
This is the one runner behind org-query and org-view, so the two
answer in the same envelope by construction: `children', `total' and
the `files_searched' count.

The files searched are the ones the caller put in force with
`org-records-mcp--with-file-set', which is where the two differ: org-query
may be sent a `files' parameter and a view always runs over the
allowed files.  SORT is the other difference, passed to
`org-ql-select' as `:sort': a view sorts by `org-records-mcp-query-sort-fn'
and org-query is unsorted.  FIELDS, PROPERTIES and COMPUTED are
resolved before this runs, so every match is built from names that
are known to exist.

Matches come back as Org elements and the nodes are built from them
in a second pass, because `org-ql-select' applies `:action' before
`:sort': an action returning anything but an element would hand a
comparator something it cannot compare."
  (let* ((target-files org-agenda-files)
         (matches
          ;; Given no files, `org-ql-select' would search the current
          ;; buffer, which no call names.
          (when target-files
            (condition-case err
                (mapcar
                 (lambda (element)
                   (org-records-mcp--projected-node-at
                    element fields properties computed))
                 (org-ql-select target-files query-sexp :sort sort))
              (error
               (org-records-mcp--tool-validation-error
                "Org-ql query error: %s"
                (error-message-string err)))))))
    (json-encode
     `((children . ,(vconcat matches))
       (total . ,(length matches))
       (files_searched . ,(length target-files))))))

(defun org-records-mcp--tool-query
    (query &optional fields properties computed files)
  "Search Org files using an org-ql QUERY expression.
QUERY is a string containing an org-ql query sexp.
FIELDS says how much of each matching node to return; see
`org-records-mcp--node-fields-given'.
PROPERTIES says which of each matching node's drawer to return; see
`org-records-mcp--node-properties-given'.
COMPUTED says which computed fields each matching node returns; see
`org-records-mcp--node-computed-given'.
FILES names the files and directories to search, replacing the
allowed files, see `org-records-mcp--with-file-set'; defaults to all
allowed files.

MCP Parameters:
  query - org-ql query sexp as string (e.g. \"(todo \\\"TODO\\\")\")
  fields - How much of each matching node to return (array of
          strings, or a string naming a configured list, optional);
          defaults to those org-records-mcp-list-fields names
  properties - Which Org drawer properties to return (array of
          property names, or \"all\" or \"none\", optional);
          defaults to none
  computed - Which computed fields to return (array of names, or
          \"all\" or \"none\", optional); defaults to those
          org-records-mcp-list-computed-fields names
  files - Files and directories to search, replacing the allowed
          files (array of strings, optional)"
  (when (or (not (stringp query)) (string-empty-p query))
    (org-records-mcp--tool-validation-error
     "Query must be a non-empty string"))
  (let ((query-sexp
         (condition-case nil
             (read query)
           (error
            (org-records-mcp--tool-validation-error
             "Failed to parse query: %s"
             query)))))
    (unless (consp query-sexp)
      (org-records-mcp--tool-validation-error
       "Query must be a list, got: %s"
       (type-of query-sexp)))
    (org-records-mcp--with-file-set files
      ;; The three namespaces are resolved before the query runs, so
      ;; a misspelled name is refused rather than repeated per match.
      (org-records-mcp--run-query
       query-sexp
       (org-records-mcp--node-fields-given
        fields org-records-mcp-list-fields
        'org-records-mcp-list-fields)
       (org-records-mcp--node-properties-given properties nil)
       (org-records-mcp--node-computed-given
        computed org-records-mcp-list-computed-fields
        'org-records-mcp-list-computed-fields)
       nil))))

;; Views

(defconst org-records-mcp--view-parameters '(:filter :range)
  "The parameters a view declares, in the order its query takes them.
A view is called with the ones it declares and no others, so this
list is the calling convention as much as it is the vocabulary.")

(defun org-records-mcp--view-parameter-name (parameter)
  "Return PARAMETER, one of `org-records-mcp--view-parameters', as a call spells it."
  (substring (symbol-name parameter) 1))

(defun org-records-mcp--named-entry (name entries)
  "Return the entry of ENTRIES that NAME names, or nil.
ENTRIES is an alist the user configured, keyed by symbol, and NAME
is what a call sent.  The match is by name and never by `intern', so
nothing a call sends becomes a symbol."
  (let ((text (format "%s" name)))
    (cl-find
     text
     entries
     :key (lambda (entry) (format "%s" (car entry)))
     :test #'string=)))

(defun org-records-mcp--configured-names (entries)
  "Return the names ENTRIES are configured under, for a refusal message."
  (if entries
      (mapconcat (lambda (entry) (format "%s" (car entry))) entries
                 ", ")
    "none"))

(defun org-records-mcp--view (name)
  "Return the plist declaring the view NAME names, or refuse NAME.
The views are `org-records-mcp-views', which the user owns, so the refusal
names the views that are configured rather than a set this server
decided on."
  (or (cdr (org-records-mcp--named-entry name org-records-mcp-views))
      (org-records-mcp--tool-validation-error
       "Unknown view: %s.  Configured views: %s"
       name
       (org-records-mcp--configured-names org-records-mcp-views))))

(defun org-records-mcp--filter-query (name)
  "Return the org-ql sexp the filter NAME names, or refuse NAME.
The filters are `org-records-mcp-filters', a closed vocabulary, which is
what lets the refusal name every filter there is to ask for."
  (or (cdr
       (org-records-mcp--named-entry name org-records-mcp-filters))
      (org-records-mcp--tool-validation-error
       "Unknown filter: %s.  Configured filters: %s"
       name
       (org-records-mcp--configured-names org-records-mcp-filters))))

(defun org-records-mcp--view-ranges (declaration)
  "Return the range names the view DECLARATION takes, nil for none.
A view that takes one range is the common case, so DECLARATION may
name it as a bare symbol where the list of names would go, and the
two declare the same view."
  (ensure-list (plist-get declaration :range)))

(defun org-records-mcp--view-range (view name ranges)
  "Return the range a call naming NAME asks the view VIEW for.
RANGES are the range names that view declares, the first of them the
range it runs at when a call names none.  NAME is matched by name,
so the symbol the view's query receives is one RANGES holds and
never one made from what the call sent."
  (if (org-records-mcp--blank-param-p name)
      (car ranges)
    (or (cl-find
         (format "%s" name)
         ranges
         :key #'symbol-name
         :test #'string=)
        (org-records-mcp--tool-validation-error
         "Unknown range for the %s view: %s.  Its ranges: %s"
         view name (mapconcat #'symbol-name ranges ", ")))))

(defun org-records-mcp--view-refuses
    (view declaration parameter value)
  "Refuse VALUE, sent for a PARAMETER the view VIEW does not take.
DECLARATION is the plist declaring the view, and the refusal names
the parameters it does take, because those are what the caller has
to choose from.  A call that sent nothing is not refused, so a view
is simply run without the parameters it does not declare."
  (unless (org-records-mcp--blank-param-p value)
    (let ((taken
           (cl-remove-if-not
            (lambda (declared)
              (plist-get declaration declared))
            org-records-mcp--view-parameters)))
      (org-records-mcp--tool-validation-error
       "The %s view takes no %s.  %s"
       view
       (org-records-mcp--view-parameter-name parameter)
       (if taken
           (format
            "It takes: %s"
            (mapconcat #'org-records-mcp--view-parameter-name taken
                       ", "))
         "It takes no parameters")))))

(defun org-records-mcp--view-arguments (view declaration filter range)
  "Return the arguments the query of the view VIEW is called with.
DECLARATION is the plist declaring it; FILTER and RANGE are what the
call sent for those parameters.  The view is called with the
parameters it declares and no others, in the order
`org-records-mcp--view-parameters' has them.  One it does not declare is
refused rather than ignored: a caller that believes it narrowed a
search which in fact returned everything has no way to find out."
  (append
   (if (plist-get declaration :filter)
       (list
        (unless (org-records-mcp--blank-param-p filter)
          (org-records-mcp--filter-query filter)))
     (org-records-mcp--view-refuses view declaration :filter filter))
   (let ((ranges (org-records-mcp--view-ranges declaration)))
     (if ranges
         (list (org-records-mcp--view-range view range ranges))
       (org-records-mcp--view-refuses
        view
        declaration
        :range range)))))

(defun org-records-mcp--view-query (view declaration arguments)
  "Return the org-ql sexp the view VIEW asks, given ARGUMENTS.
DECLARATION is the plist declaring it.  Its `:query' is a function,
which ARGUMENTS are applied to, or a literal sexp, which a view
taking no parameters may carry instead.  A literal sexp has nowhere
to put an argument, so a view carrying one beside a parameter it
declares is refused rather than answered with a query that ignores
what the call asked."
  (let ((query (plist-get declaration :query)))
    (cond
     ((functionp query)
      (apply query arguments))
     ((null query)
      (org-records-mcp--tool-validation-error
       "The %s view declares no query"
       view))
     (arguments
      (org-records-mcp--tool-validation-error
       "The %s view carries a literal query, which the parameters it \
declares cannot reach"
       view))
     (t
      query))))

(defun org-records-mcp--tool-view
    (view &optional filter range fields properties computed)
  "Run the view named VIEW, restricted by FILTER, at the range RANGE.
VIEW names an entry of `org-records-mcp-views', FILTER one of
`org-records-mcp-filters', and RANGE one of the ranges that view declares; a
parameter the view does not declare is refused.

FIELDS says how much of each matching node to return, PROPERTIES
which of its Org drawer and COMPUTED which computed fields; see
`org-records-mcp--node-fields-given', `org-records-mcp--node-properties-given' and
`org-records-mcp--node-computed-given'.  A view answers in the same three
namespaces as org-query, and carries the same of each unasked: a
view is a query with a name, so a client that learned one reads the
other.

A view always runs over the allowed files: it takes no `files'
parameter, and mcp-server-lib refuses a call passing one before this
runs.

MCP Parameters:
  view - Name of the view to run (string, required)
  filter - Name of the filter to restrict it by (string, optional)
  range - Name of the range to run it at (string, optional);
          defaults to the range the view declares first
  fields - How much of each matching node to return (array of
          strings, or a string naming a configured list, optional);
          defaults to those org-records-mcp-list-fields names
  properties - Which Org drawer properties to return (array of
          property names, or \"all\" or \"none\", optional);
          defaults to none
  computed - Which computed fields to return (array of names, or
          \"all\" or \"none\", optional); defaults to those
          org-records-mcp-list-computed-fields names"
  (when (or (not (stringp view)) (string-empty-p view))
    (org-records-mcp--tool-validation-error
     "View must be a non-empty string"))
  (let* ((declaration (org-records-mcp--view view))
         (arguments
          (org-records-mcp--view-arguments
           view declaration filter range))
         ;; The three namespaces are resolved before the query runs,
         ;; so a misspelled name is refused rather than repeated per
         ;; match.
         (node-fields
          (org-records-mcp--node-fields-given
           fields org-records-mcp-list-fields
           'org-records-mcp-list-fields))
         (properties
          (org-records-mcp--node-properties-given properties nil))
         (computed
          (org-records-mcp--node-computed-given
           computed org-records-mcp-list-computed-fields
           'org-records-mcp-list-computed-fields)))
    ;; A view always runs over the allowed files: org-view takes no
    ;; `files' parameter, and mcp-server-lib refuses a call passing
    ;; one with an "Unexpected parameter" error before this runs.
    (org-records-mcp--with-file-set nil
      (org-records-mcp--run-query
       (org-records-mcp--view-query view declaration arguments)
       node-fields
       properties
       computed
       org-records-mcp-query-sort-fn))))

;; Read tools

(defun org-records-mcp--tool-node-read
    (link &optional fields depth properties computed files)
  "Tool handler for org-node-read.
LINK is a native Org link to a heading or a whole file.
FIELDS, when non-nil, says how much of the node to return; see
`org-records-mcp--node-fields-given'.
DEPTH, when non-nil, says how many generations of children to
expand in place; see `org-records-mcp--depth-given'.
PROPERTIES, when non-nil, says which of the node's Org drawer to
return; see `org-records-mcp--node-properties-given'.
COMPUTED, when non-nil, says which computed fields the node
returns; see `org-records-mcp--node-computed-given'.
FILES, when non-nil, names the files an `id:' LINK is looked up in;
see `org-records-mcp--link-target'.
Returns structured JSON.

MCP Parameters:
  link - Link to a heading or a file (string, required):
         - id:{id} (heading with that ID)
         - file:/path/to/file.org::#{custom-id} (heading with that
           CUSTOM_ID)
         - file:/path/to/file.org::*{title} (first heading with that
           title)
         - file:/path/to/file.org (whole file)
         - id:{id} of the file-level property drawer (whole file)
         - any of these bracketed, as [[link]] or [[link][description]]
  fields - How much of the node to return (array of strings, or a
          string naming a configured list, optional); defaults to
          every field but the two digests
  depth - How many generations of children to expand in place
          (integer, optional); defaults to none
  properties - Which Org drawer properties to return (array of
          property names, or \"all\" or \"none\", optional);
          defaults to all
  computed - Which computed fields to return (array of names, or
          \"all\" or \"none\", optional); defaults to all
  files - Files and directories to look up an id: link in, in order,
          instead of Emacs's ID index (array of strings, optional);
          refused with any other link"
  (org-records-mcp--read-structured link
                                    fields
                                    depth
                                    properties
                                    computed
                                    files))

(defun org-records-mcp--tool-node-text (link &optional files)
  "Tool handler for org-node-text.
LINK is a native Org link to a heading or a whole file.
FILES, when non-nil, names the files an `id:' LINK is looked up in;
see `org-records-mcp--link-target'.
Returns plain text content.

MCP Parameters:
  link - Link to a heading or a file (string, required):
         - id:{id} (heading with that ID)
         - file:/path/to/file.org::#{custom-id} (heading with that
           CUSTOM_ID)
         - file:/path/to/file.org::*{title} (first heading with that
           title)
         - file:/path/to/file.org (returns entire file)
         - id:{id} of the file-level property drawer (returns entire
           file)
         - any of these bracketed, as [[link]] or [[link][description]]
  files - Files and directories to look up an id: link in, in order,
          instead of Emacs's ID index (array of strings, optional);
          refused with any other link"
  (org-records-mcp--read-link link
                              "link"
                              #'org-records-mcp--node-text-at-point
                              #'org-records-mcp--read-file
                              files))

;; History

(defconst org-records-mcp--git-global-args
  '("--no-optional-locks"
    "--literal-pathspecs"
    "-c"
    "log.showSignature=false")
  "The options every git command a history runs is given first.
A history only reads, so git takes no optional lock, such as the one
refreshing the index, that a commit running beside it could trip
over.  A file name is a literal path, never a glob, and a user's
setting that has `git log' verify signatures does not add lines to
what is parsed.")

(defconst org-records-mcp--git-repository-variables
  '("GIT_ALTERNATE_OBJECT_DIRECTORIES"
    "GIT_CONFIG"
    "GIT_CONFIG_PARAMETERS"
    "GIT_CONFIG_COUNT"
    "GIT_OBJECT_DIRECTORY"
    "GIT_DIR"
    "GIT_WORK_TREE"
    "GIT_IMPLICIT_WORK_TREE"
    "GIT_GRAFT_FILE"
    "GIT_INDEX_FILE"
    "GIT_NO_REPLACE_OBJECTS"
    "GIT_REPLACE_REF_BASE"
    "GIT_PREFIX"
    "GIT_SHALLOW_FILE"
    "GIT_COMMON_DIR")
  "The variables that point git at a repository, unset for every git a history runs.
They are what `git rev-parse --local-env-vars' lists.  An Emacs
started with one of them set, as from a git hook, would otherwise
read the history of that repository rather than of the one the file
is committed in.")

(defun org-records-mcp--git (directory input &rest args)
  "Run git with ARGS in DIRECTORY and return (STATUS . OUTPUT).
INPUT, when non-nil, is a string git reads on its standard input.
OUTPUT is git's standard output as bytes, a unibyte string; its
standard error is discarded, since each caller says in its own words
what a failure means.  ARGS are passed as a list, never through a
shell, after `org-records-mcp--git-global-args'.  DIRECTORY is local:
the file of a link has a local truename by the time it gets here,
and git finds the repository from it alone, with
`org-records-mcp--git-repository-variables' unset.  No git on
`exec-path' is refused."
  (let ((git
         (or (executable-find "git")
             (org-records-mcp--tool-validation-error
              "No git on exec-path: org-node-history reads a file's \
history from git"))))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (let* ((default-directory (file-name-as-directory directory))
             (process-environment
              (append
               org-records-mcp--git-repository-variables
               process-environment))
             (coding-system-for-read 'binary)
             (coding-system-for-write 'binary)
             (args (append org-records-mcp--git-global-args args))
             (status
              (if input
                  (apply #'call-process-region
                         input
                         nil
                         git
                         nil
                         '(t nil)
                         nil
                         args)
                (apply #'call-process git nil '(t nil) nil args))))
        (cons status (buffer-string))))))

(defun org-records-mcp--git-line (directory &rest args)
  "Return the first line git ARGS print in DIRECTORY, or nil when git fails."
  (let ((result (apply #'org-records-mcp--git directory nil args)))
    (and (eql (car result) 0)
         (car (split-string (cdr result) "\n" t)))))

(defun org-records-mcp--history-since-given (since)
  "Return SINCE, a call's `since' parameter, as the bound it names.
The value is (commit . HASH), HASH a commit's hash as the call wrote
it in lower case, or (time . TIME), TIME an Emacs time.  A hash is 7
to 64 hexadecimal digits, which is every abbreviation git prints and
every full hash, SHA-1 or SHA-256.  A time is an ISO date or local
time, as the clock tools take one, see
`org-records-mcp--clock-parse-timestamp', or an Org timestamp, active
or inactive, whose day name is not read.  Anything else is refused,
naming the forms; so is a blank SINCE, as the required parameter it
is."
  (let ((since
         (string-trim
          (org-records-mcp--text-param-given since "since"))))
    (cond
     ((string-empty-p since)
      (org-records-mcp--missing-param-error "since"))
     ((let ((case-fold-search t))
        (string-match-p "\\`[0-9a-f]\\{7,64\\}\\'" since))
      (cons 'commit (downcase since)))
     ((string-match
       (concat
        "\\`[[<]\\([0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\)"
        "\\(?: +[^]>[:digit:][:space:]]+\\)?"
        "\\(?: +\\([0-9]\\{1,2\\}\\):\\([0-9]\\{2\\}\\)\\)? *[]>]\\'")
       since)
      (cons
       'time
       (org-records-mcp--clock-parse-timestamp
        (concat
         (match-string 1 since)
         (when (match-string 2 since)
           (format " %02d:%s"
                   (string-to-number (match-string 2 since))
                   (match-string 3 since)))))))
     ((string-match-p "\\`[0-9]\\{4\\}-" since)
      (cons 'time (org-records-mcp--clock-parse-timestamp since)))
     (t
      (org-records-mcp--tool-validation-error
       "Not a commit or a time: '%s'.  since takes a commit hash, \
such as the current of an earlier answer, an ISO time such as \
2026-10-07T16:00, or an Org timestamp such as [2026-10-07 Wed 16:00]"
       since)))))

(defun org-records-mcp--history-limit-given (limit)
  "Return LIMIT, a call's `limit' parameter, as a count, or nil for none.
A blank LIMIT, see `org-records-mcp--blank-param-p', and 0 ask for no
cap.  A whole number is that many revisions, and so is a string
holding one, which is how a client that sends every argument as a
string sends it.  Anything else is refused."
  (let ((count
         (cond
          ((org-records-mcp--blank-param-p limit)
           0)
          ((integerp limit)
           limit)
          ((and (stringp limit) (string-match-p "\\`[0-9]+\\'" limit))
           (string-to-number limit)))))
    (unless (and count (>= count 0))
      (org-records-mcp--tool-validation-error
       "limit must be a whole number of revisions, not: %s"
       (org-records-mcp--json-name limit)))
    (and (> count 0) count)))

(defun org-records-mcp--history-outline-path ()
  "Return the titles from the heading at point's outermost ancestor down.
The last title is the heading's own; each is the one
`org-records-mcp--title-at-point' reads.  Point does not move."
  (save-excursion
    (org-back-to-heading t)
    (let ((path (list (org-records-mcp--title-at-point))))
      (while (org-up-heading-safe)
        (push (org-records-mcp--title-at-point) path))
      path)))

(defun org-records-mcp--history-heading-at-point ()
  "Return the heading at point as a history follows it, a plist.
`:text' is its subtree as org-node-text reads it, `:path' its outline
path, see `org-records-mcp--history-outline-path', and `:id' and
`:custom-id' its own ID and CUSTOM_ID, nil when it carries none.
Neither is inherited, whatever `org-use-property-inheritance' says:
an ancestor's ID names the ancestor."
  (list
   :text (org-records-mcp--node-text-at-point)
   :path (org-records-mcp--history-outline-path)
   :id (org-entry-get nil "ID")
   :custom-id (org-entry-get nil "CUSTOM_ID")))

(defun org-records-mcp--history-repository (file)
  "Return the git repository FILE is committed in, as a plist.
`:directory' is the directory of FILE's truename, which every git
command runs in, `:name' the file's name there, which a path and an
object name are given relative to, `:root' the repository's top
directory, `:path' the file's path below it, as git names the files a
commit changed, and `:head' the commit HEAD names.  A FILE in no
repository, or in one with no commit, is refused."
  (let* ((truename (file-truename file))
         (directory (file-name-directory truename))
         (name (file-name-nondirectory truename))
         (result
          (org-records-mcp--git directory nil
                                "rev-parse"
                                "--show-toplevel"
                                "--show-prefix"))
         (lines
          (split-string (decode-coding-string (cdr result) 'utf-8)
                        "\n")))
    (unless (eql (car result) 0)
      (org-records-mcp--tool-validation-error
       "Not in a git repository: %s.  org-node-history reads a \
file's history from the git repository it is committed in"
       file))
    (list
     :directory directory
     :name name
     :root (file-name-as-directory (nth 0 lines))
     :path (concat (nth 1 lines) name)
     :head
     (or (org-records-mcp--git-line directory
                                    "rev-parse"
                                    "--verify"
                                    "--quiet"
                                    "HEAD^{commit}")
         (org-records-mcp--tool-validation-error
          "The git repository %s is in has no commit"
          file)))))

(defun org-records-mcp--history-object (commit repository)
  "Return the object name of REPOSITORY's file as COMMIT holds it."
  (concat commit ":./" (plist-get repository :name)))

(defun org-records-mcp--history-window (repository since file sent)
  "Return the revisions of REPOSITORY's file after SINCE, newest first.
SINCE is what `org-records-mcp--history-since-given' returns, and FILE
the file as the call reaches it and SENT the `since' the call sent,
for a refusal to name.  The value is
\(REVISIONS . BASE): REVISIONS a list of (COMMIT . TIME), one for each
commit on HEAD's first-parent line that changed the file, TIME the
committer time in seconds; BASE the object name of the file as it
stood before the oldest of them, or nil when there are none.

A time SINCE takes the commits committed at it or later, and BASE is
the file at the first parent of the oldest.  A commit SINCE takes the
commits after it, and BASE is the file at that commit: a commit HEAD
does not descend from is refused, since the commits after it are no
line of history.  The first-parent line makes consecutive revisions
each other's parent as far as the file goes, whatever merges the
history holds.  A window of more than
`org-records-mcp-history-max-revisions' revisions is refused."
  (let* ((directory (plist-get repository :directory))
         (max org-records-mcp-history-max-revisions)
         (commit
          (when (eq (car since) 'commit)
            (let ((full
                   (or (org-records-mcp--git-line directory
                                                  "rev-parse"
                                                  "--verify"
                                                  "--quiet"
                                                  (concat
                                                   (cdr since)
                                                   "^{commit}"))
                       (org-records-mcp--tool-validation-error
                        "No commit %s in the git repository %s is in"
                        sent file))))
              (unless (eql
                       (car
                        (org-records-mcp--git directory nil
                                              "merge-base"
                                              "--is-ancestor"
                                              full
                                              "HEAD"))
                       0)
                (org-records-mcp--tool-validation-error
                 "HEAD does not descend from commit %s: send a \
commit on the current branch, or a time"
                 sent))
              full)))
         (result
          (apply #'org-records-mcp--git
                 directory
                 nil
                 "log"
                 "--first-parent"
                 "--format=%H %ct"
                 "-n"
                 (number-to-string (1+ max))
                 (append
                  (if commit
                      (list (concat commit "..HEAD"))
                    (list
                     (format-time-string
                      "--since=%Y-%m-%d %H:%M:%S %z"
                      (cdr since))
                     "HEAD"))
                  (list "--" (plist-get repository :name)))))
         (revisions
          (mapcar
           (lambda (line)
             (let ((fields (split-string line " ")))
               (cons
                (nth 0 fields) (string-to-number (nth 1 fields)))))
           (split-string (cdr result) "\n" t))))
    (unless (eql (car result) 0)
      (org-records-mcp--tool-validation-error
       "git could not read the history of %s"
       file))
    (when (> (length revisions) max)
      (org-records-mcp--tool-validation-error
       "Too many revisions of %s: more than %d since %s.  Send a later \
since.  org-records-mcp-history-max-revisions sets the ceiling"
       file max sent))
    (cons
     revisions
     (when revisions
       (org-records-mcp--history-object
        (or commit
            (concat (car (car (last revisions))) "^"))
        repository)))))

(defun org-records-mcp--history-texts (repository objects coding)
  "Return the text of each of OBJECTS in REPOSITORY, nil for a missing one.
OBJECTS are object names, as `org-records-mcp--history-object' makes
them.  One `git cat-file --batch' reads them all, and each blob is
decoded with CODING, the coding system Emacs reads the file with."
  (let ((result
         (org-records-mcp--git (plist-get repository :directory)
                               (mapconcat (lambda (object)
                                            (concat object "\n"))
                                          objects
                                          "")
                               "cat-file" "--batch"))
        (texts nil))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert (cdr result))
      (goto-char (point-min))
      (dolist (_ objects)
        (let ((line (buffer-substring (point) (line-end-position))))
          (forward-line 1)
          (if (string-match "\\`[0-9a-f]+ blob \\([0-9]+\\)\\'" line)
              (let* ((start (point))
                     (end
                      (+ start
                         (string-to-number (match-string 1 line)))))
                (push (decode-coding-string
                       (buffer-substring start end) coding)
                      texts)
                ;; The blob is followed by a newline of git's own.
                (goto-char (1+ end)))
            (push nil texts)))))
    (nreverse texts)))

(defun org-records-mcp--history-headings ()
  "Return every heading in the current buffer as (BEGIN . PATH), in order.
PATH is the heading's outline path, its titles as
`org-records-mcp--title-at-point' reads them.  Org's parser finds the
headings and nests them; the titles of the headings above one are
those of the headings it was nested in."
  (let (enclosing
        headings)
    (org-element-map
     (org-element-parse-buffer 'headline) 'headline
     (lambda (headline)
       (let ((level (org-element-property :level headline))
             (begin (org-element-property :begin headline)))
         (while (and enclosing (>= (car (car enclosing)) level))
           (pop enclosing))
         (push (cons
                level
                (save-excursion
                  (goto-char begin)
                  (org-records-mcp--title-at-point)))
               enclosing)
         (push
          (cons begin (reverse (mapcar #'cdr enclosing))) headings))))
    (nreverse headings)))

(defun org-records-mcp--history-paths-equal-p (a b)
  "Return non-nil when outline paths A and B name the same headings."
  (and (= (length a) (length b))
       (cl-every #'org-records-mcp--titles-equal-p a b)))

(defun org-records-mcp--history-paths-in (text)
  "Return the outline path of every heading in file TEXT.
The current buffer is the scratch buffer of
`org-records-mcp--with-history-scratch', so TEXT is read with the
grammar it reads every revision with.  What the buffer held is put
back, so a position found in it before stays good after."
  (let ((held (buffer-string)))
    (erase-buffer)
    (insert text)
    (prog1 (mapcar #'cdr (org-records-mcp--history-headings))
      (erase-buffer)
      (insert held))))

(defun org-records-mcp--history-find-by-path (path seen-in)
  "Return where the heading at outline PATH begins, or nil.
The first heading whose outline path is PATH is the one, as the first
heading of a title is the one a `::*title' link reaches.  When none
is, a heading is found by its own title alone, if exactly one heading
in the buffer carries it: that follows a heading moved under another
parent, or one whose parent was renamed.

SEEN-IN is the file text the heading was last found in.  A heading
found by its title alone whose outline path SEEN-IN still holds is
another heading, standing where it stood, and nil is returned: a
heading written beside one of the same title did not move there."
  (let ((headings (org-records-mcp--history-headings)))
    (or (car
         (cl-find-if
          (lambda (heading)
            (org-records-mcp--history-paths-equal-p
             (cdr heading) path))
          headings))
        (let ((titled
               (cl-remove-if-not
                (lambda (heading)
                  (org-records-mcp--titles-equal-p
                   (car (last (cdr heading))) (car (last path))))
                headings)))
          (and titled
               (null (cdr titled))
               (not
                (cl-find
                 (cdr (car titled))
                 (org-records-mcp--history-paths-in seen-in)
                 :test #'org-records-mcp--history-paths-equal-p))
               (car (car titled)))))))

(defun org-records-mcp--history-find (identity seen-in)
  "Return where the heading IDENTITY names begins in the current buffer.
IDENTITY is a plist as `org-records-mcp--history-heading-at-point'
returns one, and SEEN-IN the file text it was found in.  The heading
is found by its ID, else by its CUSTOM_ID, else by its outline path,
see `org-records-mcp--history-find-by-path'.  A heading found by its path
whose own ID or CUSTOM_ID differs from one IDENTITY carries is
another heading, and nil is returned: an identifier names one heading
for as long as it is there.  Nil also when nothing matches."
  (let ((id (plist-get identity :id))
        (custom-id (plist-get identity :custom-id)))
    (or (and id (org-find-entry-with-id id))
        (and custom-id (org-find-property "CUSTOM_ID" custom-id))
        (when-let* ((begin
                     (org-records-mcp--history-find-by-path
                      (plist-get identity :path) seen-in)))
          (save-excursion
            (goto-char begin)
            (cl-flet ((agrees
                       (ours property)
                       (let ((theirs (org-entry-get nil property)))
                         (or (null ours)
                             (null theirs)
                             (string= ours theirs)))))
              (and (agrees id "ID")
                   (agrees custom-id "CUSTOM_ID")
                   begin)))))))

(defun org-records-mcp--history-locate (text identity)
  "Return the heading IDENTITY names in file TEXT, or nil.
IDENTITY is a heading as this returns one, or as
`org-records-mcp--history-heading-at-point' does with `:file-text'
added, the text of the file it was found in.  The current buffer is
the scratch buffer of `org-records-mcp--with-history-scratch'; TEXT
replaces its content.  The heading is returned with `:file-text'
TEXT, and nil when TEXT is nil, a revision without the file, or
holds no such heading."
  (when text
    (erase-buffer)
    (insert text)
    (goto-char (point-min))
    (when-let* ((begin
                 (org-records-mcp--history-find
                  identity (plist-get identity :file-text))))
      (goto-char begin)
      (append
       (org-records-mcp--history-heading-at-point)
       (list :file-text text)))))

(defmacro org-records-mcp--with-history-scratch (grammar &rest body)
  "Run BODY in an Org buffer of its own that reads with GRAMMAR.
GRAMMAR is the setting lines `org-records-mcp--headline-grammar-settings'
returns for the file whose history is read, so every revision is read
with the keywords and priorities the file has now, and no revision's
`#+SETUPFILE:' is fetched.  The mode's hooks and startup options do
not run, and the element cache is off, since each revision replaces
the whole buffer."
  (declare (indent 1) (debug (form body)))
  `(with-temp-buffer
     (let ((org-inhibit-startup t))
       (delay-mode-hooks
         (org-mode)))
     (setq-local org-element-use-cache nil)
     (insert ,grammar)
     (org-set-regexps-and-options)
     ,@body))

(defun org-records-mcp--history-edits (old new)
  "Return the edits turning the list of lines OLD into NEW.
Each edit is (OP . LINE), OP one of the characters ?\\s, ?- and ?+
that start a line of a unified diff, in order.  The lines both share
at the start and at the end are kept as they are, and a longest
common subsequence of the rest decides what is kept between.

Emacs has no diff of its own to call: `diff' runs a program over
files, which a history does not write.  When the lines between are
too many to compare in reasonable space, every one of them is taken
out and put back rather than compared."
  (let* ((a (vconcat old))
         (b (vconcat new))
         (n (length a))
         (m (length b))
         (head 0)
         (tail 0))
    (while (and (< head n)
                (< head m)
                (equal (aref a head) (aref b head)))
      (cl-incf head))
    (while (and (< tail (- n head))
                (< tail (- m head))
                (equal (aref a (- n tail 1)) (aref b (- m tail 1))))
      (cl-incf tail))
    (let* ((rows (- n head tail))
           (columns (- m head tail))
           (width (1+ columns))
           (edits nil))
      (dotimes (i head)
        (push (cons ?\s (aref a i)) edits))
      (if (> (* rows columns) 4000000)
          (progn
            (dotimes (i rows)
              (push (cons ?- (aref a (+ head i))) edits))
            (dotimes (j columns)
              (push (cons ?+ (aref b (+ head j))) edits)))
        ;; LENGTHS at (I, J) is the length of the longest common
        ;; subsequence of what follows line I of the old middle and
        ;; line J of the new one.
        (let ((lengths (make-vector (* (1+ rows) width) 0))
              (i 0)
              (j 0))
          (cl-loop
           for row from (1- rows) downto 0 do
           (cl-loop
            for column from (1- columns) downto 0 do
            (aset
             lengths (+ (* row width) column)
             (if (equal
                  (aref a (+ head row)) (aref b (+ head column)))
                 (1+ (aref
                      lengths (+ (* (1+ row) width) (1+ column))))
               (max (aref lengths (+ (* (1+ row) width) column))
                    (aref lengths (+ (* row width) (1+ column))))))))
          (while (or (< i rows) (< j columns))
            (cond
             ((and (< i rows)
                   (< j columns)
                   (equal (aref a (+ head i)) (aref b (+ head j))))
              (push (cons ?\s (aref a (+ head i))) edits)
              (cl-incf i)
              (cl-incf j))
             ((and (< i rows)
                   (or (= j columns)
                       (>= (aref lengths (+ (* (1+ i) width) j))
                           (aref lengths (+ (* i width) (1+ j))))))
              (push (cons ?- (aref a (+ head i))) edits)
              (cl-incf i))
             (t
              (push (cons ?+ (aref b (+ head j))) edits)
              (cl-incf j))))))
      (dotimes (i tail)
        (push (cons ?\s (aref a (+ (- n tail) i))) edits))
      (nreverse edits))))

(defconst org-records-mcp--history-context 3
  "The lines of context around each change in a history's diff.
Three is what `diff -u' and `git diff' show.")

(defun org-records-mcp--history-diff (old new)
  "Return the unified diff from text OLD to text NEW, or nil when equal.
Either may be nil, for a heading that is not there.  The diff is
hunks alone, each under its `@@ -L,S +L,S @@' line, with
`org-records-mcp--history-context' lines of context, and its lines are
joined by newlines with none after the last.  A range of one line is
written by its line alone, and an empty one by the line before it,
as `diff -u' writes them."
  (let* ((edits
          (vconcat
           (org-records-mcp--history-edits
            (and old (split-string old "\n"))
            (and new (split-string new "\n")))))
         (count (length edits))
         (old-before (make-vector (1+ count) 0))
         (new-before (make-vector (1+ count) 0))
         (changes nil)
         (hunks nil))
    (dotimes (k count)
      (let ((op (car (aref edits k))))
        (aset
         old-before (1+ k)
         (+ (aref old-before k)
            (if (eq op ?+)
                0
              1)))
        (aset
         new-before (1+ k)
         (+ (aref new-before k)
            (if (eq op ?-)
                0
              1)))
        (unless (eq op ?\s)
          (push k changes))))
    (setq changes (nreverse changes))
    (cl-flet ((range
               (before size)
               (cond
                ((= size 1)
                 (format "%d" (1+ before)))
                ((= size 0)
                 (format "%d,0" before))
                (t
                 (format "%d,%d" (1+ before) size)))))
      (while changes
        (let* ((start
                (max 0
                     (- (car changes)
                        org-records-mcp--history-context)))
               (end
                (min count
                     (+ (car changes) 1
                        org-records-mcp--history-context))))
          (setq changes (cdr changes))
          (while (and changes
                      (<= (- (car changes)
                             org-records-mcp--history-context)
                          end))
            (setq end
                  (min count
                       (+ (car changes) 1
                          org-records-mcp--history-context)))
            (setq changes (cdr changes)))
          (push (concat
                 (format "@@ -%s +%s @@"
                         (range
                          (aref old-before start)
                          (- (aref old-before end)
                             (aref old-before start)))
                         (range
                          (aref new-before start)
                          (- (aref new-before end)
                             (aref new-before start))))
                 (mapconcat (lambda (k)
                              (let ((edit (aref edits k)))
                                (concat
                                 "\n"
                                 (string (car edit))
                                 (cdr edit))))
                            (number-sequence start (1- end))
                            ""))
                hunks))))
    (and hunks (string-join (nreverse hunks) "\n"))))

(defun org-records-mcp--history-path-text (path)
  "Return outline PATH, a list of titles, as a note names it."
  (if path
      (string-join path " / ")
    "the top level"))

(defun org-records-mcp--history-change (older newer)
  "Return what changed from OLDER to NEWER, or nil when nothing did.
Each is a heading as `org-records-mcp--history-locate' returns one, or
nil where the revision has none.  The value is an alist of `note',
present when the heading appears, disappears or moves to another
parent, and `diff', present when its subtree's text changed."
  (let* ((diff
          (org-records-mcp--history-diff
           (plist-get older :text) (plist-get newer :text)))
         (older-parent (butlast (plist-get older :path)))
         (newer-parent (butlast (plist-get newer :path)))
         (note
          (cond
           ((and newer (not older))
            "appears")
           ((and older (not newer))
            "disappears")
           ((and older
                 newer
                 (not
                  (org-records-mcp--history-paths-equal-p
                   older-parent newer-parent)))
            (format "moves from %s to %s"
                    (org-records-mcp--history-path-text older-parent)
                    (org-records-mcp--history-path-text
                     newer-parent))))))
    (when (or note diff)
      `(,@
        (when note
          `((note . ,note)))
        ,@
        (when diff
          `((diff . ,diff)))))))

(defun org-records-mcp--history-holds-p (text heading)
  "Return non-nil when file TEXT holds a heading with HEADING's ID or CUSTOM_ID.
HEADING is a plist as `org-records-mcp--history-locate' returns one.
TEXT replaces the content of the current buffer, the scratch buffer
of `org-records-mcp--with-history-scratch'."
  (when text
    (erase-buffer)
    (insert text)
    (let ((id (plist-get heading :id))
          (custom-id (plist-get heading :custom-id)))
      (or (and id (org-find-entry-with-id id))
          (and custom-id
               (org-find-property "CUSTOM_ID" custom-id))))))

(defun org-records-mcp--history-elsewhere
    (repository commit heading arrived)
  "Return the other file HEADING moved between at COMMIT, or nil.
REPOSITORY is the file's, and HEADING, as
`org-records-mcp--history-locate' returns one, appears in the file at
COMMIT when ARRIVED is non-nil and disappears from it otherwise.  The
other file is one of the Org files COMMIT changed that held HEADING's
ID or CUSTOM_ID before COMMIT and not after, when it arrived, or after
and not before, when it left: one commit took the heading out of one
file and wrote it into the other.  A heading carrying neither
identifier is not looked for, and a root commit changed no file from
another.

The file is returned as the path the call may reach it by, through
`org-records-mcp--find-allowed-file' as a file the call names, and nil
is returned for one the call may not reach, so a history names no
file a read would refuse.  The current buffer is the scratch buffer
of `org-records-mcp--with-history-scratch'."
  (when (or (plist-get heading :id) (plist-get heading :custom-id))
    (let* ((result
            (org-records-mcp--git (plist-get
                                   repository
                                   :directory)
                                  nil
                                  "diff-tree"
                                  "-r"
                                  "-z"
                                  "--name-only"
                                  (concat commit "^")
                                  commit))
           (paths
            (and (eql (car result) 0)
                 (seq-filter
                  (lambda (path)
                    (and
                     (org-records-mcp--org-file-name-p path)
                     (not
                      (string= path (plist-get repository :path)))))
                  (split-string (decode-coding-string
                                 (cdr result) 'utf-8)
                                "\0" t))))
           (texts
            (and paths
                 (org-records-mcp--history-texts
                  repository
                  (mapcan
                   (lambda (path)
                     (list
                      (concat commit "^:" path)
                      (concat commit ":" path)))
                   paths)
                  'utf-8))))
      (cl-loop
       for path in paths for (before after) on texts by #'cddr when
       (and (if arrived
                (org-records-mcp--history-holds-p before heading)
              (org-records-mcp--history-holds-p after heading))
            (not
             (if arrived
                 (org-records-mcp--history-holds-p after heading)
               (org-records-mcp--history-holds-p before heading))))
       return
       (org-records-mcp--find-allowed-file (expand-file-name
                                            path
                                            (plist-get
                                             repository
                                             :root))
                                           t)))))

(defun org-records-mcp--history-revisions
    (revisions texts newest identity limit repository)
  "Return the revisions that changed a heading, newest first.
REVISIONS are (COMMIT . TIME) pairs, newest first, and TEXTS the file
as each of them holds it, followed by the file as it stood before the
oldest.  NEWEST is the heading as the newest of TEXTS holds it, as
`org-records-mcp--history-locate' returns one, or nil when it holds
none, and IDENTITY the heading as Emacs holds it now, which it was
found by.  LIMIT, when non-nil, is the most revisions to return.  The
current buffer is the scratch buffer of
`org-records-mcp--with-history-scratch'.  REPOSITORY is the file's,
which a heading appearing or disappearing is looked for elsewhere in,
see `org-records-mcp--history-elsewhere'.

The walk goes back one revision at a time, finding the heading in
each older text by what the newer one says of it, so a heading
renamed while it carries an ID or a CUSTOM_ID is followed past the
rename.  Where the older text lacks it, the search goes on with what
the heading was last seen as.  The value is (ENTRIES . COMPLETE),
COMPLETE nil when LIMIT stopped the walk before the oldest revision."
  (let ((newer newest)
        (identity (or newest identity))
        (entries nil)
        (rest revisions)
        (older-texts (cdr texts)))
    (while (and rest (not (and limit (>= (length entries) limit))))
      (let* ((revision (car rest))
             (older
              (org-records-mcp--history-locate
               (car older-texts) identity))
             (change (org-records-mcp--history-change older newer))
             (note (alist-get 'note change))
             (elsewhere
              (and (member note '("appears" "disappears"))
                   (org-records-mcp--history-elsewhere
                    repository
                    (car revision)
                    (or newer older)
                    (equal note "appears")))))
        (when elsewhere
          (setf (alist-get 'note change)
                (concat
                 (if (equal note "appears")
                     "moves from "
                   "moves to ")
                 elsewhere)))
        (when change
          (push `((revision . ,(car revision))
                  (time
                   .
                   ,(format-time-string "%Y-%m-%dT%H:%M:%S"
                                        (cdr revision)))
                  ,@change)
                entries))
        (when older
          (setq identity older))
        (setq newer older)
        (setq rest (cdr rest))
        (setq older-texts (cdr older-texts))))
    (cons (nreverse entries) (null rest))))

(defun org-records-mcp--tool-node-history
    (link since &optional limit files)
  "Tool handler for org-node-history.
LINK is a native Org link to a heading, SINCE the bound the history
starts after, see `org-records-mcp--history-since-given', LIMIT the
most revisions to return, see `org-records-mcp--history-limit-given',
and FILES the files an `id:' LINK is looked up in, see
`org-records-mcp--link-target'.  Returns structured JSON.

The heading is found as a read finds it, in the buffer visiting its
file, which is read and never changed.  The file's revisions come from
the git repository it is committed in, and each is read into a
scratch buffer, never into a buffer visiting the file; nothing is
written anywhere.

MCP Parameters:
  link - Link to a heading (string, required):
         - id:{id} (heading with that ID)
         - file:/path/to/file.org::#{custom-id} (heading with that
           CUSTOM_ID)
         - file:/path/to/file.org::*{title} (first heading with that
           title)
         - any of these bracketed, as [[link]] or [[link][description]]
  since - The bound the history starts after (string, required): a
          commit hash, or a time
  limit - The most revisions to return, the newest (integer,
          optional); defaults to no cap
  files - Files and directories to look up an id: link in, in order,
          instead of Emacs's ID index (array of strings, optional);
          refused with any other link"
  (let* ((target (org-records-mcp--link-target link "link" files))
         (file (plist-get target :file))
         (heading nil)
         (grammar nil)
         (coding nil)
         (link nil))
    (org-records-mcp--with-org-file file
      (org-records-mcp--goto-heading target)
      (setq heading
            (append
             (org-records-mcp--history-heading-at-point)
             (list
              :file-text
              (buffer-substring-no-properties
               (point-min) (point-max)))))
      (setq link (org-records-mcp--link-at-point))
      (setq grammar (org-records-mcp--headline-grammar-settings))
      (setq coding buffer-file-coding-system))
    (let* ((sent since)
           (since (org-records-mcp--history-since-given since))
           (limit (org-records-mcp--history-limit-given limit))
           (repository (org-records-mcp--history-repository file))
           (head (plist-get repository :head))
           (window
            (org-records-mcp--history-window
             repository since file sent))
           (revisions (car window))
           (texts
            (org-records-mcp--history-texts
             repository
             `(,(org-records-mcp--history-object head repository)
               ,@
               (mapcar
                (lambda (revision)
                  (org-records-mcp--history-object
                   (car revision) repository))
                revisions)
               ,@ (and (cdr window) (list (cdr window))))
             coding)))
      (unless (car texts)
        (org-records-mcp--tool-validation-error
         "%s is not committed in the git repository it is in"
         file))
      (org-records-mcp--with-history-scratch grammar
        (let* ((newest
                (org-records-mcp--history-locate (car texts) heading))
               (walk
                (org-records-mcp--history-revisions
                 revisions
                 (cdr texts)
                 newest
                 heading
                 limit
                 repository)))
          (json-encode
           `((link . ,link)
             (file . ,file) (current . ,head)
             (complete
              .
              ,(if (cdr walk)
                   t
                 :json-false))
             (uncommitted
              .
              ,(if (equal
                    (plist-get newest :text)
                    (plist-get heading :text))
                   :json-false t))
             (revisions . ,(vconcat (car walk))))))))))

;; Clock tools

(defun org-records-mcp--tool-config-clock ()
  "Return the clock configuration.

MCP Parameters: None"
  (json-encode
   `((org_clock_into_drawer
      . ,(prin1-to-string org-clock-into-drawer))
     (org_clock_rounding_minutes . ,org-clock-rounding-minutes)
     (org_clock_continuously
      .
      ,(if org-clock-continuously
           t
         :json-false))
     (org_records_mcp_clock_continuous_threshold
      . ,org-records-mcp-clock-continuous-threshold))))

(defun org-records-mcp--tool-clock-dangling (&optional files)
  "Find all open (unclosed) clocks in a set of Org files.
The files are the ones FILES names, see `org-records-mcp--with-file-set',
or the allowed files when FILES is nil.
Uses `org-find-open-clocks' on each of them, in full even where the
user's buffer is narrowed; see `org-records-mcp--with-wide-clock-buffer'.
Reads each clock's timestamp via the Org element API.

MCP Parameters:
  files - Files and directories to search, replacing the allowed
          files (array of strings, optional)"
  (org-records-mcp--with-file-set files
    (let ((all-clocks nil))
      (dolist (file org-agenda-files)
        (org-records-mcp--with-wide-clock-buffer file
          (let ((open (org-find-open-clocks file)))
            (dolist (clock open)
              (let ((marker (car clock))
                    (clock-file (expand-file-name file)))
                (with-current-buffer (marker-buffer marker)
                  (save-excursion
                    (goto-char marker)
                    (let*
                        ((el (org-element-at-point))
                         (start-str
                          (when (eq (org-element-type el) 'clock)
                            (org-records-mcp--clock-element-start-str
                             el)))
                         (heading
                          (save-excursion
                            (org-back-to-heading t)
                            (org-records-mcp--title-at-point))))
                      (push `((file . ,clock-file)
                              (heading . ,heading)
                              (start . ,start-str)
                              (link
                               . ,(org-records-mcp--link-at-point)))
                            all-clocks)))))))))
      (let ((total (length all-clocks)))
        (json-encode
         `((open_clocks . ,(vconcat (nreverse all-clocks)))
           (total . ,total)))))))

(defun org-records-mcp--tool-clock-active ()
  "Return the currently active clock entry, if any.

MCP Parameters: None"
  (let ((active (org-records-mcp--clock-find-active)))
    (if active
        (if (eq (alist-get 'allowed active) nil)
            (json-encode
             '((active . t) (in_allowed_file . :json-false)))
          (let ((marker (alist-get 'marker active)))
            (json-encode
             `((active . t)
               (file . ,(alist-get 'file active))
               (heading . ,(alist-get 'heading active))
               (start . ,(alist-get 'start active))
               (link
                .
                ,(with-current-buffer (marker-buffer marker)
                   (org-with-wide-buffer
                    (goto-char marker)
                    (org-records-mcp--link-at-point))))))))
      (json-encode '((active . :json-false))))))

(defun org-records-mcp--tool-clock-in
    (link &optional start_time resolve files clock_out)
  "Clock in to the heading LINK names.
LINK must name a heading in the allowed files, even where
`org-records-mcp-file-scope-override' reaches further: the clock it
starts outlives the call, and `org-records-mcp--clock-find-active' looks
for a clock in the allowed files alone, so one started anywhere else
would run unseen by org-clock-active and org-clock-out.
While a clock runs, CLOCK_OUT must name its heading, see
`org-records-mcp--clock-check-clock-out', and that clock is closed first, at
the new clock's start, which must not precede its own.  LINK,
START_TIME, RESOLVE and CLOCK_OUT are all checked before that, so a
refused call changes nothing.  Once that clock is closed, a save of it
that fails ends the call saying so, see `org-records-mcp--clock-save-closed'.
When `org-clock-continuously' is non-nil and no explicit START_TIME
is given, the new clock may start at the previous clock's end time
if it is within `org-records-mcp-clock-continuous-threshold' minutes.
When RESOLVE is true, the dangling CLOCK lines of the target heading
are deleted before clocking in: the open lines of its own entry other
than the running clock, which is closed, never deleted.  One on a
descendant is left to a call naming that descendant, so the response's
`resolved' counts the heading LINK names and nothing under it; see
`org-records-mcp--clock-resolve-dangling'.
FILES, when non-nil, names the files an `id:' LINK is looked up in;
see `org-records-mcp--link-target'.  It does not apply to CLOCK_OUT.

MCP Parameters:
  link - Link to the node to clock in
         Formats:
           - id:{id}
           - file:{absolute-path}::#{custom-id}
           - file:{absolute-path}::*{title} (first match)
           - any of these as [[link]] or [[link][description]]
  start_time - Optional ISO 8601 start time (e.g. 2026-03-23T14:30:00),
          naming a time that exists; left out, or \"\" or
          whitespace, the current time
  resolve - true to delete dangling clocks before clocking in;
            false, or leaving it out, means not to
  files - Files and directories to look up an id: link in, in order,
          instead of Emacs's ID index (array of strings, optional);
          refused with any other link
  clock_out - Link to the heading of the running clock, which is
              closed first; required while a clock runs, refused
              while none does"
  (setq start_time
        (org-records-mcp--optional-text-given
         start_time "start_time"))
  (let* ((target (org-records-mcp--link-target link "link" files))
         (file-path (plist-get target :file))
         (resolve (org-records-mcp--boolean-param resolve "resolve"))
         (now (current-time))
         (explicit-start
          (when start_time
            (org-records-mcp--clock-parse-timestamp start_time)))
         ;; The running clock closes where the new one starts.
         (close-at
          (org-records-mcp--clock-round-time (or explicit-start now)))
         (active (org-records-mcp--clock-find-active))
         (running-start
          (and active
               (org-time-string-to-time (alist-get 'start active))))
         ;; Closing the running clock may edit another buffer that
         ;; already had unsaved edits; `saved' covers that edit too.
         (org-records-mcp--unsaved-change-p nil))
    ;; A running clock outlives the call that starts it, and a scope
    ;; override lasts for that call alone: org-clock-active and
    ;; org-clock-out look for a clock in the allowed files only, so
    ;; one started in a file the override reaches would run where no
    ;; later call finds it.
    (unless (org-records-mcp--find-allowed-file file-path)
      (org-records-mcp--tool-validation-error
       "'%s': a clock starts only in the allowed files, where \
org-clock-active and org-clock-out find it"
       (plist-get target :link)))
    ;; Every check runs before any clock is closed, so a refused call
    ;; changes nothing: a link that names no heading, such as
    ;; file:…::*Nope, is refused with the running clock intact.
    (org-records-mcp--with-org-file file-path
      (org-records-mcp--goto-heading target))
    (org-records-mcp--clock-check-clock-out active clock_out)
    (when (and active (time-less-p close-at running-start))
      (org-records-mcp--tool-validation-error
       "Start time %s is before the running clock's start %s"
       (org-records-mcp--clock-format-timestamp close-at)
       (org-records-mcp--clock-format-timestamp running-start)))
    (when active
      (let* ((marker (alist-get 'marker active))
             (buf (marker-buffer marker))
             (was-modified (buffer-modified-p buf))
             (tick (buffer-chars-modified-tick buf)))
        ;; The close is Org's, so `org-log-note-clock-out' records it
        ;; here as it does for a clock-out by hand, and the record is
        ;; written before the buffer is saved rather than left on
        ;; `post-command-hook'.
        (org-records-mcp--logging-note nil
          (org-records-mcp--repeat-catching-up
            (org-clock-clock-out
             (cons marker running-start) t close-at)))
        (org-records-mcp--clock-save-closed
         buf (alist-get 'file active) was-modified)
        ;; Only an edit that reached BUF can stay unsaved, and it has
        ;; not when a hook saved BUF.
        (when (and (/= tick (buffer-chars-modified-tick buf))
                   (buffer-modified-p buf))
          (setq org-records-mcp--unsaved-change-p t))))
    ;; Determine start time
    (let* ((continuous-start
            (when (and org-clock-continuously (not explicit-start))
              ;; A clock-out still to come is not one this clock-in
              ;; follows, so the latest one at or before the present
              ;; is.  Where the close above wrote the running clock's
              ;; end after the present, as rounding can, the present
              ;; reaches that end, because it is the one the new
              ;; clock continues from.  No other clock gains from it.
              (let* ((present
                      (if (and active (time-less-p now close-at))
                          close-at
                        now))
                     (last-end
                      (org-records-mcp--clock-find-last-closed
                       present)))
                (when last-end
                  (let ((elapsed
                         (float-time (time-subtract now last-end))))
                    (when
                        (<=
                         elapsed
                         (*
                          60
                          org-records-mcp-clock-continuous-threshold))
                      last-end))))))
           (clock-start
            (org-records-mcp--clock-round-time
             (or explicit-start continuous-start now))))
      (let ((resolved-count 0))
        (org-records-mcp--modify-and-save file-path
            "clock-in"
            `((clocked_in . t)
              (start
               .
               ,(org-records-mcp--clock-format-timestamp clock-start))
              (heading . ,(org-records-mcp--title-at-point)) ,@
              (when (> resolved-count 0)
                `((resolved . ,resolved-count))))
          (org-records-mcp--goto-heading target)
          (when resolve
            (setq resolved-count
                  (org-records-mcp--clock-resolve-dangling)))
          (org-records-mcp--clock-insert-entry clock-start))))))

(defun org-records-mcp--tool-clock-out
    (link &optional end_time files note)
  "Clock out the clock LINK names, which has to be the running one.
LINK is this call's guard: a clock operation asserts which clock it
changes rather than a value it overwrites, so a LINK naming any
heading but the one the running clock sits under is refused as a
conflict and nothing is closed.  Without it the call would close
whichever clock happens to be running, which may be one the user
started in Emacs and the client never saw.  The link
`org-records-mcp--tool-clock-active' reports for the running clock names it;
see `org-records-mcp--clock-names-running-p' for the rest.
A clock running in a file outside the allowed files is refused, as
clocking in refuses it: org-records-mcp starts no clock outside them, and
the refusal names neither that file nor the heading and start of the clock
it holds, which `org-records-mcp--tool-clock-active' withholds too.  That
refusal comes before LINK is looked at, so it reveals nothing about
the clock either way.
The clock is closed through Org, so Emacs's own clock stops with it
and Org's clock-out settings decide what the file ends up holding:
`org-clock-out-remove-zero-time-clocks' deletes a CLOCK line of no
length, and the drawer it empties, and `org-clock-out-switch-to-state'
rewrites the heading's TODO keyword.  The response reports neither; it
reports the close org-records-mcp asked for.
END_TIME is an optional ISO 8601 end time (e.g. 2026-03-23T16:45:00).
FILES, when non-nil, names the files an `id:' LINK is looked up in;
see `org-records-mcp--link-target'.
NOTE is prose to record against the clock being closed, or none.
`org-string-nw-p' is what reads it, so every blank the call can spell
-- \"\", null, false, [] and a string of whitespace -- is a note the
call does not send, and no entry is written for one.

MCP Parameters:
  link - Link to the heading the running clock is on
         Formats:
           - id:{id}
           - file:{absolute-path}::#{custom-id}
           - file:{absolute-path}::*{title} (first match)
           - any of these as [[link]] or [[link][description]]
  end_time - Optional ISO 8601 end time (e.g. 2026-03-23T16:45:00),
          naming a time that exists; left out, or \"\" or
          whitespace, the current time
  files - Files and directories to look up an id: link in, in order,
          instead of Emacs's ID index (array of strings, optional);
          refused with any other link
  note - Prose to record against the clock being closed (string,
         optional); an empty or whitespace-only note records nothing"
  ;; The call is checked before the world is: a `link' the client did
  ;; not send is a malformed call, and answering it with the state of
  ;; the clock would report on something the call never got to ask
  ;; about.
  (setq link (org-records-mcp--link-given link "link"))
  (setq end_time
        (org-records-mcp--optional-text-given end_time "end_time"))
  (setq note (org-string-nw-p note))
  (let ((active (org-records-mcp--clock-find-active)))
    (unless active
      (org-records-mcp--tool-conflict-error
       "No active clock to stop"))
    (unless (alist-get 'allowed active)
      (org-records-mcp--tool-validation-error
       "A clock is running in a file outside the allowed files.  Ask \
the user to clock out of it in Emacs"))
    (unless (org-records-mcp--clock-names-running-p
             active
             (org-records-mcp--link-target link "link" files))
      (org-records-mcp--tool-conflict-error
       "link does not name the running clock: %s.  The clock runs \
on %s"
       link (org-records-mcp--clock-describe-running active)))
    (let* ((active-file (alist-get 'file active))
           (now (current-time))
           (end
            (if end_time
                (org-records-mcp--clock-round-time
                 (org-records-mcp--clock-parse-timestamp end_time))
              (org-records-mcp--clock-round-time now)))
           (start-str (alist-get 'start active))
           (start-parsed (org-parse-time-string start-str))
           (start-time (apply #'encode-time start-parsed)))
      ;; Validate end is after start
      (when (time-less-p end start-time)
        (org-records-mcp--tool-validation-error
         "End time %s is before start time %s"
         (org-records-mcp--clock-format-timestamp end)
         (format "[%s]" start-str)))
      (let ((duration (float-time (time-subtract end start-time))))
        (org-records-mcp--modify-and-save
            active-file "clock-out"
            `((clocked_out . t)
              (heading . ,(alist-get 'heading active))
              (start . ,start-str)
              (end . ,(org-records-mcp--clock-format-timestamp end))
              (duration
               . ,(org-records-mcp--clock-duration-string duration)))
          ;; Org writes the close itself, so every CLOCK line it reads
          ;; as a clock is closed, its clock-out settings apply as they
          ;; do to an interactive clock-out, and the Emacs clock the
          ;; line belongs to stops: `org-clock-marker' is left unset
          ;; rather than pointing at a closed clock, which a later
          ;; clock-in would read as a clock still running.
          (let* ((marker (alist-get 'marker active))
                 ;; Org unsets the clock's marker as it closes it, so
                 ;; the heading is found while the marker still lives.
                 ;; It keeps its place: Org writes below it, and takes
                 ;; away no more than the CLOCK line and its drawer.
                 (heading
                  (save-excursion
                    (goto-char (marker-position marker))
                    (org-back-to-heading t)
                    (point))))
            ;; `org-log-note-clock-out' records the close, and
            ;; `org-clock-out-switch-to-state' can put the heading in
            ;; another TODO state, which its own log settings record;
            ;; both are written here rather than left waiting on
            ;; `post-command-hook'.
            ;;
            ;; A NOTE is the prose of the entry that setting asks Org
            ;; to set up, so a call carrying one turns the setting on
            ;; for its own close and Org places the entry where it
            ;; places every clock-out entry: against the clock line it
            ;; belongs to, in whatever drawer that line sits in.  The
            ;; rule that a clock line taken away takes its entry with
            ;; it is Org's, and holds here as it does by hand:
            ;; `org-clock-out-remove-zero-time-clocks' deleting the
            ;; line leaves nothing for a note to be about.
            (let ((org-log-note-clock-out
                   (or note org-log-note-clock-out)))
              (org-records-mcp--logging-note note
                (org-records-mcp--repeat-catching-up
                  (org-clock-clock-out
                   (cons marker start-time) nil end))))
            ;; The response links to the heading clocked out of.
            (goto-char heading)))))))

(defun org-records-mcp--tool-clock-add
    (link start end &optional files)
  "Add a completed clock entry to the heading LINK names.
START is ISO 8601 start time (e.g. 2026-03-23T14:30:00).
END is ISO 8601 end time (e.g. 2026-03-23T16:45:00).
FILES, when non-nil, names the files an `id:' LINK is looked up in;
see `org-records-mcp--link-target'.

MCP Parameters:
  link - Link to the node
         Formats:
           - id:{id}
           - file:{absolute-path}::#{custom-id}
           - file:{absolute-path}::*{title} (first match)
           - any of these as [[link]] or [[link][description]]
  start - ISO 8601 start time (e.g. 2026-03-23T14:30:00), naming a
          time that exists; seconds are read and not recorded
  end - ISO 8601 end time (e.g. 2026-03-23T16:45:00), naming a
          time that exists; seconds are read and not recorded
  files - Files and directories to look up an id: link in, in order,
          instead of Emacs's ID index (array of strings, optional);
          refused with any other link"
  (let* ((target (org-records-mcp--link-target link "link" files))
         (file-path (plist-get target :file))
         (start-time
          (org-records-mcp--clock-round-time
           (org-records-mcp--clock-parse-timestamp start)))
         (end-time
          (org-records-mcp--clock-round-time
           (org-records-mcp--clock-parse-timestamp end))))
    (when (time-less-p end-time start-time)
      (org-records-mcp--tool-validation-error
       "End time %s is before start time %s"
       (org-records-mcp--clock-format-timestamp end-time)
       (org-records-mcp--clock-format-timestamp start-time)))
    (org-records-mcp--modify-and-save
        file-path "clock-add"
        `((added . t)
          (start
           . ,(org-records-mcp--clock-format-timestamp start-time))
          (end . ,(org-records-mcp--clock-format-timestamp end-time))
          (duration
           .
           ,(org-records-mcp--clock-duration-string
             (float-time (time-subtract end-time start-time)))))
      (org-records-mcp--goto-heading target)
      (org-records-mcp--clock-insert-entry start-time end-time))))

(defun org-records-mcp--tool-clock-delete (link start &optional files)
  "Delete a clock entry from the heading LINK names.
START is the ISO 8601 start time of the clock entry to delete
\\(e.g., 2026-03-23T14:30:00).  It is the whole of what names the
entry, which is why the call reaches no further than the heading LINK
names: a CLOCK line under a descendant is that heading's, and
destroying it on an ancestor's word would report the ancestor as the
heading changed.  Where START names two entries of the one heading it
names neither, and the call is refused with both of them described;
see `org-records-mcp--clock-delete-entry'.
FILES, when non-nil, names the files an `id:' LINK is looked up in;
see `org-records-mcp--link-target'.

MCP Parameters:
  link - Link to the node
         Formats:
           - id:{id}
           - file:{absolute-path}::#{custom-id}
           - file:{absolute-path}::*{title} (first match)
           - any of these as [[link]] or [[link][description]]
  start - ISO 8601 start time of the clock entry to delete,
          naming a time that exists
          (e.g. 2026-03-23T14:30:00)
  files - Files and directories to look up an id: link in, in order,
          instead of Emacs's ID index (array of strings, optional);
          refused with any other link"
  (let* ((target (org-records-mcp--link-target link "link" files))
         (file-path (plist-get target :file))
         (start-time
          (org-records-mcp--clock-round-time
           (org-records-mcp--clock-parse-timestamp start)))
         (deleted-info nil))
    (org-records-mcp--modify-and-save file-path "clock-delete"
                                      `((deleted . t) ,@deleted-info)
      (org-records-mcp--goto-heading target)
      (setq deleted-info
            (org-records-mcp--clock-delete-entry start-time))
      (unless deleted-info
        (org-records-mcp--tool-validation-error
         "No clock entry starting at %s found"
         (org-records-mcp--clock-format-timestamp start-time))))))

;; Tool description parts shared by several tools

(defconst org-records-mcp--heading-link-formats
  "         Formats:
           - id:{id}
           - file:{absolute-path}::#{custom-id}
           - file:{absolute-path}::*{title} (first match)
           - any of these as [[link]] or [[link][description]]
"
  "The link forms of a `link' parameter naming a heading.
Tool descriptions `concat' it after the parameter's first line.")

(defconst org-records-mcp--node-link-formats
  "         Formats:
         - id:{id} - heading with that ID
         - file:/path/to/file.org::#{custom-id} - heading with that
           CUSTOM_ID
         - file:/path/to/file.org::*{title} - first heading with that
           title
         - file:/path/to/file.org - whole file
         - id:{id} of the file-level property drawer - whole file
         - any of these as [[link]] or [[link][description]]
"
  "The link forms of a `link' parameter naming a node.
A node is a heading or a whole file, so these are the forms of the
tools that take either.  Tool descriptions `concat' it after the
parameter's first line.")

(defconst org-records-mcp--files-set-description
  "          Each entry is an absolute path to an Org file or a
          directory; a relative path is refused.  A file outside the
          allowed files is accepted only as far as
          org-records-mcp-file-scope-override permits; see
          org-config-allowed-files.  A directory the setting permits is
          searched recursively for the Org files Org takes from a
          directory in org-agenda-files (by default every .org file,
          no archive), skipping hidden and unreadable directories,
          symlinked directories and anything not a regular file.
          Any other directory is not read: it stands for the allowed
          files under it, and is refused when there are none.  The
          buffers the call opens for these files are closed
          afterwards.
          \"\" and [] mean no files, as leaving it out does.
          A client that sends every argument as a string sends the
          array as its JSON text, the characters
          [\"/home/you/notes.org\"] in a string.
"
  "How the `files' parameter of a tool scanning a set of files works.
Tool descriptions `concat' it after the parameter's first lines.")

(defconst org-records-mcp--fields-description
  "          Either an array of the field names below, such as
          [\"title\", \"link\"], or the name of a list configured in
          org-records-mcp-node-field-lists, sent as a string.  An unknown
          field name and an unknown list name are both refused, and
          the refusal names the valid ones.
          [] asks for the default, as leaving it out does.
          A client that sends every argument as a string sends the
          array as its JSON text, the characters [\"title\",
          \"link\"] in a string.
"
  "How the `fields' parameter works, for every tool that takes one.
Each such tool names its own default before this text, because the
default is what that endpoint carries and not a property of the
parameter.")

(defconst org-records-mcp--properties-description
  "          Either an array of property names, such as
          [\"Effort\"], or \"all\" for the whole drawer or \"none\"
          for none of it, sent as a string.  Property names are
          matched as Org matches them, ignoring case.  A property
          the node does not carry is left out, as an empty field is;
          a special property, which Org computes rather than stores,
          is refused and named as a node field instead.
          [] asks for the default, as leaving it out does.
          A client that sends every argument as a string sends the
          array as its JSON text, the characters [\"Effort\"] in a
          string.
"
  "How the `properties' parameter works, for every tool taking one.
Each such tool names its own default before this text, as it does
for `fields'.")

(defconst org-records-mcp--computed-description
  "          Either an array of the names org-records-mcp-computed-fields
          configures, or \"all\" for every one of them or \"none\"
          for none, sent as a string.  A name nobody configured is
          refused, and the refusal names the ones that are.  A field
          whose function answers with nothing is left out.
          [] asks for the default, as leaving it out does.
          A client that sends every argument as a string sends the
          array as its JSON text, the characters [\"rank\"] in a
          string.
"
  "How the `computed' parameter works, for every tool taking one.
Each such tool names its own default before this text, as it does
for `fields'.")

(defconst org-records-mcp--node-description "
A node is a file or a heading, and both come back in one shape.  A
node carries the fields the call asked for, minus any it has no
value for: a key that is there has a value, a key that is missing
was either asked for and empty or never asked for, and the call
itself says which.  Nothing is ever sent as null.
  title - The heading's title, or a file's #+TITLE: and its own name
          when it sets none
  todo - TODO state
  priority - Priority letter
  tags - The tags in effect on the heading, inherited ones included
         as org-use-tag-inheritance and
         org-tags-exclude-from-inheritance direct, both of which
         org-config-tags reports
  local_tags - The tags written on the heading itself: local to the
         heading, not to this machine.  They are the set the three
         tag tools write, and the set org-node-set-tags asserts in
         its before; they are identical to tags when inheritance is
         off
  scheduled - Scheduled timestamp
  deadline - Deadline timestamp
  closed - Closed timestamp
  file - Absolute path of the file the node lives in
  id - The ID the link names
  level - Heading level, 0 for a file
  link - Link naming this node again: id:{id} when it has an ID, else
         file:{path}::#{custom-id} when it has a CUSTOM_ID, else
         file:{path}::*{title}; a file without an ID is file:{path}
  breadcrumbs - The headings above this one, outermost first, each
         an object of its title, link and level as a read of it
         answers them.  The file is not one, so a top-level heading
         and a file have none
  blocked - Whether marking the heading done is blocked, as Org's
         org-blocker-hook answers: true or false on a heading with a
         not-done TODO keyword, and left out otherwise
  log - The heading's log notes, newest first, read from the drawer
         org-log-into-drawer names (LOGBOOK unless it names
         another).  Each is an object of its kind (the purpose
         org-log-note-headings gives it: note, state, done,
         reschedule, delschedule, redeadline, deldeadline, refile,
         clock-out, or one of the user's), the time its line
         carries as Org wrote it, from and to (the states or dates
         a change moved between) and text (the prose written under
         it, indentation stripped), each left out when it has none.
         An item right under a CLOCK line that no heading matches
         is a clock-out note, timed by the clock's end; any other
         item no heading matches carries text and no kind.  CLOCK
         lines are not entries; the clock tools read them.  Left
         out of a heading with no entry and of a file
  content - Body text, or a file's preamble before its first heading
  content_digest - Opaque token over the region content is read from
         and org-node-set-content writes within.  Send back the token
         you were given to say what you believed was there; never
         compute one.  content is trimmed for reading and the token
         is not, so two nodes carrying the same content can carry
         different tokens.  A node with an empty body still has one
  digest - Opaque token over the node's whole subtree, every
         descendant included whatever depth was asked for.  A change
         anywhere under the node changes it
  children - The direct children: references carrying title, todo,
             level and link, or, as far as depth expands them, nodes
             carrying the same fields, properties and computed values
             as this one

Two things a node carries are not fields, because their names are
the user's rather than this server's: a drawer holds TITLE as
readily as Effort.  Each is asked for in a parameter of its own and
arrives under one key, where no name of the user's can shadow a
field.
  properties - The Org drawer properties the call asked for.  These
             are in the file and survive a write back
  computed - What the functions org-records-mcp-computed-fields configures
             answer for this node.  These are computed as the node
             is read, belong to no drawer and are never written back
"
  "How a node reads, for every tool description that returns one.
One shape serves a file, a heading, a child and a query result, so
the tools that return any of them share this text rather than each
describing the same thing differently.")

(defconst org-records-mcp--core-tool-specs
  (list
   (list
    #'org-records-mcp--tool-config-todo
    :id "org-config-todo"
    :description
    (concat
     "Get the TODO keyword configuration: the task state sequences and
their semantics.  Given a link, the answer is the one Org reaches in
that link's file, which is the set a write to a heading in it is held
to; given none, it is the global Emacs Org-mode configuration.

Parameters:
  link - Link to the file to answer for (string, optional)
"
     org-records-mcp--node-link-formats
     "         A link naming a heading answers for that heading's
         file: the settings are file-wide.
         A file carrying no `#+TODO:', `#+SEQ_TODO:' or
         `#+TYP_TODO:' setting of its own inherits the global
         sequences and is answered with them.
         Left out, or \"\" or whitespace, the
         answer is the global configuration.
  files - Files and directories to look up an id: link in, in order,
          instead of Emacs's ID index (array of strings, optional);
          refused with any other link, and with no link

Returns JSON object with two arrays:
  sequences - Array of TODO keyword sequences, each containing:
    - type: Sequence type (e.g., \"sequence\", \"type\")
    - keywords: Array of keywords including \"|\" separator between
active and done states
  semantics - Array of keyword semantics, each containing:
    - state: The TODO keyword (e.g., \"TODO\", \"DONE\")
    - isFinal: Whether this is a final (done) state (boolean)
    - sequenceType: The sequence type this keyword belongs to

The \"|\" separator in sequences marks the boundary between active
states (before) and done states (after).  If no \"|\" is present,
the last keyword is treated as the done state.

Use this tool to understand the available task states before
creating or updating TODO items, and name the file you are writing
to: a file defining its own workflow is held to that workflow, and
the global configuration says nothing about it.")
    :read-only t)
   (list
    #'org-records-mcp--tool-config-tags
    :id "org-config-tags"
    :description
    "Get tag-related configuration from the current Emacs Org-mode
settings.  Returns literal Elisp variable values as strings for tag
configuration introspection.

Parameters: None

Returns JSON object with literal Elisp expressions (as strings) for:
  org-use-tag-inheritance - Controls tag inheritance behavior
  org-tags-exclude-from-inheritance - Tags that don't inherit
  org-tag-alist - List of allowed tags with optional key bindings and
                  groups
  org-tag-persistent-alist - Additional persistent tags (or nil)

The org-tag-alist format includes:
  - Simple tags: (\"tagname\" . key-char)
  - Group markers: :startgroup, :endgroup for mutually exclusive tags
  - Grouptags: :startgrouptag, :grouptags, :endgrouptag for tag
hierarchies

Use this tool to understand:
  - Which tags are allowed
  - Tag inheritance rules
  - Mutually exclusive tag groups
  - Tag hierarchy relationships

This helps validate tag usage and understand tag semantics before
adding or modifying tags on TODO items."
    :read-only t)
   (list
    #'org-records-mcp--tool-config-tag-candidates
    :id "org-config-tag-candidates"
    :description
    (concat
     "Return all candidate tags the user might want to use across the
allowed files, or across the files named in `files'.

Mirrors Org's interactive tag completion (C-c C-q): the result is
the union of configured tags from `org-tag-alist' /
`org-tag-persistent-alist', any per-file `#+TAGS:' / `#+FILETAGS:'
keywords, and every tag actually present on a node in any of
those files.  Group keywords like `:startgroup' are filtered out.

Parameters:
  files - Files and directories to collect tags from (array of
          strings, optional)
          Replaces the allowed files for this call; when omitted, all
          allowed files are used.
"
     org-records-mcp--files-set-description "
Returns JSON object with:
  tags - Sorted, deduplicated array of tag-name strings.

Use this when suggesting or completing tags rather than
`org-config-tags', which only exposes the static configuration.")
    :read-only t)
   (list
    #'org-records-mcp--tool-config-priority
    :id "org-config-priority"
    :description
    "Get priority configuration from the current Emacs Org-mode
settings.  Returns the priority range and default as single-character
strings.

Parameters: None

Returns JSON object with:
  highest - Highest priority character (e.g. \"A\")
  lowest - Lowest priority character (e.g. \"C\")
  default - Default priority character (e.g. \"B\")

Use this tool to understand the valid priority range before setting
or interpreting priorities on TODO items."
    :read-only t)
   (list
    #'org-records-mcp--tool-config-allowed-files
    :id "org-config-allowed-files"
    :description
    "Get the list of Org files accessible through the org-records-mcp
server, and whether a call may name Org files outside them.  Returns
the allowed files as configured in org-records-mcp-allowed-files (the agenda
files when unset), and the policy of org-records-mcp-file-scope-override.

Parameters: None

Returns JSON object containing:
  files (array of strings): Absolute paths of allowed Org files
  override_allowed (boolean): Whether a call may name an Org file
    outside the allowed files, by a file: link, an entry of files,
    or an id: link whose ID Emacs's ID index places there.  The
    permission lasts for that one call only.
  override_roots (array of strings, present only when overriding is
    limited to directories): Absolute paths of the directories under
    which a named Org file is permitted.  When override_allowed is
    true and override_roots is absent, any Org file is permitted.

Example response:
  {
    \"files\": [
      \"/home/user/org/tasks.org\",
      \"/home/user/org/projects.org\",
      \"/home/user/notes/daily.org\"
    ],
    \"override_allowed\": true,
    \"override_roots\": [\"/home/user/decisions\"]
  }

Empty configuration returns:
  {
    \"files\": [],
    \"override_allowed\": false
  }

Use cases:
  - Discovery: What Org files can I access through MCP?
  - Link Construction: I need to build a file: link - what's
    the exact path?
  - Access Troubleshooting: Why is my file access failing?
  - Configuration Verification: Did my org-records-mcp-allowed-files setting
    work correctly?"
    :read-only t)
   (list
    #'org-records-mcp--tool-file-settings
    :id "org-file-settings"
    :description
    (concat
     "Read the in-buffer settings one Org file writes: the #+ lines at
the top of it that say what the file is and how Org treats it.  This
is what the file itself writes, line for line, which is what
org-file-set-setting asserts and replaces.  It is not what Org ends
up with: for the TODO keywords a write to a heading is held to,
including the ones a #+SETUPFILE: or the global configuration brings
in, ask org-config-todo.

Parameters:
  link - Link to the file to answer for, or to a heading in it
         (string, required)
"
     org-records-mcp--node-link-formats
     "         A link naming a heading answers for that heading's
         file: these settings are file-wide.
  files - Files and directories to look up an id: link in (array of
          strings, optional); see org-node-read

Returns JSON object:
  link - Link to the file (string): id:{id} when its own property
         drawer holds one, else file:{path}
  settings - JSON object with one entry per setting this tool
         covers, each an array of the lines the file writes it on,
         in the order it writes them.  [] is a setting the file
         does not write, which is what tells it from one written to
         a value that looks like a default

Example response:
  {
    \"link\": \"file:/home/user/org/gtd.org\",
    \"settings\": {
      \"TITLE\": [\"Getting things done\"],
      \"TODO\": [\"TODO(t) NEXT(n) | DONE(d)\", \"WAIT(w) | KILL(k)\"],
      \"ARCHIVE\": [],
      \"CATEGORY\": [\"gtd\"],
      \"FILETAGS\": [\":gtd:\"],
      \"STARTUP\": []
    }
  }

A setting may be written on more than one line, and Org reads all of
them: two #+TODO: lines are two sequences, and two #+FILETAGS: lines
are both sets of tags.  #+ARCHIVE: and #+CATEGORY: are the exception
- Org reads the first line and ignores the rest - and this tool
reports every line either way, because the file carries them.

TODO here is the #+TODO: lines and those alone.  A file may name
sequences in #+SEQ_TODO: or #+TYP_TODO: as well, or pull them in
through a #+SETUPFILE:, and none of the three is reported here or
replaced by writing TODO: ask org-config-todo for the keywords a
write to a heading in this file is actually held to, and expect it
to name states this answer does not.

Use this before org-file-set-setting: its before is the array this
answers with.")
    :read-only t)
   (list
    #'org-records-mcp--tool-node-set-todo
    :id "org-node-set-todo"
    :description
    (concat
     "Move an Org node's TODO state, or take it off.  A null
after leaves the node with no keyword, so it stops being a
task.  Its title, tags and properties are preserved either way.

Parameters:
  link - Link to the node to update (string, required)
"
     org-records-mcp--heading-link-formats
     "  before - The TODO state the node holds now (string, required)
           Send \"\" to assert that it has no TODO keyword
           Any other state is refused as a conflict and nothing is
           written; read the node again and re-plan
  after - New TODO state to set (string or null, required)
          Must be a valid keyword from org-todo-keywords
          null takes the keyword off, so the node stops being
          a task; \"\" is no keyword and is refused as one, and
          false is the parameter left out
          A client that cannot send null sends the text null,
          which is read as null unless the file names a keyword
          null
          It sets the keyword only.  A planning date that moves is
          Org's doing and comes back in the response
  before_planning - The node's planning fields as they are now
           (object, optional)
             {\"scheduled\": \"<2026-06-20 Sat +1w>\"}
           Each value is the raw Org timestamp a read returns,
           brackets, repeater and delay included
           Name a field the node has one for; leave out a field
           it has none for, which asserts that it has none.  \"\"
           and null are refused, so one state keeps one spelling
           A field holding something else is refused as a conflict
           and nothing is written; read the node again and
           re-plan
           Required for a heading whose state change would move a
           planning value -- a repeating heading that carries one --
           and refused there when it is missing.  That refusal names
           what the heading holds, so you can send the call again
           without reading it first
           CLOSED is not asserted here: Org writes and clears it on
           a done transition, so it is reported and never vouched
           for
           A client that sends every argument as a string sends the
           object as its JSON text, those characters in a string
  note - Optional note to attach to this state transition (string, optional)
         When provided, stored in LOGBOOK as part of the state change entry
         Empty or whitespace-only values are ignored
  files - Files and directories to look up an id: link in (array of
          strings, optional); see org-node-read

Example - starting a task that carries no planning dates:
  {\"link\": \"id:abc-123\", \"before\": \"TODO\",
   \"after\": \"IN-PROGRESS\"}

Example - finishing a repeating task, asserting the date it will
move.  The heading has no DEADLINE, so the map leaves it out:
  {\"link\": \"id:abc-123\", \"before\": \"TODO\",
   \"before_planning\": {\"scheduled\": \"<2026-06-20 Sat +1w>\"},
   \"after\": \"DONE\"}

Example - taking the keyword off, so it stops being a task:
  {\"link\": \"id:abc-123\", \"before\": \"TODO\",
   \"after\": null}

Returns JSON object:
  success - Always true on success (boolean)
  saved - False when the change is only in the user's open Emacs
          buffer, not on disk; tell the user it needs saving (boolean)
  before - The TODO state the node held (string, empty for none)
  after - The TODO state Org left it in (string, empty when the
          keyword was taken off): the one asked for, unless Org
          made another of it, as it does when it repeats a
          repeating entry instead of finishing it
          before and after are states the field was in and is in,
          not values to write: send either back as the next call's
          before, never as its after
  scheduled, deadline, closed - Present only when the call moved
          that field, which is what a repeat does (object): before is
          the state it was in and after the state it is in now, the
          raw Org timestamp to send as the next call's before, or
          \"\" when the field ends up holding nothing
          These are read back from Org after it has decided them.
          Do not work a new date out from the old one and the
          repeater: `.+' counts from today and `++' steps on until
          it is past today, so the arithmetic is wrong for two of
          the three repeater forms
          CLOSED is reported like the other two and asserted like
          neither: Org writes it on a done transition and clears it
          on a repeat
  clock - Present only when the transition closed the Emacs session's
          own clock running in the heading, which
          `org-clock-out-when-done' does on a move to a done keyword
          (object): the start, end and duration of that close.  A
          clock org-clock-in started is a CLOCK line in the file and
          not that clock, so a done keyword leaves it open and no
          field is reported; close it with org-clock-out.  Both
          timestamps are bracketed, as a CLOCK line spells an
          inactive timestamp and as org-clock-add reports them;
          org-clock-out spells its own start without brackets, so
          compare the two as instants, not as strings
  link - Link to the updated node (string): id:{id} when it has
         an ID, else file:{path}::#{custom-id} when it has a
         CUSTOM_ID, else file:{path}::*{title}")
    :read-only nil)
   (list
    #'org-records-mcp--tool-node-create
    :id "org-node-create"
    :description
    "Add a new node to an Org file at a specified location.
Creates it with an optional TODO state, optional tags,
optional body content, and optional properties.  A node that names no
state is a heading rather than a task.  No ID or CUSTOM_ID is created:
set one in properties to give the node a stable link.

Parameters:
  title - The node's title, without TODO state or tags (string,
          required)
          Cannot be empty or whitespace-only
          Cannot contain newlines
  todo - TODO keyword from org-todo-keywords (string, optional)
         Left out, or \"\", makes a heading
         with no keyword: a node that is not a task.  A value that names no
         keyword is refused
  tags - Tags for the node (string or array, optional)
         Single tag: \"urgent\"
         Multiple tags: [\"work\", \"urgent\"]
         A client that sends every argument as a string sends the
         array as its JSON text, those characters in a string
         Validated against org-tag-alist if configured
         Must follow Org tag rules (alphanumeric, _, @)
         Respects mutually exclusive tag groups
         Left out, or \"\" or [], sets no tags
  content - Body content of the node (string, optional)
            Left out, or \"\", writes no body
            Cannot contain headlines at same or higher level as new
            item
            If #+BEGIN/#+END blocks are present, they must be balanced
  parent - Link to the parent (string, required)
           For top-level: file:{absolute-path}
                          or id:{id} of the file-level property drawer
           For child: id:{parent-id}
                      or file:{absolute-path}::#{custom-id}
                      or file:{absolute-path}::*{title} (first match)
           Links may be bracketed: [[link]] or [[link][description]]
  previous_sibling - Link to the sibling to insert after (string,
                     optional), in any form parent takes for a child:
                     a direct child of the parent, or a top-level
                     heading of the file when parent names the whole
                     file.  Its id: link is looked up in the parent's
                     file.  Left out, or \"\" or
                     whitespace, appends as last child of parent
  properties - Properties for the new node (object, optional)
               e.g. {\"ID\": \"...\", \"CUSTOM_ID\": \"...\",
                     \"EFFORT\": \"1:00\"}
               Values are strings (numbers and booleans are
               accepted) on a single line, written as given and
               not otherwise checked; an ID is not added to Org's
               ID index
               Values take the three states a drawer line has, as
               in org-node-set-properties: a string or number is
               written as given, \"\" writes a line carrying no
               value, which a read returns as \"\", and null writes
               nothing, a new node having no line to take away
               true or false writes the text t or nil, so false
               writes the property where null passes it over
               Special properties (TODO, TAGS, PRIORITY, SCHEDULED,
               DEADLINE, etc.) are forbidden - use the other
               parameters and dedicated tools
               properties left out means no properties; an
               empty object is refused
               A client that sends every argument as a string sends
               the object as its JSON text, those characters in a
               string
  files - Files and directories to look up an id: link of parent in
          (array of strings, optional); see org-node-read.  It
          applies to parent only, and is refused unless parent is an
          id: link.

Returns JSON object:
  success - Always true on success (boolean)
  saved - False when the change is only in the user's open Emacs
          buffer, not on disk; tell the user it needs saving (boolean)
  link - Link to the new node (string): id:{id} when it has
         an ID, else file:{path}::#{custom-id} when it has a
         CUSTOM_ID, else file:{path}::*{title}
  file - Filename (not full path) where item was added
  title - The title the node was created with

Positioning behavior:
  - With parent only: Appends as last child of parent
  - With parent + previous_sibling: Inserts immediately after that
sibling and its subtree
  - Top-level (parent naming only the file): Adds after the
file's preamble (a file-level property drawer, keyword lines such as
#+TITLE and any text before the first heading), before every existing
heading
  - Top-level + previous_sibling: Inserts immediately after that
top-level heading and its subtree"
    :read-only nil)
   (list
    #'org-records-mcp--tool-node-set-title
    :id "org-node-set-title"
    :description
    (concat
     "Rename an Org node's title while preserving its TODO state,
tags, properties, and body content.

Parameters:
  link - Link to the node to rename (string, required)
"
     org-records-mcp--heading-link-formats
     "  before - The title the node holds now, without TODO state
           or tags (string, required)
           Any other title is refused as a conflict and nothing is
           written; read the node again and re-plan
  after - New title without TODO state or tags (string, required)
          Cannot be empty or whitespace-only
          Cannot contain newlines
          Cannot be text Org reads as something else: a trailing
          :tag:, a leading COMMENT, a leading TODO keyword or a
          leading [#A]
  files - Files and directories to look up an id: link in (array of
          strings, optional); see org-node-read

Example - renaming a node:
  {\"link\": \"id:abc-123\", \"before\": \"Draft the spec\",
   \"after\": \"Draft the write-safety spec\"}

Returns JSON object:
  success - Always true on success (boolean)
  saved - False when the change is only in the user's open Emacs
          buffer, not on disk; tell the user it needs saving (boolean)
  before - The previous title (string)
  after - The new title that was set (string)
  link - Link to the renamed node (string): id:{id} when it has
         an ID, else file:{path}::#{custom-id} when it has a
         CUSTOM_ID, else file:{path}::*{title}")
    :read-only nil)
   (list
    #'org-records-mcp--tool-node-set-content
    :id "org-node-set-content"
    :description
    (concat
     "Replace or empty the body content of an Org node.  Replaces
either a unique substring of the node's body text or the body
entire, whichever before names; an after of \"\" leaves nothing in
its place.

Parameters:
  link - Link to the node to edit (string, required)
"
     org-records-mcp--heading-link-formats
     "  before - What the body holds now (string, required)
           A substring of the body replaces that substring, and
           must appear exactly once
           The content_digest of this node replaces the body
           entire: send back the token a read handed you, prefix
           and all, and take it from the read you planned this
           call from rather than from a list you kept
           Use empty string \"\" only for adding to empty nodes
           Every other blank - null, false, [] - is the parameter
           left out and is refused as one
  after - Replacement text (string, required)
          Cannot introduce headlines at same or higher level
          Must maintain balanced #+BEGIN/#+END blocks
  files - Files and directories to look up an id: link in (array of
          strings, optional); see org-node-read

Example - replacing part of the body:
  {\"link\": \"id:abc-123\", \"before\": \"This is a placeholder.\",
   \"after\": \"Implementation started.\"}

Example - rewriting the body entire:
  {\"link\": \"id:abc-123\", \"before\": \"sha256:1b4f0e9851971998\",
   \"after\": \"The whole body, written afresh.\"}

Example - writing into a node that has no body:
  {\"link\": \"id:abc-123\", \"before\": \"\",
   \"after\": \"Meeting notes.\"}

Returns JSON object:
  success - Always true on success (boolean)
  saved - False when the change is only in the user's open Emacs
          buffer, not on disk; tell the user it needs saving (boolean)
  link - Link to the edited node (string): id:{id} when it has
         an ID, else file:{path}::#{custom-id} when it has a
         CUSTOM_ID, else file:{path}::*{title}

Special behavior - Empty before:
  An empty before asserts the node has no content:
  - It is how initial content reaches a node that has none
  - A node that already has content is refused, and the refusal
    asks for the part of the content to replace

Adding to a long body costs sending that body back: assert its
content_digest and send the body with the addition in it.  Every
body write asserts what it overwrites, so a call repeated after a
timeout is refused rather than writing the text a second time.

Refusals:
  Every refusal over the value before asserts is marked
  conflict:, whichever form it took - the substring is not there,
  is there more than once, the node has no body, the node has one
  where \"\" said it had none, or the digest is not the body's.
  Each answers a before the client believed it read, so the
  recovery is the same: read the node again and plan against what
  it holds now.  A before that was never sent says nothing about
  the file and is refused unmarked, as the missing parameter it
  is.")
    :read-only nil)
   ;; Entry update tools
   (list
    #'org-records-mcp--tool-node-set-properties
    :id "org-node-set-properties"
    :description
    (concat
     "Set or remove properties on an Org heading or on a whole file.
Updates the PROPERTIES drawer: a value writes the property and null
takes it away, guarded by what before says it holds.  Setting ID or
CUSTOM_ID gives a heading a stable link; org-records-mcp creates neither
itself.

A link naming a whole file writes that file's own drawer, the one
above its #+ settings and before its first heading, which is where
Org reads a file's properties.  It is made when the file has none.
A file whose very first line is a heading has nowhere for one, and
the drawer is made above that heading.  No other write tool takes a
link naming a file; a file's #+TITLE, #+TODO and #+FILETAGS are not
properties and are not reached here.

Parameters:
  link - Link to a heading, or to a whole file for its own
         property drawer (string, required)
"
     org-records-mcp--node-link-formats
     "  before - JSON object of what those properties hold now
           (required)
           One entry per property after writes, and no other: a
           property after writes and before omits is refused, and
           so is one before names and after leaves alone
           Read the values from org-node-read rather than
           assuming them
           A drawer line has three states and before spells all
           three: null asserts there is no such line, \"\" asserts
           a line carrying no value, and any other string asserts
           the line holds that text
  after - JSON object of property name-value pairs (required)
          String value (numbers and booleans are accepted):
          set the property; it must be a single line
          true or false writes the text t or nil
          Empty string writes a line carrying no value, the
          state org-node-read returns as \"\"
          null takes the property line away, guarded by what
          before says it holds
          ID and CUSTOM_ID can be set; values are written as
          given and not otherwise checked, and an ID is not
          added to Org's ID index
          Special properties (TODO, TAGS, PRIORITY, SCHEDULED,
          DEADLINE, etc.) are forbidden - use dedicated tools
          A client that sends every argument as a string sends
          the object as its JSON text, those characters in a
          string, and before the same way
  files - Files and directories to look up an id: link in (array of
          strings, optional); see org-node-read

Returns JSON object:
  success - Always true on success (boolean)
  saved - False when the change is only in the user's open Emacs
          buffer, not on disk; tell the user it needs saving (boolean)
  properties_set - Array of property names that were set
  properties_deleted - Array of property names that were removed;
          a property that a null after names but the drawer did
          not carry is in neither array.  A line carrying nothing
          is carried: taking it away is a removal and is named here
  before - JSON object of the values these properties held, one
           entry per name before asserted; nothing in the file
           records a removed value once the call returns
  link - Link to the node (string): for a heading, id:{id} when it
         has an ID, else file:{path}::#{custom-id} when it has a
         CUSTOM_ID, else file:{path}::*{title}; for a file, id:{id}
         of its own drawer when it has one, else file:{path}")
    :read-only nil)
   (list
    #'org-records-mcp--tool-file-set-setting
    :id "org-file-set-setting"
    :description
    (concat
     "Write one in-buffer setting of an Org file: the #+ lines that say
what the file is and how Org treats it.  One call writes one
setting, and it writes every line of it: before is all the lines the
file has for it and after is all the lines it is to have.

Settings this tool writes: #+TITLE:, #+TODO:, #+ARCHIVE:,
#+CATEGORY:, #+FILETAGS:, #+STARTUP:.  Any other #+ line is refused
by name.  #+PROPERTY: in particular is not here: it sets properties
file-wide and belongs with org-node-set-properties, and a file's own
property drawer - a different thing with the same name - is written
there too.

Parameters:
  link - Link to the file, or to a heading in it (string, required)
"
     org-records-mcp--node-link-formats
     "         A link naming a heading writes its file: these
         settings are file-wide.
  setting - Which setting to write (string, required): TITLE, TODO,
          ARCHIVE, CATEGORY, FILETAGS or STARTUP, in upper case
  before - Every line the file writes that setting on now (string
          or array, required), in the order it writes them - the
          array org-file-settings returns for it.  Read it from
          there rather than assuming it.  [] asserts that the file
          writes the setting on no line.  Any other set of lines is
          a conflict and nothing is written
  after - The lines to write (string or array, required).  [] takes
          every line of the setting away.  A line is one line of
          text with no space around it, as a read returns it
  files - Files and directories to look up an id: link in (array of
          strings, optional); see org-node-read

Returns JSON object:
  success - Always true on success (boolean)
  saved - False when the change is only in the user's open Emacs
          buffer, not on disk; tell the user it needs saving (boolean)
  setting - The setting written (string), upcased
  before - The lines asserted, sent back because nothing in the file
          records them once the call returns (array of strings)
  after - The lines the file writes now (array of strings)
  link - Link to the file (string): id:{id} when its own property
         drawer holds one, else file:{path}

Rewriting #+TODO: rewrites headings.  Org takes a heading's first
word for its keyword when the sequences name that word and for the
start of its title when they do not, so sequences that stop naming
WAIT retitle `* WAIT ship it' to a keywordless heading titled `WAIT
ship it', and sequences that start naming it retitle `* WAIT for the
parts' to a WAIT heading titled `for the parts'.  Both are a call
rewriting headings it named none of, so the call is refused while
any heading in the file would read differently, naming the keywords
that move and counting the headings each takes.  To move a heading
out of the way first: org-node-set-todo off a keyword that is going,
with the new sequences written beside the old ones so both are
valid; org-node-set-title off a title that would become one.

#+ARCHIVE: reaches past its line too, and is not refused: it changes
where org-node-archive sends a subtree from then on, and leaves
everything already written meaning what it meant.  #+FILETAGS: is
the same shape - every heading in the file inherits those tags, and
a heading's own tags are untouched.

Refusals:
  A before that does not match the file is marked conflict: the
  file is not as the client believed, so read it again with
  org-file-settings and plan against what it holds now.  A setting
  outside the six, a line carrying a newline or space around its
  value, and a #+TODO: write that would rewrite a heading are
  unmarked: what has to change is the call.")
    :read-only nil)
   (list
    #'org-records-mcp--tool-node-set-scheduled
    :id "org-node-set-scheduled"
    :description
    (concat
     "Move an Org node's SCHEDULED timestamp, or take it off.  before
and after are the two ends of that move, not the ends of a range:
before is the date the node carries now and after is the date
it is to carry instead, or null to leave it with none.  Moving a task
from Sunday the 20th to Sunday the 27th:

  {\"link\": \"id:abc\", \"before\": \"<2026-09-20 Sun>\",
   \"after\": \"2026-09-27\"}

Parameters:
  link - Link to the node (string, required)
"
     org-records-mcp--heading-link-formats
     "  before - The SCHEDULED timestamp the node carries now
           (string, required)
           The raw Org timestamp a read returns, brackets,
           repeater and delay included, such as
           \"<2026-06-20 Sat +1w -3d>\" - not the ISO shorthand
           after takes
           Empty string asserts the node has no SCHEDULED
  after - ISO date string (string or null, required), naming a date that
          exists: 2026-02-30 and 2026-13-45 are refused rather
          than rolled over to another date
          Examples: \"2026-03-27\", \"2026-03-27 09:00\"
          null takes the timestamp away, guarded by what before
          says the node carries.  \"\" is not a date and is
          refused as one; false is the parameter left out
          A client that cannot send null sends the text null,
          which is read as null
  files - Files and directories to look up an id: link in (array of
          strings, optional); see org-node-read

Returns JSON object:
  success - Always true on success (boolean)
  saved - False when the change is only in the user's open Emacs
          buffer, not on disk; tell the user it needs saving (boolean)
  before - Previous SCHEDULED value (string, empty if none)
  after - The SCHEDULED the node now carries (string, empty when
          taken away)
          A timestamp here is a value: send it back as the next
          call's before, or as its after to write it again.  The
          empty string is a state and not a value, and a removal is
          asked for again with null
  link - Link to the node (string): id:{id} when it has
         an ID, else file:{path}::#{custom-id} when it has a
         CUSTOM_ID, else file:{path}::*{title}")
    :read-only nil)
   (list
    #'org-records-mcp--tool-node-set-deadline
    :id "org-node-set-deadline"
    :description
    (concat
     "Move an Org node's DEADLINE timestamp, or take it off.  before
and after are the two ends of that move, not the ends of a range:
before is the date the node carries now and after is the date
it is to carry instead, or null to leave it with none.  Pushing a deadline
from Sunday the 20th to Sunday the 27th:

  {\"link\": \"id:abc\", \"before\": \"<2026-09-20 Sun>\",
   \"after\": \"2026-09-27\"}

Parameters:
  link - Link to the node (string, required)
"
     org-records-mcp--heading-link-formats
     "  before - The DEADLINE timestamp the node carries now
           (string, required)
           The raw Org timestamp a read returns, brackets,
           repeater and delay included, such as
           \"<2026-06-20 Sat +1w -3d>\" - not the ISO shorthand
           after takes
           Empty string asserts the node has no DEADLINE
  after - ISO date string (string or null, required), naming a date that
          exists: 2026-02-30 and 2026-13-45 are refused rather
          than rolled over to another date
          Examples: \"2026-03-27\", \"2026-03-27 09:00\"
          null takes the timestamp away, guarded by what before
          says the node carries.  \"\" is not a date and is
          refused as one; false is the parameter left out
          A client that cannot send null sends the text null,
          which is read as null
  files - Files and directories to look up an id: link in (array of
          strings, optional); see org-node-read

Returns JSON object:
  success - Always true on success (boolean)
  saved - False when the change is only in the user's open Emacs
          buffer, not on disk; tell the user it needs saving (boolean)
  before - Previous DEADLINE value (string, empty if none)
  after - The DEADLINE the node now carries (string, empty when
          taken away)
          A timestamp here is a value: send it back as the next
          call's before, or as its after to write it again.  The
          empty string is a state and not a value, and a removal is
          asked for again with null
  link - Link to the node (string): id:{id} when it has
         an ID, else file:{path}::#{custom-id} when it has a
         CUSTOM_ID, else file:{path}::*{title}")
    :read-only nil)
   (list
    #'org-records-mcp--tool-node-add-tags
    :id "org-node-add-tags"
    :description
    (concat
     "Add tags to an Org node, leaving its other tags alone.

Parameters:
  link - Link to the node (string, required)
"
     org-records-mcp--heading-link-formats
     "  after - Tags to add (string or array, required)
          Single tag: \"work\"
          Multiple tags: [\"work\", \"urgent\"]
          A client that sends every argument as a string sends the
          array as its JSON text, those characters in a string
          A tag the node already has, written on it or
          inherited, is left alone rather than written twice
          Must follow Org tag rules (alphanumeric, _, @)
          Respects mutually exclusive tag groups
  files - Files and directories to look up an id: link in (array of
          strings, optional); see org-node-read

The call takes nothing away, so it asserts nothing and takes no
before.  Use org-node-set-tags when you mean to replace the whole
set.

Example - adding one tag:
  {\"link\": \"id:abc-123\", \"after\": \"urgent\"}

Returns JSON object:
  success - Always true on success (boolean)
  saved - False when the change is only in the user's open Emacs
          buffer, not on disk; tell the user it needs saving (boolean)
  before - Array of the tags the node carried itself
  after - Array of the tags it carries itself now
  inherited - Array of the tags in effect on it from elsewhere
  link - Link to the node (string): id:{id} when it has
         an ID, else file:{path}::#{custom-id} when it has a
         CUSTOM_ID, else file:{path}::*{title}")
    :read-only nil)
   (list
    #'org-records-mcp--tool-node-remove-tags
    :id "org-node-remove-tags"
    :description
    (concat
     "Remove tags from an Org node, leaving its other tags alone.

Parameters:
  link - Link to the node (string, required)
"
     org-records-mcp--heading-link-formats
     "  after - Tags to remove (string or array, required)
          Single tag: \"work\"
          Multiple tags: [\"work\", \"urgent\"]
          A client that sends every argument as a string sends the
          array as its JSON text, those characters in a string
          A tag the node does not have is passed over
          A tag it only inherits is refused, naming where the tag
          is written
  files - Files and directories to look up an id: link in (array of
          strings, optional); see org-node-read

The call takes away only what it names, so a tag you never saw
survives it and it asserts nothing: it takes no before.  This is how
to clear tags you have read.

Example - removing one tag:
  {\"link\": \"id:abc-123\", \"after\": \"urgent\"}

Returns JSON object:
  success - Always true on success (boolean)
  saved - False when the change is only in the user's open Emacs
          buffer, not on disk; tell the user it needs saving (boolean)
  before - Array of the tags the node carried itself
  after - Array of the tags it carries itself now
  inherited - Array of the tags in effect on it from elsewhere
  link - Link to the node (string): id:{id} when it has
         an ID, else file:{path}::#{custom-id} when it has a
         CUSTOM_ID, else file:{path}::*{title}")
    :read-only nil)
   (list
    #'org-records-mcp--tool-node-set-tags
    :id "org-node-set-tags"
    :description
    (concat
     "Replace the tags written on an Org node.

Parameters:
  link - Link to the node (string, required)
"
     org-records-mcp--heading-link-formats
     "  before - The tags the node carries itself now (string or
           array, required)
           This is the local_tags of a read, not its tags
           Send [] to assert that it carries none of its own
           Order makes no difference; any other set is refused as a
           conflict and nothing is written
           Send the tags themselves and never a digest: a token
           covers a region, and this call writes one field
  after - Tags to write (string or array, required)
          Single tag: \"work\"
          Multiple tags: [\"work\", \"urgent\"]
          A client that sends every argument as a string sends the
          array as its JSON text, those characters in a string
          [] leaves the node carrying no tags of its own
          Must follow Org tag rules (alphanumeric, _, @)
          Respects mutually exclusive tag groups
  files - Files and directories to look up an id: link in (array of
          strings, optional); see org-node-read

The call destroys every tag it does not list, including tags you
never saw, so before asserts the whole prior set.  When you know
which tags you mean to change, org-node-add-tags and
org-node-remove-tags name them and assert nothing.

Inherited tags are left where they are, by all three tools.

Example - replacing the set:
  {\"link\": \"id:abc-123\", \"before\": [\"work\"],
   \"after\": [\"work\", \"urgent\"]}

Example - leaving the node no tags of its own:
  {\"link\": \"id:abc-123\", \"before\": [\"work\", \"urgent\"],
   \"after\": []}

Returns JSON object:
  success - Always true on success (boolean)
  saved - False when the change is only in the user's open Emacs
          buffer, not on disk; tell the user it needs saving (boolean)
  before - Array of the tags the node carried itself
  after - Array of the tags it carries itself now
  inherited - Array of the tags in effect on it from elsewhere
  link - Link to the node (string): id:{id} when it has
         an ID, else file:{path}::#{custom-id} when it has a
         CUSTOM_ID, else file:{path}::*{title}")
    :read-only nil)
   (list
    #'org-records-mcp--tool-node-set-priority
    :id "org-node-set-priority"
    :description
    (concat
     "Set or remove priority on an Org node.

Parameters:
  link - Link to the node (string, required)
"
     org-records-mcp--heading-link-formats
     "  before - The priority character the node carries now
           (string, required)
           Just the letter, without the [# ] Org writes around it
           Empty string asserts the node has no priority
  after - Priority character (string or null, required)
          Must be in the configured range (default \"A\" to \"C\")
          Use org-config-priority to check the valid range
          null takes the priority away, guarded by what before
          says the node carries.  \"\" is no character and is
          refused as one; false is the parameter left out
          A client that cannot send null sends the text null,
          which is read as null
  files - Files and directories to look up an id: link in (array of
          strings, optional); see org-node-read

Returns JSON object:
  success - Always true on success (boolean)
  saved - False when the change is only in the user's open Emacs
          buffer, not on disk; tell the user it needs saving (boolean)
  before - Previous priority (string, empty if none)
  after - The priority the node now carries (string, empty when
          taken away)
          before and after are states the field was in and is in,
          not values to write: send either back as the next call's
          before, never as its after
  link - Link to the node (string): id:{id} when it has
         an ID, else file:{path}::#{custom-id} when it has a
         CUSTOM_ID, else file:{path}::*{title}")
    :read-only nil)
   (list
    #'org-records-mcp--tool-node-add-note
    :id "org-node-add-note"
    :description
    (concat
     "Add a timestamped note to the LOGBOOK drawer of an Org node.
Creates the LOGBOOK drawer if it doesn't exist.

Parameters:
  link - Link to the node (string, required)
"
     org-records-mcp--heading-link-formats
     "  note - Note text to add (string, required)
         Cannot be empty or whitespace-only
         Multi-line notes are properly indented in the LOGBOOK
         Note is inserted at the top of the LOGBOOK drawer
  files - Files and directories to look up an id: link in (array of
          strings, optional); see org-node-read

Returns JSON object:
  success - Always true on success (boolean)
  saved - False when the change is only in the user's open Emacs
          buffer, not on disk; tell the user it needs saving (boolean)
  link - Link to the node (string): id:{id} when it has
         an ID, else file:{path}::#{custom-id} when it has a
         CUSTOM_ID, else file:{path}::*{title}")
    :read-only nil)
   (list
    #'org-records-mcp--tool-node-delete
    :id "org-node-delete"
    :description
    (concat
     "Delete an Org node, and every descendant under it, from its file.

This is not the tool for a node that is finished.  org-node-archive
moves such a node to the archive file and writes into it where it
came from, so the node can be found and put back; use it whenever
the node is being retired rather than discarded.  A delete keeps no
copy anywhere: the text leaves the file, org-records-mcp does not hold it,
and nothing in the file records that it was ever there.

Parameters:
  link - Link to the node to delete (string, required)
"
     org-records-mcp--heading-link-formats
     "  before - The node's digest (string, required)
           Send back the digest field of a read of this node, prefix
           and all, exactly as that read handed it to you
           Take it from the read you planned this call from, not
           from a list you kept: the token covers the whole subtree,
           so an edit to any descendant, a clock line among them,
           makes it stale
  files - Files and directories to look up an id: link in (array of
          strings, optional); see org-node-read

Returns JSON object:
  success - Always true on success (boolean)
  saved - False when the change is only in the user's open Emacs
          buffer, not on disk; tell the user it needs saving (boolean)
  link - The link the node had (string); it resolves to nothing now")
    :read-only nil)
   (list
    #'org-records-mcp--tool-node-archive
    :id "org-node-archive"
    :description
    (concat
     "Archive an Org node, and every descendant under it, to the archive
file Org is configured to use.

This is the tool for a node that is finished rather than mistaken.
Org writes into the node as it moves it where it came from: the
file, the outline path, the category, the TODO state it held and its
inherited tags, as ARCHIVE_* properties.  A node archived by mistake
can therefore be found in the archive file and put back where those
properties say it was.

Parameters:
  link - Link to the node to archive (string, required)
"
     org-records-mcp--heading-link-formats
     "  before - The node's digest (string, required)
           Send back the digest field of a read of this node, prefix
           and all, exactly as that read handed it to you
           Take it from the read you planned this call from, not
           from a list you kept: the token covers the whole subtree,
           so an edit to any descendant, a clock line among them,
           makes it stale
  files - Files and directories to look up an id: link in (array of
          strings, optional); see org-node-read

Returns JSON object:
  success - Always true on success (boolean)
  saved - False when the change is only in an open Emacs buffer, not
          on disk; tell the user it needs saving.  It answers for the
          archive file as well as for the file the node left (boolean)
  link - The link the node had in the file it left (string)
  archive_file - The file the node was archived to (string)")
    :read-only nil)
   (list
    #'org-records-mcp--tool-node-refile
    :id "org-node-refile"
    :description
    (concat
     "Refile an Org node, and every descendant under it, under a
different parent.  The parent may be in another file, and the node
goes to that file: filing an inbox item into a project is one call.

The call names the destination - the parent the node goes under, and
optionally the sibling it follows there.  It does not shift a node
one step from where it is; every call says where the node lands.

The subtree arrives whole, its LOGBOOK and its drawers with it, and
Org shifts it to the level of its new place.  An id: link to the
node, or to anything under it, keeps working afterwards.  Nothing in
the node records where it was: a refile is undone by refiling it
back, by a caller that knows where back is.  Use org-node-archive
when the node is being retired, since that writes the node's origin
into it.

A user who logs refiles - org-log-refile - gets the LOGBOOK entry
that setting asks for, timestamped and with no note under it, the
same entry a refile by hand leaves.  Say anything more about the
move with org-node-add-note.

Parameters:
  link - Link to the node to refile (string, required)
"
     org-records-mcp--heading-link-formats
     "  before - The node's digest (string, required)
           Send back the digest field of a read of this node, prefix
           and all, exactly as that read handed it to you
           Take it from the read you planned this call from, not
           from a list you kept: the token covers the whole subtree,
           so an edit to any descendant, a clock line among them,
           makes it stale
  parent - Link to the node's new parent (string, required), in any
           form link takes, or file:{absolute-path} for the top
           level of that file, as org-node-create's parent takes it.
           It may name a node in any file this server may reach; the
           node goes to that file
  previous_sibling - Link to the child of parent the node is to
                     follow (string, optional), in any form link
                     takes, looked up in the parent's file.
                     Left out, or \"\" or
                     whitespace, the node becomes the parent's last
                     child, or, at the top level, the file's first
                     heading
  files - Files and directories to look up the id: link in link in
          (array of strings, optional); see org-node-read.  It
          applies to link only - it says where to find the node the
          call refiles - and is refused unless link is an id: link.
          parent and previous_sibling are resolved without it, so an
          id: parent must be one Emacs's ID index holds, and is
          refused by name when it is not

Returns JSON object:
  success - Always true on success (boolean)
  saved - False when the change is only in an open Emacs buffer, not
          on disk; tell the user it needs saving.  When the node went
          to another file, it answers for both files (boolean)
  link - Link to the node in its new place (string): id:{id} when it
         has an ID, else file:{path}::#{custom-id} when it has a
         CUSTOM_ID, else file:{path}::*{title}")
    :read-only nil)
   (list
    #'org-records-mcp--tool-node-read
    :id "org-node-read"
    :description
    (concat
     "Read an Org file or heading as a node.  Takes a native Org link.

Parameters:
  link - Link to a heading or a file (string, required)
"
     org-records-mcp--node-link-formats
     "         Any other string, such as a bare ID, a bare path or an
         org:// resource URI, is refused.
  fields - How much of the node to return (array of strings, or a
          string, optional)
          Defaults to every field below but the two digests: a
          digest is for a call about to change something, so no
          node is hashed unasked; naming one asks for exactly that.
"
     org-records-mcp--fields-description
     "  depth - How many generations of children to expand in place
          (integer, optional)
          Defaults to none, which returns the children as
          references.  Every generation a call expands carries the
          same fields as the node itself, and the properties and
          computed values it asked for, so an expanded child is the
          node a read of its link returns, and the generation past
          depth comes back as references again.  With no children
          among the fields there is nothing to expand and depth
          changes nothing.
          A read of more nodes than org-records-mcp-read-max-nodes is
          refused, naming the node the walk stopped at so that it
          can be read on its own; it is never trimmed to fit.
          0 asks for none, as leaving it out does.
  properties - Which Org drawer properties to return (array of
          strings, or a string, optional)
          Defaults to all: a read is the call that returns the
          whole node, so it carries the drawer unasked.  \"none\"
          turns it off.
"
     org-records-mcp--properties-description
     "  computed - Which computed fields to return (array of strings,
          or a string, optional)
          Defaults to all.  What is worth computing is the
          workflow's question, so nothing is configured out of the
          box and \"all\" is then empty.  \"none\" turns them off.
"
     org-records-mcp--computed-description
     "  files - Files and directories to look up an id: link in (array of
          strings, optional)
          Without files, an id: link resolves to the file Emacs's ID
          index names for it, which must be in the allowed files or
          permitted by org-records-mcp-file-scope-override, as the
          file of a file: link must.  With files, the ID is
          looked up in these files instead, in the order given,
          rather than in Emacs's ID index: a heading in a file Emacs
          never indexed is found, and no index rescan runs.  Entries
          are checked as for org-query, so a file outside the
          allowed files is reached only as far as
          org-records-mcp-file-scope-override permits, and a directory is
          searched as that tool searches it.  An ID none of the files
          holds is an error.  Refused with any link but an id:
          link, such as a file: link, which names its file already.
          \"\" and [] mean no files, as leaving it out does.
          A client that sends every argument as a string sends the
          array as its JSON text, the characters
          [\"/home/you/notes.org\"] in a string.
          Every tool that names a heading takes files in the same
          way.

Returns: JSON object, the node the link names, carrying the fields
the call asked for.
"
     org-records-mcp--node-description "
File must be in the allowed files, or permitted by
org-records-mcp-file-scope-override.")
    :read-only t)
   (list
    #'org-records-mcp--tool-node-text
    :id "org-node-text"
    :description
    (concat
     "Read an Org file or heading as plain text.  Takes a native Org
link.  Returns the node as Org writes it: TODO state, tags,
properties, body text, and all nested subheadings.

Parameters:
  link - Link to a heading or a file (string, required)
"
     org-records-mcp--node-link-formats
     "         Any other string is refused, as in org-node-read.
  files - Files and directories to look up an id: link in (array of
          strings, optional); see org-node-read

Returns: Plain text content of the heading and its subtree, or of
the whole file")
    :read-only t)
   (list
    #'org-records-mcp--tool-node-history
    :id "org-node-history"
    :description
    (concat
     "Show what changed on one Org heading since a bound, from the git
repository its file is committed in.  Takes a native Org link.  Each
revision that changed the heading comes back with a unified diff of
the heading's subtree alone, never of the whole file, so a client
sees an edit made in Emacs, on a phone or by another client without
reading the file's history.

Parameters:
  link - Link to the heading (string, required)
"
     org-records-mcp--heading-link-formats
     "         A link naming a whole file is refused.
  since - Where the history starts (string, required), one of:
          - a commit hash, 7 to 64 hexadecimal digits: the revisions
            after that commit.  Send the current of an earlier
            answer to see what changed since that answer.  A commit
            HEAD does not descend from is refused.
          - a time, as an ISO date or local time such as 2026-10-07
            or 2026-10-07T16:00, or an Org timestamp such as
            [2026-10-07 Wed 16:00]: the revisions committed at that
            time or later.
  limit - The most revisions to return (integer, optional)
          The newest come back, and complete says whether older
          ones were left unread.  0 asks for no cap, as leaving it
          out does.
  files - Files and directories to look up an id: link in (array of
          strings, optional); see org-node-read

Returns: JSON object with:
  link - Link to the heading (string)
  file - The file the heading is in (string)
  current - The commit the answer is current to, HEAD of the
            file's repository (string).  Send it as the next since.
  complete - False when limit stopped the history before the oldest
             revision in its window (boolean)
  uncommitted - True when the heading as Emacs holds it now differs
                from the heading at current: an edit not yet
                committed, or not yet saved (boolean)
  revisions - The revisions that changed the heading, newest first
              (array).  Each has revision, the commit (string); time,
              its local commit time as 2026-10-07T16:10:00 (string);
              diff, the unified diff of the subtree from the
              revision before (string, absent when only note
              changed); and note (string, only when there is one):
              \"appears\", \"disappears\", \"moves from A to B\"
              when the heading went under another parent, or
              \"moves from FILE\" and \"moves to FILE\" when one
              commit refiled it between this file and FILE.

The heading is followed back through the revisions by its ID, else
its CUSTOM_ID, else its outline path, else its title where one
heading alone carries it.  A heading without an ID or a CUSTOM_ID
whose title changed is not followed past the change, and appears
there.  A file renamed in the window starts its history at the
rename.  A window of more than org-records-mcp-history-max-revisions
revisions of the file is refused.

File must be in the allowed files, or permitted by
org-records-mcp-file-scope-override, and committed in a git
repository.")
    :read-only t)
   (list
    #'org-records-mcp--tool-query
    :id "org-query"
    :description
    (concat
     "Search Org files using org-ql query expressions.  Supports
querying by TODO state, tags, priority, deadlines, properties, and
more.  Returns matched entries as JSON with Org links for follow-up
access.

Parameters:
  query - org-ql query sexp as string (string, required)
          Examples:
            (todo \"TODO\")
            (tags \"work\")
            (and (todo \"TODO\") (priority \"A\"))
            (deadline :to today)
  fields - How much of each matching node to return (array of
          strings, or a string, optional)
          Defaults to the fields org-records-mcp-list-fields
          names, out of the box title, todo, priority, tags,
          scheduled, deadline and link: a match list is an
          overview, and the rest of a node is a read of its link
          away.  Naming fields asks for exactly those.
"
     org-records-mcp--fields-description
     "  properties - Which Org drawer properties to return (array of
          strings, or a string, optional)
          Defaults to none: a match list is an overview, and a read
          of a match's link returns its drawer.  Name the properties
          a list is about, or \"all\".
"
     org-records-mcp--properties-description
     "  computed - Which computed fields to return (array of strings,
          or a string, optional)
          Defaults to the ones org-records-mcp-list-computed-fields
          names, none out of the box: a workflow names there the
          ones its lists sort or group by.  \"all\" and \"none\"
          override it.
"
     org-records-mcp--computed-description
     "  files - Files and directories to search (array of strings, optional)
          Replaces the allowed files for this call; when omitted, all
          allowed files are searched.
"
     org-records-mcp--files-set-description "
Returns JSON object:
  children - Array of matching nodes, the shape org-node-read
             returns, each carrying the fields the call asked for.
  total - Number of matches (number)
  files_searched - Number of files searched (number)
"
     org-records-mcp--node-description)
    :read-only t))
  "Specs for the tools org-records-mcp registers on every `org-records-mcp-enable'.
Each element is a `mcp-server-lib-register-server' `:tools' spec,
`(HANDLER :id STR :description STR [:read-only BOOL])'.  The clock
tools live in `org-records-mcp--clock-tool-specs' and the tools that depend
on configuration in `org-records-mcp--view-tool-specs'.")

(defun org-records-mcp--view-catalogue ()
  "Return the configured views as lines of the org-view description.
One line per view: what a call names it, the label it carries for a
reader, and what it takes — a view that takes a range naming its
ranges and the one it runs at unasked, since that is where a caller
reads them."
  (mapconcat (lambda (entry)
               (let* ((declaration (cdr entry))
                      (label (plist-get declaration :name))
                      (ranges
                       (org-records-mcp--view-ranges declaration))
                      (takes
                       (delq
                        nil
                        (list
                         (and (plist-get declaration :filter)
                              "filter")
                         (and ranges
                              (format
                               "range (%s; %s unasked)"
                               (mapconcat #'symbol-name ranges ", ")
                               (car ranges)))))))
                 (format "           %s%s - %s\n"
                         (car entry)
                         (if label
                             (format " (%s)" label)
                           "")
                         (if takes
                             (concat
                              "takes "
                              (mapconcat #'identity takes ", "))
                           "takes no parameters"))))
             org-records-mcp-views
             ""))

(defun org-records-mcp--view-catalogue-text ()
  "Return the views part of the org-view description.
The text `org-records-mcp-view-catalogue-function' writes when one is set,
ended with a newline so the next parameter starts a line of its own,
and the per-view lines of `org-records-mcp--view-catalogue' otherwise."
  (if org-records-mcp-view-catalogue-function
      (let ((text (funcall org-records-mcp-view-catalogue-function)))
        (if (string-suffix-p "\n" text)
            text
          (concat text "\n")))
    (org-records-mcp--view-catalogue)))

(defun org-records-mcp--view-tool-description ()
  "Return the description of the org-view tool for what is configured.
The views and the filters are the user's, and a vocabulary is only
closed to a client that can see it, so the description names them
rather than describing a shape a client would have to guess at.
The views are described by `org-records-mcp-view-catalogue-function' when
one is set, and the sentences that point into the per-view lines
give way to ones that hold for any text, since nothing in it is
marked."
  (let ((custom org-records-mcp-view-catalogue-function))
    (concat
     "Run a named view: a question the workflow has a name for, asked
over the allowed files.  "
     (if custom
         "Only configured views are accepted"
       "Only the names below are accepted")
     ", and a
view refuses a parameter it does not take rather than ignoring it.
Use org-query to write a query of your own, or to search files
outside the allowed ones.

Parameters:
  view - Name of the view to run (string, required)
         "
     (if custom
         "Views:\n"
       "Configured views, each with what it takes:\n")
     (org-records-mcp--view-catalogue-text)
     "  filter - Name of the filter to restrict the view by (string,
          optional); a view that takes no filter refuses one.
          Configured filters: "
     (org-records-mcp--configured-names org-records-mcp-filters) "
  range - Name of the range to run the view at (string, optional);
          a view that takes no range refuses one, and one that takes
          a range runs at "
     (if custom
         "its default when the call names none."
       "the range marked unasked above.")
     "
  fields - How much of each matching node to return (array of
          strings, or a string, optional)
          Defaults to the fields org-records-mcp-list-fields
          names, out of the box title, todo, priority, tags,
          scheduled, deadline and link: a match list is an
          overview, and the rest of a node is a read of its link
          away.  Naming fields asks for exactly those.
"
     org-records-mcp--fields-description
     "  properties - Which Org drawer properties to return (array of
          strings, or a string, optional)
          Defaults to none: a view is a query with a name, and a
          read of a match's link returns its drawer.  Name the
          properties a list is about, or \"all\".
"
     org-records-mcp--properties-description
     "  computed - Which computed fields to return (array of strings,
          or a string, optional)
          Defaults to the ones org-records-mcp-list-computed-fields
          names, none out of the box: a workflow names there the
          ones its lists sort or group by.  \"all\" and \"none\"
          override it.
"
     org-records-mcp--computed-description "
Returns JSON object:
  children - Array of matching nodes, the shape org-node-read
             returns, each carrying the fields the call asked for.
  total - Number of matches (number)
  files_searched - Number of files searched (number)
"
     org-records-mcp--node-description)))

(defun org-records-mcp--view-tool-specs ()
  "Return the spec for org-view when `org-records-mcp-views' configures one.
The tool is left out while no view is configured, so a client never
sees a tool that has nothing to answer with, and it carries the
views and the filters of the moment it is registered."
  (when org-records-mcp-views
    (list
     (list
      #'org-records-mcp--tool-view
      :id "org-view"
      :description (org-records-mcp--view-tool-description)
      :read-only t))))

(defconst org-records-mcp--clock-tool-specs
  (list
   (list
    #'org-records-mcp--tool-config-clock
    :id "org-config-clock"
    :description
    "Get the clock configuration from the current Emacs Org-mode
settings.  Returns clock-related settings.

Parameters: None

Returns JSON object with:
  org_clock_into_drawer - Where to put clock entries (literal Elisp)
  org_clock_rounding_minutes - Rounding interval in minutes (number)
  org_clock_continuously - Whether continuous clocking is enabled
  org_records_mcp_clock_continuous_threshold - Max minutes for continuous
    clocking gap

Use this tool to understand clock settings before clocking
in or out."
    :read-only t)
   (list
    #'org-records-mcp--tool-clock-active
    :id "org-clock-active"
    :description
    "Get the currently active clock, if any.  Searches all allowed
files for an unclosed CLOCK entry.  Also detects native Emacs clocks
running in non-allowed files via `org-clock-is-active'.

Parameters: None

Returns JSON object:
  active - Whether a clock is active (boolean)
  in_allowed_file - false when clock is in a non-allowed file
    (only present in that case; file/heading/start/link are omitted)
  file - File path of active clock (string, only if active
    in allowed file)
  heading - Title of the heading with the active clock, the title a
    read reports (string, only if active in allowed file)
  start - Start timestamp string (string, only if active
    in allowed file)
  link - Link to the heading with the active clock (string, only if
    active in allowed file): id:{id} when it has an ID, else
    file:{path}::#{custom-id} when it has a CUSTOM_ID, else
    file:{path}::*{title}"
    :read-only t)
   (list
    #'org-records-mcp--tool-clock-in
    :id "org-clock-in"
    :description
    (concat
     "Clock in to the specified heading.

Only one clock runs at a time.  While one runs, the call must name it
in clock_out, and that clock is closed first, at the new clock's
start.  Without clock_out, or with one naming another heading, the
call is refused and changes nothing; the refusal names the running
clock's heading by title and link, and its start, so ask the user
before clocking out of it.  A clock running outside the allowed files
cannot be named: ask the user to clock out of it.

A clock starts only in the allowed files, where org-clock-active and
org-clock-out find it: a link to a heading outside them is refused,
even one org-records-mcp-file-scope-override lets other tools reach.

When org-clock-continuously is enabled and no explicit start_time
is given, the new clock may start at the previous clock's end time
if it is within the continuous threshold.

Rounding is applied per org-clock-rounding-minutes.

The CLOCK line is written into the file and does not become the
Emacs session's running clock, so Org settings that act on that
clock do nothing here.  org-clock-out-when-done is the one to know:
a done keyword leaves the line open and reports no clock, and
org-clock-out is what closes it.

Parameters:
  link - Link to the node to clock in (string, required)
"
     org-records-mcp--heading-link-formats
     "  start_time - ISO 8601 start time (string, optional)
               Example: 2026-03-23T14:30:00
               Left out, or \"\" or whitespace, uses
               the current time (or continuous time)
               Must not be before the running clock's start
  resolve - true to delete the dangling (unclosed) CLOCK lines the
            heading itself carries, before clocking in (boolean,
            optional); one on a child of that heading is left alone,
            and the running clock is closed, never deleted; false, or
            leaving it out, means not to
  files - Files and directories to look up an id: link in (array of
          strings, optional); see org-node-read.  Not used for clock_out
  clock_out - Link to the heading of the running clock (string);
              required while a clock runs, refused while none does.
              The link a refusal names for it is accepted as sent;
              an id: link is looked up in the running clock's file.
              Left out, or \"\" or whitespace, names
              no clock to close

Returns JSON object:
  success - Always true on success (boolean)
  saved - False when a change, including closing the running clock
          in its own file, is only in the user's open Emacs buffer,
          not on disk; tell the user it needs saving (boolean)
  clocked_in - Always true (boolean)
  start - Formatted start timestamp (string)
  heading - The heading's title, as a read reports it (string)
  link - Link to the node (string): id:{id} when it has
         an ID, else file:{path}::#{custom-id} when it has a
         CUSTOM_ID, else file:{path}::*{title}
  resolved - Number of dangling clocks deleted (integer, only if
             resolve was requested and dangling clocks were found)")
    :read-only nil)
   (list
    #'org-records-mcp--tool-clock-out
    :id "org-clock-out"
    :description
    (concat
     "Clock out the running clock.

link names the clock to close: the heading whose CLOCK line is open,
which org-clock-active reports along with the link to it.  A link
naming any other heading, or a whole file, is refused and nothing is
closed, so the call cannot end a clock the user started somewhere the
client never looked.

Closing the clock stops the Emacs clock it belongs to, so a clock-in
after it needs no clock_out.  Org's clock-out settings decide what the
file holds afterwards: org-clock-out-remove-zero-time-clocks deletes a
CLOCK line of no length, and the drawer it empties, and
org-clock-out-switch-to-state rewrites the heading's TODO keyword.
The response reports neither, so read the heading back when it matters.

A clock running outside the allowed files is refused: org-records-mcp
starts no clock outside them and reports nothing about that clock, so
ask the user to clock out of it in Emacs.

Rounding is applied per org-clock-rounding-minutes.

Parameters:
  link - Link to the heading the running clock is on (string,
         required)
"
     org-records-mcp--heading-link-formats
     "  end_time - ISO 8601 end time (string, optional)
             Example: 2026-03-23T16:45:00
             Left out, or \"\" or whitespace, uses
             the current time
  files - Files and directories to look up an id: link in
          (array of strings, optional); see org-node-read
  note - Prose to record against the clock being closed (string,
         optional).  It is written under the closed CLOCK line, in
         the drawer that line sits in, the way Org records a note
         for a clock closed by hand.  Empty or whitespace-only
         values are ignored.  A clock of no length that
         org-clock-out-remove-zero-time-clocks takes away carries
         no note either, there being no clock line left to mark

Returns JSON object:
  success - Always true on success (boolean)
  saved - False when the change is only in the user's open Emacs
          buffer, not on disk; tell the user it needs saving (boolean)
  clocked_out - Always true (boolean)
  heading - The heading's title, as a read reports it (string)
  start - Start timestamp (string)
  end - End timestamp (string)
  duration - Duration as H:MM (string)
  link - Link to the node (string): id:{id} when it has
         an ID, else file:{path}::#{custom-id} when it has a
         CUSTOM_ID, else file:{path}::*{title}")
    :read-only nil)
   (list
    #'org-records-mcp--tool-clock-add
    :id "org-clock-add"
    :description
    (concat
     "Add a completed clock entry to a heading.  Creates a LOGBOOK
drawer if one doesn't exist.  New entries are inserted at the top
of the LOGBOOK.

Rounding is applied per org-clock-rounding-minutes.

Parameters:
  link - Link to the node (string, required)
"
     org-records-mcp--heading-link-formats
     "  start - ISO 8601 start time (string, required)
          Example: 2026-03-23T14:30:00
  end - ISO 8601 end time (string, required)
        Example: 2026-03-23T16:45:00
        Must be after start time
  files - Files and directories to look up an id: link in (array of
          strings, optional); see org-node-read

Returns JSON object:
  success - Always true on success (boolean)
  saved - False when the change is only in the user's open Emacs
          buffer, not on disk; tell the user it needs saving (boolean)
  added - Always true (boolean)
  start - Formatted start timestamp (string)
  end - Formatted end timestamp (string)
  duration - Duration as H:MM (string)
  link - Link to the node (string): id:{id} when it has
         an ID, else file:{path}::#{custom-id} when it has a
         CUSTOM_ID, else file:{path}::*{title}")
    :read-only nil)
   (list
    #'org-records-mcp--tool-clock-delete
    :id "org-clock-delete"
    :description
    (concat
     "Delete a clock entry from a heading.  Removes the LOGBOOK
drawer if it becomes empty after deletion.

Only the heading link names is touched: a CLOCK line on one of its
children belongs to that child, and a call naming the parent is
refused as no entry found.

start is the whole of what names the entry.  Where two entries of the
heading start at the same time it names neither, and the call is
refused with both described by their end times; delete the one you
mean in Emacs.

Rounding is applied per org-clock-rounding-minutes, so two starts a
few minutes apart can be written as one time and become such a pair.

Parameters:
  link - Link to the node (string, required)
"
     org-records-mcp--heading-link-formats
     "  start - ISO 8601 start time of the clock entry to delete,
          naming a time that exists
          (string, required)
          Example: 2026-03-23T14:30:00
  files - Files and directories to look up an id: link in (array of
          strings, optional); see org-node-read

Returns JSON object:
  success - Always true on success (boolean)
  saved - False when the change is only in the user's open Emacs
          buffer, not on disk; tell the user it needs saving (boolean)
  deleted - Always true (boolean)
  start - Start timestamp of deleted entry (string)
  end - End timestamp of deleted entry (string, present if closed)
  duration - Duration as H:MM (string, present if closed)
  link - Link to the node (string): id:{id} when it has
         an ID, else file:{path}::#{custom-id} when it has a
         CUSTOM_ID, else file:{path}::*{title}")
    :read-only nil)
   (list
    #'org-records-mcp--tool-clock-dangling
    :id "org-clock-dangling"
    :description
    (concat
     "Find all open (unclosed) clocks in allowed Org files, or in the
files named in `files'.  Searches for dangling CLOCK entries that
were never closed.  Uses Emacs native `org-find-open-clocks' on
each of those files.

Parameters:
  files - Files and directories to search (array of strings, optional)
          Replaces the allowed files for this call; when omitted, all
          allowed files are searched.
"
     org-records-mcp--files-set-description "
Returns JSON object:
  open_clocks - Array of open clocks, each with:
    file - File path (string)
    heading - The heading's title, as a read reports it (string)
    start - Start timestamp (string)
    link - Link to the heading (string): id:{id} when it has an ID,
           else file:{path}::#{custom-id} when it has a CUSTOM_ID,
           else file:{path}::*{title}
  total - Number of open clocks found (number)")
    :read-only t))
  "Specs for the clock tools, registered after org-view.
Same spec format as `org-records-mcp--core-tool-specs'.")

(defconst org-records-mcp--resource-specs
  (list
   (list
    "org://{link}" #'org-records-mcp--handle-org-resource
    :name "Org resource (structured JSON)"
    :description
    "Read an Org file or heading as structured JSON.  The URI is
org:// followed by a native Org link, the same link the org-node-read
tool takes, percent-encoded as in any URI.

URI format: org://{link}
  link - A native Org link, bare or as [[link]] or
         [[link][description]]:
    - id:{id} - heading with that ID
    - file:/path/to/file.org::#{custom-id} - heading with that
      CUSTOM_ID
    - file:/path/to/file.org::*{title} - first heading with that
      title
    - file:/path/to/file.org - whole file
    - id:{id} of the file-level property drawer - whole file
    Encode at least % as %25, # as %23, ? as %3F, spaces, [ and ].
    The link is decoded exactly once, so a literal % in a title is
    sent as %25: *50%25%20Done reads the heading \"50% Done\".
  Any other string, such as a bare ID or path, is refused.

Examples:
  org://id:550e8400-e29b-41d4-a716-446655440000
  org://file:/home/user/org/projects.org::%23alpha
  org://file:/home/user/org/projects.org::*Project%20Alpha

Returns: the node the link names, exactly as the org-node-read tool
returns it.

A link resolves, and is refused, exactly as in the org-node-read tool.
The file must be in the allowed files, or permitted by
org-records-mcp-file-scope-override."
    :mime-type "application/json"))
  "Specs for the resources org-records-mcp registers.
Each element is a `mcp-server-lib-register-server' `:resources' spec,
`(URI HANDLER :name STR [:description STR] [:mime-type STR])'.  The
`{link}' in the URI makes it a resource template.")

;;; Parameter types

(defconst org-records-mcp--param-types
  '((link . text)
    (parent . text)
    (previous_sibling . text)
    (clock_out . text)
    (title . text)
    (todo . text)
    (content . text)
    (note . text)
    (query . text)
    (start_time . text)
    (end_time . text)
    (start . text)
    (end . text)
    (files . texts)
    (tags . texts)
    (fields . fields)
    (computed . computed)
    (depth . count)
    (limit . count)
    (since . text)
    (resolve . flag)
    (before_planning . planning-map)
    (setting . setting)
    (view . view)
    (filter . filter)
    (range . range))
  "The JSON type each tool parameter is published with, by its name.
Each entry is (PARAMETER . KIND), KIND one of the kinds
`org-records-mcp--param-schema' turns into a JSON schema fragment.  A
parameter here means the same on every tool that takes it.  `before',
`after' and `properties' mean something different on different tools,
so they are not here: each tool taking one names it in
`org-records-mcp--tool-param-types', and a tool that does not is an
error rather than a guess.

Every parameter is declared, a plain string as much as an array, so
a handler parameter named in neither table is an error when
`org-records-mcp-enable' registers the tools rather than a string
published by default.  The readers of each kind still take the
JSON text of an array or an object, and the text null in a clearing
`after', from a client that sends every argument as a string; see
`org-records-mcp--array-param'.")

(defconst org-records-mcp--tool-param-types
  '(("org-node-set-todo" (before . text) (after . text-or-null))
    ("org-node-set-scheduled" (before . text) (after . text-or-null))
    ("org-node-set-deadline" (before . text) (after . text-or-null))
    ("org-node-set-priority" (before . text) (after . text-or-null))
    ("org-node-set-title" (before . text) (after . text))
    ("org-node-set-content" (before . text) (after . text))
    ("org-node-set-properties"
     (before . property-map)
     (after . property-map))
    ("org-file-set-setting" (before . texts) (after . texts))
    ("org-node-add-tags" (after . texts))
    ("org-node-remove-tags" (after . texts))
    ("org-node-set-tags" (before . texts) (after . texts))
    ("org-node-delete" (before . text))
    ("org-node-archive" (before . text))
    ("org-node-refile" (before . text))
    ("org-node-create" (properties . property-map))
    ("org-node-read" (properties . property-names))
    ("org-query" (properties . property-names))
    ("org-view" (properties . property-names)))
  "The parameters whose type depends on the tool taking them.
Each entry is (TOOL (PARAMETER . KIND)...), TOOL a tool id and KIND
as in `org-records-mcp--param-types'.  An entry here wins over one
there.")

(defun org-records-mcp--schema-enum (names)
  "Return NAMES, symbols or strings, as the vector of a JSON `enum'.
A name configured twice is listed once: the members of an `enum' are
distinct, and the reader takes the first entry of the name anyway."
  (vconcat
   (delete-dups (mapcar (lambda (name) (format "%s" name)) names))))

(defun org-records-mcp--schema-string (names)
  "Return the schema of a string that is one of NAMES.
With no NAMES the string is any string: a set with nothing in it is
nothing a client can be told to choose from."
  (if names
      `((type . "string")
        (enum . ,(org-records-mcp--schema-enum names)))
    '((type . "string"))))

(defun org-records-mcp--schema-names (names groups)
  "Return the schema of an array of NAMES, or of a string naming a group.
NAMES are the strings the array may hold, any string when nil.
GROUPS are the strings the parameter takes in place of an array, such
as \"all\"; with none, the parameter takes the array alone."
  (let ((array
         `((type . "array")
           (items . ,(org-records-mcp--schema-string names)))))
    (if groups
        `((anyOf . [,array ,(org-records-mcp--schema-string groups)]))
      array)))

(defun org-records-mcp--view-range-names ()
  "Return every range a configured view takes, each once."
  (seq-uniq
   (mapcan
    (lambda (entry)
      (copy-sequence (org-records-mcp--view-ranges (cdr entry))))
    org-records-mcp-views)))

(defun org-records-mcp--param-schema (kind)
  "Return the JSON schema fragment a parameter of KIND is published with.
KIND is one of:
  text           a string
  text-or-null   a string, or null asking a field to hold nothing
  texts          a string or an array of strings: one tag, line or
                 path, or several
  count          a whole number, 0 or more
  flag           true or false
  fields         an array of node field names, or the name of a list
                 in `org-records-mcp-node-field-lists'
  property-names an array of property names, or \"all\" or \"none\"
  computed       an array of the names `org-records-mcp-computed-fields'
                 configures, or \"all\" or \"none\"
  property-map   an object of one property or more, whose values are
                 a string, a number, a boolean or null
  planning-map   an object of the planning fields a call asserts,
                 each holding a timestamp
  setting        one of `org-records-mcp--file-settings'
  view           one of the views `org-records-mcp-views' configures
  filter         one of the filters `org-records-mcp-filters' configures
  range          one of the ranges a configured view takes

A kind drawing its names from a setting reads the setting now, so
the schema of a tool is that of the moment `org-records-mcp-enable'
registers it."
  (pcase-exhaustive kind
    ('text '((type . "string")))
    ('text-or-null '((type . ["string" "null"])))
    ('texts '((type . ["string" "array"]) (items (type . "string"))))
    ('count '((type . "integer") (minimum . 0)))
    ('flag '((type . "boolean")))
    ('fields
     (org-records-mcp--schema-names
      org-records-mcp--node-fields
      (mapcar #'car org-records-mcp-node-field-lists)))
    ('property-names
     (org-records-mcp--schema-names nil '("all" "none")))
    ('computed
     (org-records-mcp--schema-names
      (mapcar #'car org-records-mcp-computed-fields) '("all" "none")))
    ('property-map
     '((type . "object")
       (minProperties . 1)
       (additionalProperties
        (type . ["string" "number" "boolean" "null"]))))
    ('planning-map
     `((type . "object")
       (properties
        .
        ,(mapcar
          (lambda (entry)
            (list (car entry) '(type . "string") '(minLength . 1)))
          (org-records-mcp--planning-asserted)))
       (additionalProperties . :json-false)))
    ('setting
     (org-records-mcp--schema-string org-records-mcp--file-settings))
    ('view
     (org-records-mcp--schema-string
      (mapcar #'car org-records-mcp-views)))
    ('filter
     (org-records-mcp--schema-string
      (mapcar #'car org-records-mcp-filters)))
    ('range
     (org-records-mcp--schema-string
      (org-records-mcp--view-range-names)))))

(defun org-records-mcp--param-kind (tool parameter)
  "Return the kind TOOL publishes its PARAMETER as, a symbol.
See `org-records-mcp--param-types'.  A parameter neither table declares
is an error naming TOOL and PARAMETER."
  (or
   (alist-get
    parameter (cdr (assoc tool org-records-mcp--tool-param-types)))
   (alist-get parameter org-records-mcp--param-types)
   (error
    "Tool %s takes %s, which org-records-mcp--param-types does not type"
    tool parameter)))

(defun org-records-mcp--typed-tool-spec (spec)
  "Return SPEC, a `:tools' spec, with the JSON type of every parameter.
The types go in `:param-schemas', one entry per parameter of the
handler, so the published schema carries no type `mcp-server-lib'
filled in by default."
  (let ((tool (plist-get (cdr spec) :id)))
    (append
     spec
     (list
      :param-schemas
      (mapcar
       (lambda (parameter)
         (cons
          (symbol-name parameter)
          (org-records-mcp--param-schema
           (org-records-mcp--param-kind tool parameter))))
       (remq '&optional (help-function-arglist (car spec) t)))))))

(defun org-records-mcp-enable ()
  "Enable the org-records-mcp server.
Registers every tool and the org:// resource template under
`org-records-mcp--server-id'.  Whether org-view is among them depends on
`org-records-mcp-views' at the time of the call, and its description carries
the views and the filters configured then.  So does every tool\\='s
schema: a parameter taking a configured name, such as a view, a
filter, a range, a computed field or a field list, lists the names
configured at the time of the call; see `org-records-mcp--param-schema'.

Registrations are reference counted: a spec registered twice needs
two `org-records-mcp-disable' calls before it goes, and the second
registration keeps the properties of the first."
  (mcp-server-lib-register-server
   :id org-records-mcp--server-id
   :version org-records-mcp-version
   :tools
   (mapcar
    #'org-records-mcp--typed-tool-spec
    (append
     org-records-mcp--core-tool-specs
     (org-records-mcp--view-tool-specs)
     org-records-mcp--clock-tool-specs))
   :resources org-records-mcp--resource-specs))


(defun org-records-mcp-disable ()
  "Disable the org-records-mcp server.
Drops one reference to everything registered under
`org-records-mcp--server-id', removing whatever reaches zero.  It works on
what is registered at the time of the call, not on what a particular
`org-records-mcp-enable' added: an inner enable that configured no views
where an enclosing one did takes the enclosing call's org-view away
when it is undone."
  (mcp-server-lib-unregister-server org-records-mcp--server-id))


;;; Script Installation

(defun org-records-mcp--package-script-path ()
  "Return the path to org-records-mcp-stdio.sh in the package directory.
Returns nil if not found."
  (let* ((library-path (locate-library "org-records-mcp"))
         (package-dir
          (and library-path (file-name-directory library-path)))
         (script-path
          (and package-dir
               (expand-file-name "org-records-mcp-stdio.sh"
                                 package-dir))))
    (when (and script-path (file-exists-p script-path))
      script-path)))

(defun org-records-mcp--installed-script-path ()
  "Return the path where org-records-mcp-stdio.sh should be installed.
Reuses `mcp-server-lib-install-directory' so org-records-mcp-stdio.sh
lands next to emacs-mcp-stdio.sh, which it resolves relative to
its own directory."
  (expand-file-name "org-records-mcp-stdio.sh"
                    mcp-server-lib-install-directory))

;;;###autoload
(defun org-records-mcp-install ()
  "Install org-records-mcp-stdio.sh to `mcp-server-lib-install-directory'.
The wrapper script resolves emacs-mcp-stdio.sh relative to its
own directory, so installing both shims to the same directory
(the default behaviour, since org-records-mcp reuses mcp-server-lib's
install directory) lets MCP clients invoke org-records-mcp-stdio.sh with
no extra configuration."
  (interactive)
  (let ((source (org-records-mcp--package-script-path))
        (target (org-records-mcp--installed-script-path)))
    (unless source
      (error
       "Cannot find org-records-mcp-stdio.sh in package directory"))
    (when (file-exists-p target)
      (unless (yes-or-no-p
               (format "File already exists at %s. Overwrite? "
                       target))
        (user-error "Installation cancelled")))
    (make-directory (file-name-directory target) t)
    (copy-file source target t)
    (set-file-modes target #o755)
    (message "Script installed to: %s" target)))

;;;###autoload
(defun org-records-mcp-uninstall ()
  "Remove installed org-records-mcp-stdio.sh from `mcp-server-lib-install-directory'."
  (interactive)
  (let ((target (org-records-mcp--installed-script-path)))
    (unless (file-exists-p target)
      (user-error "No script found at: %s" target))
    (when (yes-or-no-p (format "Remove script at %s? " target))
      (delete-file target)
      (message "Script removed from: %s" target))))

(provide 'org-records-mcp)
;; scripts/format-elisp.el lays this file out for 70 columns.
;; Local Variables:
;; fill-column: 70
;; End:
;;; org-records-mcp.el ends here
