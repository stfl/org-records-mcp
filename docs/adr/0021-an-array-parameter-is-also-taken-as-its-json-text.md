# An array parameter is also taken as its JSON text

Every parameter documented as taking an array — `fields`, `properties`,
`computed`, `files` and `tags` — also takes the JSON text of that array, and
reads it back as the array before any other check runs. A value whose first
non-blank character is `[` and which is not a JSON array is refused, naming the
parameter.

The advertised schema publishes each of these parameters as an array, through
`mcp-server-lib`'s per-parameter `:param-schemas` (ADR 0034), so a client that
validates its arguments against it sends a JSON array. A client that sends
every argument as a string, whatever the schema says, cannot send an array at
all: it sends the array as its own JSON text, and without this the text arrives
as one value — one field-list name, one tag, one path spelled with brackets.
This decoding is the compatible path for that client.

Reaching into `mcp-server-lib`'s registry after registration to rewrite the
schema was rejected — it is private state, and a server that edits its
library's bookkeeping breaks on the release that reorganises it. The schema is
declared through the library's own tool spec instead.

A leading `[` is unambiguous for all five parameters: a file path is absolute,
a field, property or computed name is an identifier, and `org-tag-re` forbids
`[` in a tag. So the text form costs nothing a caller could have meant, and
every string form each parameter already offers — a single tag, a single path,
`all`, `none`, the name of a configured field list — goes on meaning what it
meant.
