# A clock starts only in the allowed files

`org-clock-in` refuses a heading outside the allowed files, even one the
override policy lets every other tool reach by a `file:` link, an entry of
`files`, or an `id:` link (ADR 0035). The refusal names the link and comes
before any check of the running clock, so a refused call closes nothing.

A running clock is state that outlives the call that starts it, and a scope
override lasts for that one call (ADR 0001). `org-clock-active`,
`org-clock-out` and the next `org-clock-in` look for the running clock in the
allowed files alone, so a clock started in a file the override reached runs
where no later call finds it: `org-clock-active` reports no clock,
`org-clock-out` has nothing to stop, and a second `org-clock-in` opens another
clock beside it. We chose the refusal over widening the search for a running
clock to everything the override permits, which under `t` is every Org file
Emacs can read, and over remembering where a clock was started, which would
carry one call's override into the calls after it.

`org-clock-add` and `org-clock-delete` leave no clock running, so they reach
every heading the override permits, as the other write tools do.
