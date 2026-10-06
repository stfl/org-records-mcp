# A clearing `after` also takes null as its JSON text

Every `after` that takes JSON null to take a value away — on
`org-node-set-todo`, `org-node-set-scheduled`, `org-node-set-deadline` and
`org-node-set-priority` — also takes the text `null`, and reads it as null
before the field's own checks run. The text is exactly the four lower-case letters
JSON spells null in; `NULL`, `Null` and `" null"` are strings like any other,
and meet the field's own refusal.

The cause is the one ADR 0021 records for arrays and ADR 0029 for objects: the
advertised schema publishes these four `after` parameters as a string or null
(ADR 0034), and a client that sends every argument as a string, whatever the
schema says, cannot send null at all and sends the text instead.
Without this the text meets the field's own validator, which refuses it with a
message naming null as the way to take the value away — the one value that
client cannot produce. Null in an `after` is the removal ADR 0016 settles on, so
without this no keyword, SCHEDULED, DEADLINE or priority can be taken away
through such a client.

The reason it is safe differs per field, and is recorded here rather than
inherited. A priority is one character and a timestamp is a date Org's parser
accepts, and `null` is neither, so on those three the text takes away nothing a
caller could have meant: read as a value it could only be refused. A
TODO keyword is a word a file configures, and a file may configure `null`. Where
the target file's workflow names a keyword `null`, the text sets that keyword
and a `before` of `"null"` asserts it; only a real JSON null takes the keyword
away there. So the text is read once the file is known, not before, and the
file's own spelling wins. We chose that over reading the text as null in every
file, which would leave such a keyword unreachable by every client, and over
refusing the text in such a file, which buys the client nothing: the keyword
stays out of reach and so does the removal. The one cost is that a client that
cannot send null cannot take the keyword away in a file that chose that
spelling. The inverse needs no special case: moving a heading off the keyword
`null` asserts it with `before: "null"`, which is a keyword like any other.

Only a top-level `after` that takes null to clear is read this way. A `before`
names a state the field was in, and `""` spells the empty one, so there the
text `null` stays text and is a conflict on a field holding nothing. A title, a
body and a settings line are text with values of their own, and write the four
letters. A value inside a property map needs nothing: the map is sent as JSON
text under ADR 0029, and null inside that text is already null. The
`org-node-set-properties` map value `"null"` is therefore the property's text.

This reading is the compatible path for clients that send the text; a client
that follows the schema sends null.
