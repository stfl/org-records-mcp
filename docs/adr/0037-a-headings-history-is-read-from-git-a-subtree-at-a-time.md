# A heading's history is read from git, a subtree at a time

`org-node-history` reads the revisions of a heading's file from the git
repository it is committed in, parses each with Org in a scratch buffer, finds
the heading there, and answers with the revisions whose subtree changed, each
as a unified diff of that subtree alone. A client learns what changed on one
heading since it last looked at the cost of what changed on that heading, not
of `git log -p` over the file.

We chose git over a record org-records-mcp would keep itself, because the files
it serves are already committed by the user's own sync, every edit included —
in Emacs, on a phone, by another client — and a record of org-records-mcp's own
would see only the edits that went through it. We chose Org's parser over
git's own line diff of the file, because a hunk of the file says nothing about
which heading it belongs to, and only the subtree's own text, found as Org
finds it, does.

`since` takes a commit or a time, and the answer carries `current`, the commit
`HEAD` names, read once when the history begins, which sent back as `since`
partitions the first-parent line: no revision is answered twice and none is
skipped, a commit landing during the call included. A time alone cannot promise
that, because commits share a second. The window counts the first-parent line
only, so consecutive revisions are each other's parent as far as the file
goes, whatever merges the history holds.

The heading is followed back by its ID, else its CUSTOM_ID, else its outline
path, else its title where one heading alone carries it and that heading is
not one still standing where it stood. That is best effort, and its limit is
stated rather than hidden: a heading carrying neither identifier is not
followed past a change of its title, and appears there. We chose that over
guessing by position or by similarity of text, because a wrong guess hands a
client another heading's history as this one's, and nothing in the answer
would say so. A move under another parent is a change of the parent heading,
judged by the same identifiers, else by its place or its titles, so a parent
renamed moves nothing under it. A heading refiled between files is named as moving only when one
commit took its ID or CUSTOM_ID out of one file and into the other, and only
when the call could reach the other file: a history names no file a read would
refuse.

A window holding more revisions than `org-records-mcp-history-max-revisions`
is refused, never cut, for the reason ADR 0008 gives for a read. A `limit` the
caller sends is different: the caller asked for less, and `complete` says
whether older revisions were left unread.
