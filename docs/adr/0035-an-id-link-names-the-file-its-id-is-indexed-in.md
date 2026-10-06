# An id: link names the file its ID is indexed in

An `id:` link resolves to the file Emacs's ID index places its ID in, and
org-records-mcp checks that file as one the call names (ADR 0001). The file is
reached when it is among the allowed files, and otherwise as far as the
override policy permits: any local Org file under `t`, a file under an override
root, and none under `nil`. The check runs on the index's answer before any
file operation, so a remote file, a symlink to one and a file the policy
refuses are all refused unread. The error names the link and never the file.
A miss rescans the index once, as `org-id-find` does, and the file the rescan
names goes through the same check. `files` keeps its meaning: with it, the ID
is looked up in the named files instead of the index.

IDs are how an Org user links across a tree, between agenda files and notes
alike, and the override policy is where that user has already said which
files a call may reach. We chose this over keeping an `id:` link inside the
allowed files unless the call lists the ID's file in `files`. That made the
policy depend on the form of the link: the same heading was reachable by its
`file:` link and refused by its `id:` link. It also made an agent following a
link into a note repeat `files` on every call. We also chose it over adding the
notes to the allowed files, which would put them into every view, and over a
separate setting for IDs, a second policy answering the same question.

What a search covers does not change. A view always runs over the allowed
files, and so does `org-query` sent without `files`, so following a link
widens what one call reaches and never what a view searches. The file of the
running clock is not named by a call either, so a clock running outside the
allowed files stays out of reach.
