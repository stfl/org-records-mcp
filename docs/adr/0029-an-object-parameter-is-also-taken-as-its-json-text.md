# An object parameter is also taken as its JSON text

Every parameter documented as taking a JSON object — `before` and `after` on
`org-node-set-properties`, `properties` on `org-node-create` and
`before_planning` on `org-node-set-todo` — also takes the JSON text of that
object, and reads it back as the object before any other check runs. A value
whose first non-blank character is `{` and which is not a JSON object is
refused, naming the parameter.

The cause is the one ADR 0021 records for arrays: the advertised schema
publishes these parameters as objects (ADR 0034), and a client that sends every
argument as a string, whatever the schema says, cannot send an object at all
and sends the object's text instead. Without
this the text meets the parameter's own check as a string and is refused, which
leaves a property unwritable through such a client — `before` is required beside
`after`, so both have to reach the tool together — and a repeating
heading's state unchangeable, since that change requires `before_planning`.

The fix is 0021's, but its reason for being safe is not, so it is recorded
here rather than inherited. A leading `[` is safe for the array parameters
because of what their strings look like: a path is absolute, a name is an
identifier, a tag cannot hold a bracket. None of the four object parameters
takes a string at all. `""` is blank, the parameter left out, like null,
false, `[]` and `{}`; every other string is refused by the parameter's own
check. So the text form takes away no string a caller could have meant, and
the argument holds whatever the text looks like after its brace. Text that
opens with anything but `{` — `"null"`, a JSON string, an array — is not read
back, and meets the parameter's own refusal.

The text `"{}"` decodes to what `{}` decodes to, and so means what `{}` means
wherever it stands: no properties on a new node, a missing `before` or `after`,
no planning assertion. Only the parameter is read back, once: a property value
that begins with `{` inside the decoded object is written as the text it is.
