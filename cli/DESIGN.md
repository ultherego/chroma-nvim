# `chroma` — installer and CLI, V1 architecture

The architecture. A skeleton of it exists — the component reader, `version`,
`components` and `doctor`; everything that writes to a disk does not. Rule #1
applies here as it does everywhere else: read the current documentation of every
Go library before using it.

This describes what the CLI is, what it refuses to do, and the one interface it
shares with the Lua side. It does not describe how to write Go.

---

## What it is for

Installing this configuration by hand works and is documented. It also asks the
user to know which external tools each part needs, to pick a directory strategy,
and to notice when something is missing rather than silently unused. The CLI
exists to do those three things, and to make an installed configuration
describable — so that `update` does not have to ask everything again.

**One rule above the others: it never installs `main`.** It installs a release.
`main` is where the work happens and it is allowed to be broken; a release is
the thing that has been through CI on the exact commit it names.

---

## Placement

`cli/` is a Go module inside this repository. Not a separate repository, and not
a package inside the Lua tree.

**Why in the same repository.** The installer and the configuration share one
fact — the list of components and what each needs — and that fact must not exist
in two places that can drift. They also share a release: `v2.1.0` is one tag
naming one configuration and one CLI that understands it. Splitting the repo
would mean versioning that agreement across a boundary, which is the expensive
kind of problem to discover later.

**Why a module of its own.** `cli/go.mod` keeps the Go toolchain, its
dependencies and its lockfile out of a tree that is otherwise Lua. Nothing in
`lua/` may import it, and nothing in `cli/` may parse Lua. They meet at the
component contract below and nowhere else.

```
cli/
  go.mod  go.sum
  cmd/chroma/            entry point, flag parsing, exit codes
  internal/
    component/           reads and validates the component contract
    resolve/             dependencies, conflicts, the plan
    detect/              what is on this machine: tools, versions, package manager
    pkg/                 per-manager install commands; knows how to say "I cannot"
    install/             fetch a release, place it, back it up, bootstrap Neovim
    state/               the installed-state file
    health/             preflight, and `doctor`
    tui/                 the interactive layer, and nothing else
```

`tui/` holds no decisions. Everything it displays comes from `resolve` and
`detect`, so `--non-interactive` is not a second implementation.

---

## The component contract

This is the part worth getting right, because it is the only place the two
languages meet.

**One file per component, in `components/` at the repository root, in JSON.**

JSON rather than YAML because Lua reads it with `vim.json.decode` and no
dependency, while Go reads it with the standard library. A format that needs a
library on one side is a format that will eventually be parsed by hand on the
other. The files are data, not configuration to be edited by users.

```json
{
  "contract": 4,
  "id": "terraform",
  "name": "Terraform / OpenTofu",
  "requires": ["core"],
  "tools": {
    "required": [
      { "any": ["terraform", "tofu"], "reason": "plan, apply and formatting all shell out" }
    ],
    "recommended": [
      { "id": "terragrunt", "reason": "directories holding terragrunt.hcl are run and formatted with it" }
    ]
  },
  "nvim": {
    "servers": ["terraformls", "tflint"],
    "mason": ["tflint"],
    "parsers": ["terraform", "hcl"],
    "formatters": ["terraform_fmt", "tofu_fmt", "terragrunt_hclfmt"],
    "modules": ["chroma-terraform"]
  }
}
```

**The `nvim` block is a list of names, one list per kind of thing the editor
switches on.** `servers`, `mason`, `linters`, `parsers`, `formatters`,
`schemas`, `plugins`, `modules`. Each is a name the editor already uses for that
thing: an nvim-lspconfig server name, a Mason package, a conform formatter, a
lockfile key, a `require` path. The CLI does not act on any of it; it is here so
that both halves of a component are one document.

**`formatters` and `schemas` are the two that made this contract 4.** Until they
existed, a selection decided servers, packages, linters, parsers, plugins and
modules — and then `.tf` files were still formatted by `terraform fmt` on save
and `k8s/**` was still validated against the Kubernetes schema, whatever anybody
had chosen. A checkbox that leaves the behaviour it names running is not a
checkbox.

**`schemas` carries logical names, and nothing else.**

```json
{ "nvim": { "schemas": ["kubernetes"] } }
```

