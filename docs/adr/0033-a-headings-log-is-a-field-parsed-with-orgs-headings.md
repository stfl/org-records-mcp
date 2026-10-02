# A heading's log is a field, parsed with Org's headings

A heading's log notes are a node field, `log`: the list items of the drawer
`org-log-into-drawer` names for the heading (`LOGBOOK` when it names none),
newest first, each an object of `kind`, `time`, `from`, `to` and `text`, each
left out when the entry has none (ADR 0005). `kind` is the purpose whose
heading in `org-log-note-headings` matches the entry's line, so the vocabulary
is the user's configuration rather than a list of English strings, and an item
no heading matches carries its `text` and no `kind`. A `clock-out` note, whose
heading is empty, is recognised by where Org writes it, right below its clock,
whatever `org-log-note-clock-out` says, and takes the time that clock ended.
CLOCK lines are not entries: the clock tools own them. The field is left out
of a heading with no entry and of a file. A read carries it unasked; a match
list carries it when the call or `org-records-mcp-list-fields` names it.

Like `breadcrumbs` and `blocked` (ADR 0032) the log is what Org says about the
node, so it is a field rather than a computed field each workflow would parse
on its own. Org writes log notes and has no function that reads them back;
org-habit and the agenda's log mode each build a regexp from a heading, and the
field does the same for every heading. The drawer is read in the order
`org-log-states-order-reversed` says Org wrote it, so the answer is newest
first under either value and a client never needs the setting to read it. It
is not in the list default, because a list is an overview (ADR 0031) and the
field reads every match's drawer.

We chose this over widening `content` to include the drawers, which hands a
client Org's text to parse and makes the region `org-node-set-content` writes
differ from the one it reads, and over sorting entries by their timestamps,
which a hand-typed item has none of. We chose the clock's end as a clock-out
note's time over leaving it out, since Org writes the note as that clock
closes, and a client ordering a log by time would otherwise have nothing to
place the note by.
