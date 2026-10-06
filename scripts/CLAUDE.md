# scripts/

The scripts `just` calls. Each one is written against a `PATH` that already has
its tools: a script never enters `nix develop` for itself, because the caller
owns the environment. A missing tool is a fast failure with a hint, not a
self-wrap.

## The quiet contract

`quiet.sh` is what makes `just lint` silent. It captures the stage's output to
`.lint-output.txt` at the repository root whether the stage passed or failed,
prints nothing on success, and on failure prints `lint failed: output at
.lint-output.txt` and propagates the exit code. Every lint stage in the
`Justfile` goes through it, so a new stage that prints its own progress breaks
the property the whole suite is built on — wrap it.

Each stage overwrites that one file, and the stages run in the order the `lint`
recipe lists them, stopping at the first failure. So the file holds the failing
stage's output, and after a green run the last stage's.

`run-tests.sh` runs `check-deps.el` before the suite, then always writes
`.test-output.txt`, whether or not the suite passed, and prints only the
`Ran N tests` summary on success. On failure it
prints the ERT block from the first `Test ` line onwards. When a test fails,
read `.test-output.txt` rather than re-running the suite.

Both output files are gitignored.

## check-deps.el

It is the preflight that keeps a stale dependency from failing the suite in a
hundred places at once: silent when the installed mcp-server-lib is good,
non-zero with the remedy when it is missing or older than the requirement. Keep
it first in `run-tests.sh`; running it after the suite buys nothing.

It probes what arrived in the required version — today a tool spec carrying
`:param-schemas`, which is 0.5.0 and adds no public symbol, so the probe
registers a throwaway server and drops it. **Raising the floor in `Eask`
obliges moving that probe to what the new version adds.** A probe left behind
passes a copy that is too old, which then dies inside the ERT helpers, and the
guard has moved the confusing failure rather than removed it.

Its commentary carries why the `require` is soft and why it stays inside the
`cond`. Both are load-bearing; read it before restructuring the file.

## format-elisp.el

`just fmt` runs it on `org-records-mcp.el` under the devshell's Emacs. It refuses any
Emacs but 31, and any Emacs without elisp-autofmt, because the layout depends on
both: formatting elsewhere would produce a diff that the next machine undoes. It
sets `fill-column` to 70 itself, since batch Emacs refuses `.dir-locals.el` as a
whole, and it turns file-local variables off while formatting.

`org-records-mcp-format--passing-messages` is the subtle part. elisp-autofmt reports
everything by `message`, including complaints after which it formatted the
buffer anyway, such as a cache it could not write. Those prefixes are listed
there and pass; every other `elisp-autofmt: ` message is raised as an error.
Adding a prefix to that list without checking that the buffer really is
formatted turns a silent non-format into a green run.

## What a new script owes the Justfile

The lint and format recipes name their files one by one; nothing globs. A new
script is unformatted and unchecked until it is added:

- a shell script → the `shfmt` recipe (`-i 4`) and the `shellcheck` recipe
- an Elisp script → nothing to add: `script-compile` byte-compiles
  `scripts/*.el` with `byte-compile-error-on-warn`, so any warning in it fails
  `just lint`, and the `.elc` files it produces are removed again by the recipe

The byte-compile stage is the one that catches an unused variable or a missing
`declare-function` in a script, and its message names the script, not the
recipe.