Not the URL, not the file patterns, not the shape yaml-language-server wants
them in. Which document `kubernetes` is, which version it is pinned to and which
paths it applies to live in `lua/chroma/schemas.lua` — the same split as tool
versions above: the contract says *what*, an implementation registry knows
*how*. A contract that a web page or a different editor is meant to be able to
read has no business carrying one language server's settings shape.

**And it is narrow on purpose.** `schemas` is for mappings Chroma adds
deliberately — "these paths hold Kubernetes manifests" is a decision this
configuration made, so it belongs to the component that made it. It is not a
filter over what the SchemaStore catalogue can recognise by itself. A workflow
file matching the GitHub Actions schema from the shared catalogue is core YAML
support doing its job; switching off `github-actions` removes actionlint, not
yaml-language-server's ability to read a document it recognises. The line is:

> a disabled component takes away what Chroma switched on for that domain. It
> does not make Core pretend it cannot read a file.

Both sides read the same files, from a tree, at runtime:

- **Lua** reads them from the configuration it is part of, so
  `:checkhealth chroma` reports per component and the plugin layer can skip what
  is not enabled.
- **Go** reads them from whichever tree it is working on: the release it has
  just fetched, or the configuration already installed.

An earlier draft of this document had the CLI embed them at build time. That is
not possible as laid out here and the constraint is worth recording rather than
discovering twice: `go:embed` cannot reach outside its own package directory —
`../..` is rejected as invalid pattern syntax, measured, not assumed — and
`components/` sits at the repository root while the module is in `cli/`.

Copying them into the module at build time would work and is exactly the kind of
duplication this contract exists to prevent. Reading from a tree costs nothing:
every command that needs the contract already has a tree, because fetching
happens before any of them decides anything.

**A tool may carry a version, and the constraint is data rather than prose.**

```json
{ "id": "tree-sitter", "version": { "min": "0.26.1" }, "reason": "compiling parsers" }
```

`exact`, or `min` and/or `max` — never both kinds, because "exactly 1.2 and at
least 1.0" is two answers to one question. Deliberately not a constraint
language: `>=1.2,<2.0 || >=3.0` is a grammar, a parser and a class of bug, and
nothing here has needed one. That is what took the contract from 1 to 2; the
readers of contract 1 correctly refuse a `version` field they have never heard
of, which is the version check doing its job.

**How to read a version is not in the contract.** A manifest says *what* is
required, which is a fact about the product. That `kubectl` needs `version
--client` while Info-ZIP has no `--version` at all and prints its own on the
second line of a usage message — measured, both — is a fact about those
executables, and it changes when they do. It lives in the CLI's own registry, so
the shared contract never carries this CLI's implementation details.

```
components/*.json          says WHAT is required
        ↓
   the requirement
        ↓
 the CLI's tool registry    knows HOW to ask this executable
        ↓
   version, or unknown
```

An unknown version satisfies no constraint. A tool that will not say what it is
cannot be shown to be new enough, and guessing in its favour is the false
positive this exists to remove: `exec.LookPath` succeeds, and the thing is too
old to do the job.

`:checkhealth chroma` checks presence and says so in as many words, pointing at
`chroma doctor` for the version half. Two implementations of "how to interrogate
this binary" would be a second registry to keep in step, and one of them would
drift.

**`contract` is a version, and it is checked in both directions.** A CLI refuses
a configuration whose `contract` is higher than it understands and says to update
itself; a configuration refuses to be driven by a CLI that is older than its
components. Without this, the shared release lifecycle is an assumption rather
than a check — and the failure it prevents is silent, which is the kind this
project has been bitten by before.

---

## The components, and why they divide where they do

Nine, each requiring nothing but `core`. The boundary is what a person would
tick, not which Lua file the code currently sits in — those two disagree today,
and it is the code that has to move.

```
core             the editor: pickers, treesitter, yaml/json/shell/lua
terraform        Terraform or OpenTofu, terraformls, tflint
kubernetes       kubectl and the cluster views
helm             charts: helm, helm_ls, filetype detection
ansible          playbooks and roles
vault            editing vault-encrypted files
aws              profile and region for the session
docker           Dockerfiles and compose
github-actions   workflow linting and its schema
```

Two of those divisions were argued rather than assumed.

**Helm does not require kubernetes.** `helm template` and `helm lint` work
against a chart on disk, with no cluster and no kubectl. Someone developing a
chart needs the filetype detection and the language server; they do not need the
cluster views. Making it a dependency would install kubectl for a job that never
touches a cluster.

