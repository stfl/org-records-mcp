# An id: link names the file its ID is indexed in

An `id:` link resolves to the file Emacs's ID index places its ID in, and
org-records-mcp checks that file as one the call names (ADR 0001). The file is
reached when it is among the allowed files, and otherwise as far as the
override policy permits: any local Org file under `t`, a file under an override
root, and none under `nil`. The check runs on the index's answer before
org-records-mcp reads the file it names, so a remote file, a symlink to one and
a file the policy refuses are refused without org-records-mcp reading them,
and the error names the link and never the file. A refused answer ends the
lookup. A miss rescans the index once, as `org-id-find` does, and the file the
rescan names goes through the same check. The rescan itself is Org's: it reads
every file Org knows of, whatever the scope, the files in `org-id-files`
included, and resolving a remote one there reaches TRAMP. With `files`, the ID
is looked up in the named files and the index is not consulted. Where the
index holds an ID in two files, such as a heading and its copy in an
`.org_archive` file or a duplicated note, the file the index names is the one
reached, as with `org-id-goto`.

IDs are how an Org user links across a tree, between agenda files and notes
alike, and the override policy is where that user has already said which
files a call may reach. We chose this over keeping an `id:` link inside the
allowed files unless the call lists the ID's file in `files`. That alternative
makes the policy depend on the form of the link: the same heading is reachable
by its `file:` link and refused by its `id:` link, and an agent following a
link into a note repeats `files` on every call. We also chose it over adding
the notes to the allowed files, which puts them into every view, and over a
separate setting for IDs, a second policy answering the same question.

A search covers the allowed files. A view always runs over them, and so does
`org-query` sent without `files`, so following a link widens what one call
reaches and never what a view searches. The file of the running clock is not
named by a call, so a clock running outside the allowed files stays out of
reach, and a clock starts only in the allowed files (ADR 0036).
