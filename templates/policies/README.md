# nyann seed policy pack (OPA / Conftest)

Policies for the opt-in `iac-policy` guard. Copy this directory into your
repo to start (the guard reads `.nyann/policies` by default; override via
the profile's `guards.iac_policy_dir`):

```sh
cp -r <plugin_root>/templates/policies .nyann/policies
```

Enable the guard by naming it in a flow in your profile:

```jsonc
"guards": { "pr": [ { "name": "iac-policy", "severity": "advisory" } ] }
```

## The two input contracts

The guard runs Conftest in one of two modes, and a policy written for one
mode never fires in the other — write for the mode you enable, and check
`[files]` / `[plan]` in the guard's message to see which ran.

1. **File mode** (the pre-action guard on pr/release/ship): Conftest
   parses the changed IaC FILES themselves (`*.tf`, `*.tfvars`,
   `*.yaml`). `input` is the parsed document — e.g. for HCL,
   `input.resource.aws_s3_bucket[name]`. Filesystem-only: this mode
   never runs a cloud CLI.
2. **Plan mode** (inside `/nyann:plan` and `/nyann:apply`, after YOU ran
   the plan): `input` is nyann's normalized IacPlan JSON —
   `input.summary.{add,change,destroy}`, `input.tool`, `input.unit`,
   `input.destructive`. Example:

   ```rego
   package main

   deny[msg] {
     input.summary.destroy > 0
     msg := sprintf("plan destroys %d resource(s) — destructive changes need a ticket reference", [input.summary.destroy])
   }
   ```

Rules use the default Conftest namespace (`package main`); `deny` blocks,
`warn` advises. `conftest test --policy .nyann/policies <file>` runs the
same evaluation by hand.