**Vault does not require ansible.** `chroma-vault` is about files that happen to
be encrypted with Ansible Vault; it does not use nvim-ansible or ansiblels, and
someone who only edits encrypted variables has no reason to carry playbook
tooling. That both binaries arrive from ansible-core is a packaging fact, and
packaging is the resolver's problem, not a reason to couple two features.

**Docker and GitHub Actions are separate from each other**, for the same reason:
neither implies the other. A TUI may group them on one screen; the manifests
must not.

Terragrunt stays a recommended tool of `terraform` rather than a component,
because it drives the same runner and the same formatter — there is no separate
feature to switch on.

---

## Two layers that are not the same question

The distinction that keeps the TUI honest:

**Neovim features** are ours. Enabling Terraform support means this
configuration loads that layer. We install it, we own it, and it either works or
it is a bug.

**External tools** are the machine's. `terraform`, `kubectl`, `helm`, `aws` may
already be there, at versions the user chose. The installer detects them,
reports them, and offers to install only what is missing — and only what it can
install safely.

```
Terraform support

  Neovim configuration
    [x] Enable

  External tools
    ✓ terraform      1.14.3
    ✓ terraform-ls   0.38.5
    ! tflint         not installed

  Install missing recommended tools?
    [x] tflint
```

A required tool that is absent is a warning, never a silent skip: the component
is enabled, and the thing it drives is not there. `doctor` says the same later.

---

## It is not a package manager

It knows `pacman`, `apt`, `dnf`, `zypper` and `brew` well enough to install
named packages and to read what is installed. It does not resolve versions, hold
its own package database, or install anything from a URL through a shell.

When it cannot install something safely it says so and prints the command:

```
terraform-docs is not installed.

Automatic installation is not supported for this package on Arch Linux.
Install it with:

  pacman -S terraform-docs
```

That is a better outcome than `curl | sh`, and it is the honest one: the CLI
does not know what that script does either.

---

## The plan is shown before it is run

Every mutating command produces a plan, prints it, and asks. `--dry-run` prints
and stops. `--non-interactive` requires the plan to contain no question that has
no answer.

```
Chroma Neovim v2.1.0 will be installed.

  Location      ~/.config/chroma-nvim        (NVIM_APPNAME=chroma-nvim)
  Existing      none
  Components    core, terraform, kubernetes, aws
  Tools         install tflint (pacman)
                terraform, kubectl, aws already present
  After         bootstrap plugins, then verify with a headless start

Proceed? [y/N]
```

Ordering matters and is fixed: **detect → resolve → plan → confirm → back up →
place → bootstrap → verify → record**. Recording the state happens last, after
verification, so a state file never describes an installation that did not
finish.

---

## What it installs into, and what it never touches

Default: `NVIM_APPNAME=chroma-nvim`, so `~/.config/chroma-nvim`, and the user's
existing `~/.config/nvim` is not involved at all. This is the same isolation the
README already documents by hand.

`--default` takes over `~/.config/nvim`. It refuses unless the target is absent
or a backup succeeded first. The backup path goes into the state file, and
`rollback` puts it back.

Nothing outside these is written:

```
~/.config/<appname>            the configuration
~/.local/share/<appname>       plugins, parsers, Mason
~/.local/state/<appname>       state, including install.json
```

`uninstall` removes exactly those and nothing else, and says what it removed.

---

## The selection

`$XDG_CONFIG_HOME/chroma/components.json` — the user's own configuration, not
the release tree. An update replaces `~/.config/chroma-nvim` wholesale; what
somebody chose has to survive that.

```json
{
  "schema": 1,
  "selected": ["terraform", "aws"]
}
```

**Intent, not a resolved graph.** `selected` is what was ticked and nothing
else. Everything that runs is worked out on read, so a component whose
dependencies change is never described by a stale copy of them.

**`core` is not in it.** It is enabled always and is not a choice, so naming it
is refused rather than ignored — a file that lists it was written against a
different idea of what this document means.

**`schema` is its own version.** It describes this file; `contract` describes
`components/*.json`. Two documents with two reasons to change, and tying their
numbers together would make one of them lie.

**No file is not an empty selection.** That distinction carries the whole
migration: a configuration from before any of this existed runs everything,
while `"selected": []` runs core alone. Someone who has used this for months and
never seen the CLI does not lose Terraform on the day gating arrives.

