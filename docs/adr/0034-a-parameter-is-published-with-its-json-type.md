# A parameter is published with its JSON type

Every tool parameter is published in `inputSchema` with the JSON type it
takes: a string or an array for `files`, tags and settings lines, an array
for the field, property and computed lists, an object for a property map and
`before_planning`, a string or null for a
clearing `after` (ADR 0016), a boolean for `resolve`, an integer for `depth`,
and a string for everything else. The types are declared in one table by
parameter name, and the parameters whose type differs between tools —
`before`, `after` and `properties` — in a second table, per tool, with no
default to fall back on. Both reach the schema through `mcp-server-lib`'s
`:param-schemas`. A plain string is declared like
any other type, so a handler parameter the table does not name is an error at
registration rather than a string published by default, which is how every
array, object and null came to be published as a string.

A parameter that takes a name from a closed set publishes the set as an
`enum`: the node fields, `all` and `none`, the settings `org-file-set-setting`
writes, and the names the user configures — field lists, computed fields,
views, filters and ranges. Configured names are read when
`org-records-mcp-enable` registers the tools, the moment the `org-view`
description is written (ADR 0010), so the schema and the description always
agree. A name configured afterwards is one the server accepts and a client
checking the schema refuses, until the tools are registered again and the
client reconnects. We chose that over leaving configured names untyped, which
leaves a client nothing to check a name against and invites it to invent one,
and over rebuilding the schema on every `tools/list`, which would mean
rewriting the library's registry (ADR 0021). A kind of name with nothing
configured publishes no `enum` rather than an empty one, which admits no value
at all and which some validators reject as a malformed schema: a filter is then
any string, and `fields` an array of field names without the string form.

An optional parameter is published without null, though every reader takes
null, false, `""` and `[]` there as the parameter left out: leaving it out is
the one spelling the schema states, and null is published only where it is a
value of its own, in a clearing `after` and in a property map. A parameter
taking a list of names or a group name drawn from a closed set — `fields`,
`properties`, `computed` — is published as `anyOf` an array and a string
`enum`, since one `type` array cannot give its two forms different `enum`s; a
string or an array of free text, such as tags, is one `type` array. The text
decoding of ADRs 0021, 0029 and 0030 stays beside the schema: the schema tells
a client what to send, and the decoding reads what a client that sends every
argument as a string sends instead.