Everything about it is refused rather than guessed at: an unknown field, a
schema it does not know, a `selected` that is not an array, a member that is not
a string or is empty, a duplicate, `core`, and a component that does not exist.
That last one fails closed because a typo and "a newer CLI wrote this for an
older Chroma" look identical, and both mean the configuration about to run is
not the one that was chosen.

**A file that is refused is not the same as no file, and does not lead to the
same place.** Absent means legacy, which is everything. Present and unreadable
means safe mode, which is core alone, said loudly. The difference is that a file
exists: somebody chose, and the choice cannot be read. Running everything would
override that choice in the one direction that cannot be undone by the editor —
`"selected": []` is a deliberate core-only, and a corrupted byte would answer it
with Terraform, Vault, AWS and the rest. Core alone is still wrong, but it is
wrong towards an editor that starts, says what is broken, and switches nothing
on that nobody asked for.

So there are three modes, and callers get told which one they are in rather than
inferring it from a boolean:

```
no file        legacy     everything
valid file     selected   the selection, resolved
invalid file   safe       core alone, with an error
```

**It is not installation status.** `"selected": ["terraform"]` says somebody
wants Terraform support. Whether terraform is installed, and new enough, is
`doctor`, and mixing the two would make a wish look like a fact.

Both languages read it, from one corpus of fixtures under
`tests/fixtures/component-state`, so "Go accepts, Lua rejects" is a failing test
rather than a machine behaving differently from the editor on it. The writer is
atomic — temporary file, fsync, rename, fsync the directory — because an editor
decides what to load from this at startup, and half of it is a Chroma that comes
up wrong.

---

## Commands

```
chroma install     fetch a release and place it          --version --components
                                                         --profile --default
                                                         --dry-run --non-interactive
chroma update      to the next release, same components  --dry-run
chroma components  edit the enabled set (TUI)            --add --remove
chroma doctor      preflight, and what is missing now
chroma rollback    restore the backup this made
chroma uninstall   remove what this installed            --keep-state
chroma version     CLI version, installed version, contract
```

Profiles are named component sets shipped with the release — `minimal`,
`terraform`, `kubernetes`, `everything`. They are a shortcut for `--components`,
not a separate mechanism.

Exit codes are part of the interface, because this will end up in scripts:
`0` done, `1` failed, `2` misuse, `3` a plan was declined, `4` preflight
refused.

---

## Release lifecycle

One tag, one release, two kinds of artefact. The existing Lua jobs are
untouched; Go gets its own, and the release job runs only when both are green.

Implemented now:

- `cli-lint` — `gofmt -l` as a check rather than a rewrite, and `go vet`
- `cli-test` — `go test ./...`, which reads the shipped contract
- `cli-build` — cross-compiles for `linux/amd64`, `linux/arm64` and
  `darwin/arm64`

Planned, and deliberately absent until there is something to release: a pinned
`golangci-lint`, `darwin/amd64`, and attaching binaries plus a `SHA256SUMS` to a
GitHub release. A release job that publishes an installer which cannot install
anything would be worse than not having one.

`go.mod` carries `go 1.24`, which is a floor rather than a pin — the directive
states the minimum language and toolchain version, and a newer toolchain will
happily build it. That is weaker than the pinning this project applies to
Neovim, Ansible and selene, and it is a deliberate difference for now: the
module has no dependencies, so what a newer Go changes is its own behaviour
rather than a resolved graph. When the module grows dependencies, this becomes a
`toolchain` line and a `go.sum`, and CI stops being allowed to pick.

A cross-cutting check belongs here, and exists: **the components in
`components/` must resolve** — no unknown `requires`, no cycles, no tool listed with neither `id`
nor `any`. That is a Go test, and it protects the Lua side as much as the CLI.

---

## V1 boundaries, stated so they are not mistaken for oversights

- **Linux first.** macOS is in the build matrix because it costs nothing to
  produce, but the package-manager layer targets `pacman`, `apt`, `dnf` and
  `zypper`; `brew` is best-effort and says so.
- **No self-update.** The CLI updates the configuration, not itself. Downloading
  and replacing a running binary is a separate problem with its own failure
  modes.
- **No Windows.** The configuration targets a terminal-first Unix workflow and
  the runtime-directory guarantees this project makes are POSIX ones.
- **No plugin management.** lazy.nvim owns that, with a lockfile that is already
  reproducible. The CLI bootstraps it and reads its result; it does not compete.
- **No configuration wizard.** The TUI asks what installation genuinely needs —
  location, components, missing tools — and leaves the rest to the
  configuration, where it is documented and can be changed later.

---

## Implementation order

The audit series is closed. Two of them ran back to back over the component
layer and both are archived; the third would find something, because a third
always does, and it would not be the thing standing between this repository and
a product. **The installer is the active track.** Audits become a gate inside a
stage rather than a stage of their own: run one before a public release, and
after touching anything on the list below.

**What blocks a milestone.** Only a finding that can:

- overwrite somebody else's configuration,
- lose a backup,
- install a version other than the one the plan showed,
- record an install state that is not true,
- skip bootstrap or verify,
- run an external command in an uncontrolled way,
- let two mutating operations touch one installation at once.

Everything else is a backlog entry, and the work continues.

**The order.** Each stage is only allowed to depend on the ones above it.

```
 1  split the command layer                 no behaviour change
 2  install.Options and Paths               one source of truth for where things go
 3  LocalSource                             a tree to install, from development
 4  selection as part of the transaction
 5  staging, backup, placement
 6  bootstrap                               the placed tree installs its own plugins
 7  verify                                  the result is a Chroma that starts
 8  install.json                            written only after verify
 9  real `chroma install`                   the end of --dry-run only
10  GitHub release source
11  detect and package managers
12  TUI
13  release workflow
    ----------------------------------------- installer V1 ends here
14  update
15  components
16  rollback
17  uninstall
18  completions, packaging, signing
```

`record` stays last, always. `install.json` must never describe an installation
that has not been verified.

### Open decisions

These are not backlog. Each one changes an interface between the CLI and a
release, and each is cheapest to settle before the stage that first depends on
it. They are written down here so they are settled once rather than discovered
during implementation.

**1. The contract version is checked for equality, and `--version` accepts any
tag.** `component.Load` refuses anything that is not exactly `Contract`, which
means a CLI at contract 4 cannot read a release built at contract 3 — so
`chroma install --version <older tag>` cannot work as the command contract
promises. Either the reader accepts a range, or `--version` is documented as
bounded by the contract this CLI understands and says so when it refuses.
*Needed by stage 10.*

**2. `lua/chroma/bootstrap.lua` is a second contract between the CLI and a
release.** The installer calls `require("chroma.bootstrap").install()` in the
tree it just placed, so every release the CLI may install has to carry that
module — and releases from before it exists do not. Its presence belongs in the
source validation, before placement, rather than being discovered halfway
through a transaction. *Needed by stage 6.*

**3. The selection is global; the installation is not.** `components.json` lives
at `$XDG_CONFIG_HOME/chroma/components.json`, one file, while `--default` and
the isolated install are two different targets. V1 does not support two parallel
installations, which is a fine limit — but the second install currently
overwrites the first one's selection without saying so, and `uninstall
--purge-selection` would remove a selection another installation is still
reading. *Needed by stage 4.*

**4. Profiles have nowhere to live.** `--profile minimal|terraform|...` is in the
command contract, and neither the component contract nor `components/*.json`
knows what a profile is. The contract is frozen, so this is CLI knowledge — the
same shape as `toolver` and the package-name registry. *Needed by stage 4.*

**5. The minimum Neovim version is not in the contract.** It is stated in three
places that cannot check each other: prose in README, `has("nvim-0.12")` in
`lua/chroma/health.lua`, and `NEOVIM_VERSION` in CI. Preflight needs it before
it can bootstrap anything, and hardcoding it in Go makes a fourth copy — which
is the duplication `components/` exists to prevent. *Needed by stage 11.*

**6. Rollback does not bootstrap, and update does.** `lazy-lock.json` ships
inside the configuration tree, so restoring a generation of configuration leaves
the previous lockfile beside plugins installed for the newer one. A headless
verify would pass on that, and the user would be told the rollback succeeded.
Either rollback ends with a bootstrap, as update does, or the data directory
becomes part of what a generation means. *Needed by stage 16.*

**7. `latest` and rate limits.** Resolving `latest` and fetching `SHA256SUMS`
are calls to an API that limits unauthenticated clients by address. A user
behind shared egress can meet that limit in the middle of an installation, so
the failure needs a message that says what happened and what to do, rather than
a bare 403. *Needed by stage 10.*

---

## What would change this design

A second consumer of the component contract — a web page, a different editor,
an Ansible role — would justify moving `components/` to its own artefact with a
published schema. Until then it is two readers in one repository, which is the
cheapest arrangement that cannot drift.
