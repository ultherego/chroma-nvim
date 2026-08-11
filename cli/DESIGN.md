# `chroma` — installer and CLI, V1 architecture

The architecture, and it is built: `install`, `update`, `components`,
`rollback`, `uninstall`, `doctor`, `version`, and `package` for making a
release. Rule #1 applies here as it does everywhere else: read the current
documentation of every Go library before using it.

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
    detect/              what is on this machine: tools and versions. It reports.
    install/             fetch a release, place it, back it up, bootstrap Neovim
    state/               the installed-state file
    health/             preflight, and `doctor`
    tui/                 the interactive layer, and nothing else
```

`tui/` holds no decisions. Everything it displays comes from the contract, and
everything it produces is an `install.Options` — the same value the flags build.
That is what makes `--non-interactive` one implementation rather than two: after
the last question both paths run the identical code, and a question a flag has
already answered is not asked.

**It is line-oriented, and that is a decision rather than a stage.** It reads an
`io.Reader` and writes an `io.Writer`, so every screen is tested without a
terminal, over a pipe, in CI. There is no raw mode, no cursor addressing and no
redraw — the Go standard library has none of those, so a full-screen interface
means a third-party library and its transitive tree. This module still has zero
dependencies, and acquiring the first one is a maintainer's decision, not
something to arrive at by accident inside a milestone.

One consequence worth stating: **an exhausted input is a refusal, not a
default.** A pipe that has run out has not agreed to a location or to a set of
components, so it produces an error naming `--non-interactive` rather than an
installation built from answers nobody gave.

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
  "contract": 5,
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

**A version constraint expresses a compatibility boundary, and nothing else.**

```
min   the earliest version known to work
max   the latest version known to work, and only when a real
      incompatibility has been found — not a guess about the future
```

Neither says which version Chroma would prefer, because Chroma has no
preference about a tool that is not its own. A floor belongs here only when
something states one: `git >= 2.19` because lazy.nvim needs partial clones,
`tree-sitter >= 0.26.1` and `fzf >= 0.36` because nvim-treesitter and fzf-lua
say so. "It is what the machine we developed on had" is not a reason.

**There is no `exact`, and that is what took the contract from 4 to 5.**
Contract 4 had one, and it was the single way this schema could say "this
machine must run kubectl 1.35.2" — Chroma deciding the version of a tool that
belongs to the user, which is exactly what the external-tools policy says it
does not do. Leaving the field in place and forbidding it in prose would have
been worse than either: the next person reads the struct, sees both readers
support it, and quite reasonably uses it. **A schema should not be able to
express what the product will not do.**

Removing it is a breaking change to a document both languages read, so it is a
contract bump rather than a quiet edit. A contract-5 reader refuses `exact` as
an unknown field; had the number stayed at 4, the same document would have been
valid to one reader and invalid to another, which is the drift the number exists
to prevent.

Deliberately still not a constraint language: `>=1.2,<2.0 || >=3.0` is a
grammar, a parser and a class of bug, and nothing here has needed one. Versions
as data rather than as prose is what took the contract from 1 to 2; the readers
of contract 1 correctly refuse a `version` field they have never heard of, which
is the version check doing its job.

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

It knows no package manager at all, and this is the strong version of that
claim: there is no table of package names, no install command, no `sudo`, and
nothing that could grow into one. Chroma installs Chroma.

Choosing the kubernetes component asks for Chroma's Kubernetes features — the
plugin, the language server, the schemas, the parser. It does not ask for
`kubectl`, and an absent `kubectl` neither blocks the installation nor makes it
incomplete. What the installation does is say so, once, at the end:

```
External tools

  These belong to your system. Chroma does not install, upgrade or
  replace them. A feature that needs one says so when you use it.

  kubernetes
    not found  kubectl                views and log tailing
```

`not found`, never `ERROR` — an installation on a machine with no kubectl is a
complete installation. `chroma doctor` prints the same report later, from the
same renderer, so the two cannot drift.

The moment that actually matters is later still, in the editor: a feature that
shells out to `kubectl` checks for it and says what is absent, which is both
accurate and useful, because that is when somebody wants it. An earlier version
of this design had a per-distribution package table and a `sudo pacman -S`
behind a confirmation. It was deleted rather than left unused: the useful half
was always the sentence "kubectl is not here", and that needs no package
manager to say.

---

## The plan is shown before it is run

Every mutating command produces a plan, prints it, and asks. `--dry-run` prints
and stops. `--non-interactive` requires the plan to contain no question that has
no answer.

```
Chroma Neovim v2.1.0 will be installed.

  Source        v2.1.0
  Location      ~/.config/chroma-nvim
  Run with      NVIM_APPNAME=chroma-nvim nvim
  Selection     ~/.config/chroma/components.json

  Components    core, kubernetes, terraform
  Present       git, curl, tar, unzip, gzip, cc, tree-sitter, fzf
  Missing       nothing
  External      terraform/tofu not on PATH; Chroma does not install these,
                and installing without them changes nothing here

Proceed? [y/N]
```

`Present` and `Missing` are Chroma's own tooling, and `Missing` is the line the
exit code follows. `External` is named and not counted — see "It is not a
package manager" above.

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
chroma doctor      is the installation on this machine healthy
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

## The release artefact

A release is two files, and the installer will accept nothing else.

```
chroma-nvim-v1.0.0.tar.gz
SHA256SUMS
```

**Every entry lives under `chroma-nvim-<version>/`.** A tarball that unpacks
into the working directory is rude to anybody who opens it by hand, and a
required prefix gives the extractor one more thing it can check: an archive
whose entries are not all under the name it claims to be is not the archive that
was built.

**What is in it is `install.RuntimeEntries`, and that list exists once.** The
packager writes those entries and the installer copies exactly the same ones
when it stages a checkout, so an installation from a release and one from a tree
are the same files. Two lists would be two products with one version number.

Out of it, therefore: `cli/` — the installer is not the configuration —
`tests/`, `.github/`, the governance documents, the linter configuration, and
`.git`, which is out for a reason of its own: an installed configuration that is
a checkout invites `git pull` on top of a managed installation, which arrives at
a version no install state describes.

**The archive is reproducible.** Entries are sorted, ownership is nobody, and
modification times are fixed, so packaging one tree twice produces one checksum.
A digest that moved between builds would be a record of when the archive was
made rather than of what is in it.

**`SHA256SUMS` is what `sha256sum` writes**: a hex digest, two spaces, a name.
A line that cannot be parsed is refused rather than skipped, in a file whose
whole job is to be unambiguous.

**Built by `chroma package`,** which is developer-only and lives in the same
binary as everything else on purpose: the release workflow has to build the
archive with the code that was tested, not with a shell pipeline that agrees
with it today.

**One `SHA256SUMS` covers every asset**, not only the archive — the
cross-compiled binaries are hashed by the packager too, through `--asset`. The
workflow builds them and hands them over; it does not compute a digest. Assets
are listed by basename, because a release asset is flat, and two files sharing
one basename are refused rather than published as one.

---

## Releasing

**A tag, not a branch.** `.github/workflows/release.yml` triggers on `v*` and
builds everything from the commit the tag points at. Nothing in it fetches a
branch, pulls, or resolves a ref of its own:

```
tag  →  commit X  →  binaries built from X
                     archive built from X
                     SHA256SUMS describing both
                     release pointing at X
```

**Publication is the last job, and the only one that can write.** `contents:
write` is scoped to it; everything that could fail has already run by the time
it starts. The release is created in a single `gh release create` call carrying
every asset, so a release either exists complete or does not exist — uploading
one at a time would leave a published release missing a binary.

**The gates are the ones `main` gets, called rather than copied.** The workflow
`uses: ./.github/workflows/ci.yml`, which is why that file has a
`workflow_call` trigger. A second definition of "good enough to ship" is a
second thing to keep current, and one of them falls behind.

Between packaging and publication the build checks its own output with tools
that did not produce it: `sha256sum -c SHA256SUMS`, `tar -tzf` for entries
outside the prefix the archive claims to be, and `chroma version` against the
tag it was built for. The version reaches the binary through
`-ldflags -X main.version`, so a tag is the only place a release number is
written down and no commit carries one.

**A hyphen makes it a pre-release.** Semver says so, and it is the distinction
that matters here: `v0.0.0-release-dev.1` must not become what
`--version latest` resolves to, so it is published with `--prerelease
--latest=false`.

---

## Updating

**An update is the installation transaction, not a second one.** `install` and
`update` differ in three decisions, all taken before the transaction starts —
where the selection comes from, whether the backup is optional, and whether a
previous generation is recorded — and then run the same code. An update that
placed a tree its own way would be a second installer, and the half nobody
exercises daily is the half that breaks.

**It does not ask about components.** What somebody chose has a longer life than
any release, and re-asking on every update is how a person ends up with a
different editor because they pressed return too quickly. The selection document
is read and carried over. It is validated against the contract of the release
being installed, so a component the new release no longer has is a refusal
before anything moves rather than a silent drop.

**An installation is a generation.**

```
current   v0.2.0   ~/.config/chroma-nvim
previous  v0.1.0   ~/.config/chroma-nvim.chroma-backup-<stamp>
```

`install.json` records the previous generation — its version, its contract, its
source, and where its directory went. That is schema 2, and the reason for the
bump: schema 1 could say what had been moved aside but not what it was, which is
enough to restore a directory and not enough to name a version. Rollback reads
it; nothing else writes it.

The generation is recorded only after the backup step has actually moved
something. A path the transaction never produced would promise a way back to
somewhere nothing is.

**Already on that release is not a transaction.** The target tag is resolved
before anything is downloaded, and an installation already on it says so and
stops. Doing the whole thing to arrive at the same tree is a risk taken for no
change.

**A failure puts the working generation back.** Every step after the backup
rolls back through the same transaction an install uses, so a refused bootstrap
or a failed verify leaves the editor that was working exactly where it was —
and `install.json` still describes it, because the record is written last.

---

## Changing components

**A selection is not a generation.** This is the boundary the whole lifecycle
rests on, and it is worth stating before `rollback` needs it:

```
generation = which release of Chroma is installed
selection  = which parts of it the user wants
```

So `chroma components` writes no `install.json`, moves no directory and makes
no backup. The version, the source and the previous generation are exactly what
they were. A rollback later moves the version without moving the selection —
and conversely, adding a component does not invent a version to go back to.

**`--set` is the primitive, and it names a target state.** `--set
terraform,kubernetes` means "afterwards, have exactly these", not "add these".
`--set ''` means core alone, said out loud, the same as it means to `install`.
Mutations like `--enable` can be built on that later; a target state cannot be
built on a series of mutations without knowing what came before.

The interactive form is the same primitive with the current selection already
ticked, through the same selector `install` uses. Two selectors would be two
ideas of what a component list looks like, and the one nobody looks at is the
one that goes wrong.

**It is still a transaction.** The new selection is written, the editor is
brought to it, the result is verified, and only then is the change kept. A
bootstrap or verify that fails restores the selection that was in force — which
is what decides whether a mistyped component costs somebody their editor.

**Nothing is deleted.** A component switched off stops being activated; the
Mason packages, parsers and plugin directories it used may stay on disk, and
that is correct rather than untidy. The configuration is what decides what runs.
A garbage collector would be a subsystem earning its keep only if somebody ever
runs out of disk, and it can be `chroma clean` on the day that happens.

One consequence, recorded because it changed a precondition: `Bootstrap` and
`Verify` used to require that *this* transaction had placed the tree. They now
require that a tree is there. The flag was a fair proxy while installing was the
only thing that ran the editor, and stopped being one here.

---

## Rolling back

**One target and no `--version`.** Rollback goes to the generation the last
update moved aside, and nowhere else. It is a local operation on a directory
that was kept — if that directory is gone it refuses, because fetching the tag
again would be `install --version` wearing the wrong name.

**It swaps.** What was current becomes the generation to come back to, so a
second rollback returns:

```
v1 ⇄ v2
```

One slot, two directions. Not a history: nobody asked for a stack, and a stack
would need a policy for how deep it goes and when it is pruned.

**It moves the version and keeps the selection.** A component chosen after the
update is still chosen after the rollback. The two are different facts with
different lifetimes, and undoing one when the user asked to undo the other is
the kind of surprise a lifecycle command cannot afford.

**Which is why the selection is checked first.** If the generation being
restored has no component the current selection names, the command refuses —
before a rename, a backup, a bootstrap or a write:

```
Cannot roll back to v1.0.0.

The current component selection is not supported by that generation:

  aws

Change the component selection first, with `chroma components`.
```

**Undoing a rollback moves; it does not delete.** The transaction tracks
`Restored` apart from `Placed`, and the difference is destructive: a placed tree
is one the transaction assembled, so undoing it means removing it, while a
restored generation already existed and was only moved. Deleting it would
destroy the very thing a rollback exists to preserve. A failure at bootstrap or
verify puts both directories back and leaves `install.json` describing the
generation that is actually there — it is written last, as everywhere else.

---

## Uninstalling

**One rule, and everything follows from it:**

> What Chroma made for its own operation, uninstall may remove. What Chroma only
> moved aside, because it belonged to somebody already, uninstall gives back.

So this goes: the configuration, every kept generation, the plugin and Mason
data, the cache, the state, the selection document, and `install.json` last of
all. And this does not: a configuration that was in Neovim's own directory
before `--default` took it over. That one is restored.

**A user backup and a Chroma generation are not the same thing**, and schema 3
exists to keep them apart. `backup` meant "what was moved aside", which was two
different things wearing one name — and after a single update the second
overwrote the first, so the path to somebody's own configuration was no longer
recorded anywhere. `user_backup` is written by the first installation that takes
a directory over, and carried forward unchanged by every operation after it. The
record refuses to name one path as both.

**The selection goes too.** It describes how somebody configured Chroma, and
after an uninstall there is nothing for that preference to be about. Keeping it
"in case" would mean an installation six months later silently inheriting a
choice made before, when a new installation should be a new decision.

**One operation, no levels.** `--purge` beside a plain `uninstall` asks somebody
to guess which of two destructive things they meant. The honest alternative is
cheaper: print the exact list of paths and let them read it before agreeing.

**Nothing is deleted until the restore has succeeded.** The configuration is
moved aside and held; only once the pre-Chroma configuration is back does the
first delete happen. Deleting first would mean a failed restore leaves the
directory empty — no Chroma and no configuration either, which is worse than
either outcome alone.

One bug this uncovered, in a transaction that had shipped four milestones ago:
`BackupTarget` moved a directory aside without recording where it came from, and
`Rollback` put backups back at `Target` — which only `Place` ever set. Installing
never noticed, because `Place` always followed. Uninstalling did, because the
step after it is a restore that can fail.

---

## One operation at a time

**Every command that moves a directory or rewrites the record takes an exclusive
lock on the installation.** `install`, `update`, `components`, `rollback` and
`uninstall`. `doctor` does not: it reads.

Two of them at once is not a race that ends in a slow answer — it is one process
renaming a tree that the other is about to write a state file about, and no
amount of care inside either transaction helps when the ground moves underneath.

**`flock`, not a file holding a pid.** The difference is the case that matters
most: a process that dies without running any cleanup. The kernel drops an
`flock` when the descriptor closes, which happens on exit however the exit
happened, `SIGKILL` included. A pid file would still be there, and the next run
would have to decide whether the pid it names is the same program or a number
the system has since reused — a guess, made at the moment somebody is already
having a bad day.

**Refused, not queued.** A CLI that blocks is indistinguishable from a CLI that
has hung. `Another Chroma operation is already in progress` is the useful
answer, and it names the log directory.

The lock file lives at `<state>/lock` and is not removed on release. Unlinking
it would open the window where one process has opened it, another unlinks it, a
third creates a new one, and two of them hold locks on two different inodes with
the same name — which is how a lock file stops being a lock.

---

## Where each operation commits

Every mutating command has a line before which it can be undone and after which
it cannot. Naming it is not documentation: `uninstall` had one, nobody had said
where, and a stop just past it made the next run delete the user's own
configuration.

**install, update, components, rollback** commit when `install.json` is written,
which is why that write is last. Everything before it — staging, the backup, the
placement, the bootstrap, the verify — is undone by the transaction, and the
record still describes the installation that is actually there.

**uninstall commits when the user's configuration has been given back.** Before
that line the operation is reversible: nothing is deleted and the pre-Chroma
configuration is still where Chroma put it, so a failure restores Chroma and
asks to be run again. After it, ownership has changed hands, and moving that
directory a second time to reinstate an installation somebody has just asked to
remove would be Chroma taking back what it has already given.

So the handover is written down, as `handed_back` in schema 4. Clearing
`user_backup` was not enough: the record then said nothing was pending, and the
next run treated the directory as Chroma's, moved it aside and deleted it —
measured, on a fault point, on somebody's own files. A record has to say not
just "there is nothing to give back" but "it has already been given".

Everything after the commit point is deletion of Chroma's own paths, and every
one of those is safe to attempt again. The record goes last precisely so that a
second run still knows what is left to finish.

### After a process stops existing

`SIGINT` and `SIGTERM` leave a program able to answer, so the guarantees are the
ones above: defers run, the transaction rolls back. `SIGKILL` does not. Nothing
runs, and the only thing the kernel does on the way out is drop the flock.

The question is therefore not whether an operation undoes itself, because it
cannot. It is whether the next run can tell what happened and get out of it
without destroying anything. Two answers are acceptable — Chroma proves what the
state is and repairs it, or it cannot and refuses, touching nothing and saying
what it found. **Believing the record over the filesystem when the two disagree
is not one of them.**

One window needed the second kind of answer. A kill between restoring the user's
configuration and writing `handed_back` leaves a record offering to restore
something that is already back. `ReconcileHandover` reads that as a completed
handover only when all three of these hold:

```
the recorded backup is gone
the configuration directory is there
it does not hold a Chroma tree      (no lua/chroma/bootstrap.lua)
```

The only ordinary way all three are true at once is that the rename ran. If
Chroma is still in the directory, the backup was deleted by somebody else —
a different situation, and the uninstall refuses instead, naming what is
missing. The reconciliation happens before the plan is built, because the plan
is printed, and a plan offering to remove somebody's own configuration is the
lie this whole area exists to prevent.

### Recovering an interrupted transaction

Two of the three kills leave the record describing something other than what is
at the target, and no journal is needed to notice — but the rule is narrower than
it first looked.

**An unreferenced `*.chroma-backup-*` is evidence of an interrupted transaction
only where its presence closes a gap in the committed state.** A missing target,
or a recorded `previous.path` that is not there: the orphan explains what is
absent, and there is exactly one arrangement it could have come from.

On its own it explains nothing. H4 measured what happens when a directory is
given a role because its name and position fit: a stray backup beside a complete
installation was treated as the committed generation, moved over the working one,
and the working one deleted. A familiar name is not proof of ownership.

The honest cost is that an update killed between placing the new tree and writing
the record is no longer repaired automatically. From the filesystem alone that
arrangement — a target present, every recorded path in place, one unreferenced
backup — is identical to a complete installation with something copied beside it,
and a rule that told them apart would be inventing a fact. It is reported and
refused instead, naming the directory and saying Chroma will not guess.

**The committed record wins, and the direction is rollback rather than
roll-forward.** Until a new `install.json` has been written atomically, the
generation change does not exist as a state of the product: the tree at the
target may not have been bootstrapped, may not have been verified, and was never
announced to anybody. It is a re-fetchable artefact, not somebody's work.

Nobody is asked to choose between the two trees. Whether the half-placed one got
as far as `verify` is not something a person outside the process can know, and
offering it as an option would be a way of promoting an uncommitted transaction.
Either the committed arrangement can be shown and is restored, or it cannot and
nothing is touched.

```
update killed after the backup     orphan → target
update killed after the place      target → aside, orphan → target, aside removed
rollback killed after the swap     target → previous.path, orphan → target
```

**Renames first, deletion last, and the uncommitted tree is moved rather than
removed.** That ordering costs one rename and buys the difference between "the
machine still has a configuration, and it is not the recorded one" and "the
machine has none at all": if the committed generation cannot be moved back, what
was at the target is put back where it was.

**Ambiguity is refused.** Two unreferenced backups, an orphan that is not a
Chroma tree, a recorded previous that is missing with nothing to explain it —
each returns an error and moves nothing. The alternative is a recovery that
shuffles directories on a hunch.

**Giving the user's configuration back is a protocol, not an inference.**

```
held         Chroma is holding it at user_backup
pending      an uninstall has begun giving it back
handed_back  ownership has returned
```

`pending` is written **before the first move**, so nothing about somebody's data
begins until the intention to do it is on disk — and a write that fails leaves
the filesystem untouched.

That ordering exists because the earlier version could be forged. It concluded a
handover from the shape of the directory: the backup gone, the target there, the
target not looking like a Chroma tree. With Chroma still installed, deleting the
backup and one file out of the tree was enough to produce all three. "This no
longer looks like a complete Chroma tree" is not "this is exactly what we were
holding for you", and treating the first as the second ends with Chroma calling
its own directory somebody else's.

Now the topology is only read when the record says a transfer had begun, and
only these mean the rename ran: the backup gone, the target present, and the
target not a Chroma tree. Anything else with `pending` set is a contradiction —
both gone, or the target still holding Chroma — and produces a refusal rather
than a story.

A state rather than two flags, for the reason contract 5 gave: `pending` and
`handed_back` as booleans leave a combination that means nothing, and a schema
should not be able to express what the product will not do.

**A persisted path proves where Chroma once put something. It does not prove
what is there now.**

Between a record being written and a command acting on it, anything may have
replaced the directory. Measured: with the kept generation replaced by a link,
a rollback moved the link into place and rewrote the record; with the held
configuration replaced by a link, an uninstall handed the link back as
somebody's own work, recorded that, and deleted its own state. Neither touched
what was on the other end, but both crossed an ownership boundary on the
strength of a string from an old record.

So the type is checked again with `Lstat` before any move that crosses such a
boundary, and a link is refused whatever is on the other end of it: following it
means acting on an object Chroma never put there, and moving it means recording
a link as a generation. For an uninstall the check comes **before `pending` is
written** — once Chroma cannot show what is at the recorded path, it has no
business starting a transfer of ownership at all.

The record also refuses to name one directory as two things. `user_backup` and
`previous.path`, either of them and the installation itself: each alias would
send a destructive step at the wrong object.

**What this does not defend against.** Somebody who owns the account can edit
`install.json` and write any state they like. Resisting that would need
authenticated state with a secret outside their control, which is a different
threat model from the one here: corruption, stale topology, substituted paths
and contradictory-but-legal-looking records.

**Uninstall is the exception, and deliberately.** There the stronger fact is
ownership, not the record: once the user's configuration has been given back it
stays given, even if `handed_back` never reached the disk. Generation operations
roll the filesystem back to the record; a proven hand-back rolls the record
forward to the filesystem.

### Failures from the release source

Everything a release brings is untrusted until it has been verified, and the
whole of that verification happens before the transaction starts: resolve, read
the checksums, download, hash, compare, unpack into a temporary directory, and
read the contract that was unpacked. Only then does an installer receive a
`PreparedSource`. A failure anywhere in that sequence cannot touch a committed
state, because none has been opened.

The cases are produced on purpose, against a controlled HTTP server rather than
a public one: a body cut in half, a 500, an asset the release does not publish,
an archive that does not match its digest, checksums that do not list the
archive, checksums that are malformed, and a broken archive whose digest is
honest — that last one deliberately, so the failure comes from the extractor
rather than from the checksum a second time. The client, the download, the
parsing, the hashing and the extractor are all real; only the host is a stand-in,
because no public host can be asked to truncate a body on cue.

**`SHA256SUMS` may not list an asset twice.** Found here: with two contradictory
digests for the archive, the honest one first was refused and the honest one last
was accepted, because the map took the last entry. A file that says a thing twice
does not describe one release, and its meaning must not depend on the order the
lines happen to be in.

The extractor's own rules — no absolute paths, nothing climbing out of the
prefix, files and directories only, everything under the prefix the archive
claims — are tested directly elsewhere. They are also exercised through the
release path, on an archive somebody could actually publish, because a guard that
is correct and unreachable protects nothing.

### Fault points

The boundaries above are tested by stopping between two steps that both
succeeded — `internal/install/fault.go`. A real operating system cannot be
aimed: permissions, ENOSPC, EXDEV and symlinks all gave genuine answers when the
campaign put them in the way, but none of them can be made to happen *after* a
rename worked and *before* the next write started.

A fault point is not a simulated error in a step. `after-verify` means verify
really ran and really succeeded, and then the process stopped; simulating a
failing verify tests what the runner-based tests already cover. Deliberately not
a filesystem interface: "fail on the third rename" quietly changes meaning the
moment a refactor splits one rename into two, while "after the generation was
restored" does not. The hook is nil in production and there is no flag,
environment variable or build tag to arm it.

---

## What Chroma borrows, and how it proves it

Taking over `~/.config/nvim` is not taking over one directory. Neovim without
`NVIM_APPNAME` also reads `~/.local/share/nvim`, `~/.local/state/nvim` and
`~/.cache/nvim`, and a bootstrap writes plugins, packages and parsers into all
three. Until this was measured, `--default` moved the first aside and the
uninstall removed the other three as Chroma's own:

```
.config/nvim         survived
.local/share/nvim    GONE   ← years of plugins
.local/state/nvim    GONE   ← undo history and shada
.cache/nvim          GONE
```

The rule the whole design rests on has not changed — **what Chroma made for its
own operation it may remove; what Chroma only moved aside, because it belonged
to somebody already, it gives back** — but there are up to four of the second
kind, and each is tracked on its own.

### Identity, not shape and not path

Two answers to "is this the directory I left here?" were measured and both were
wrong.

The path was the first. An uninstall handed back whatever stood at the recorded
backup, so an ordinary nvim-shaped directory put there afterwards was returned to
somebody as their own configuration; and a rollback restored an ordinary
directory left at a kept generation's path as that generation.

The shape was the second. `Lstat` proves a thing is a directory and not a link,
which is worth having and is not identity. Anybody can make a directory with an
`init.lua` in it.

What is recorded instead is the **device, inode and modification time the
directory had at the moment it was taken**. `rename` preserves all three, which
is exactly the property needed: every move Chroma makes carries the identity
along.

Device and inode alone were tried first, and measured to be insufficient. They
answer the copy — a `cp -a` has a different inode however carefully the contents
are reproduced — but not the substitution, because a filesystem may hand a newly
created directory the inode of one just deleted at the same path:

```
btrfs, tmpfs, overlayfs    0/40 rounds reused the inode
ext4 (the CI runner)      40/40 rounds reused the inode
```

The substitution tests passed on a development machine and failed on CI for
precisely that reason, and that is the only reason it was found before release.
A directory's own modification time changes only when its own entries change, so
it survives every move Chroma makes, and a directory created where one was
deleted carries the time it was created.

The consequence is stated rather than discovered: if something adds or removes a
top-level entry inside a directory Chroma is holding, Chroma refuses to move it
and says so. That is the right way round — refusing to hand back a changed
directory costs a manual move, and accepting a substituted one costs somebody
their work.

It is deliberately not a marker file inside the directory. A marker is content:
`cp -a` copies it, so it answers nothing the inode does not already answer, and
writing one would mean putting a file into a directory Chroma has promised to
return untouched — the same mistake the install log made.

Every move across an ownership boundary is preceded by a proof, and a proof that
fails is not repairable: if what is at the path is not what Chroma recorded, then
Chroma does not know where the real one went, and the two available actions —
hand this back as somebody's work, or delete it as Chroma's — are both
destructive and both wrong.

This is not, and does not claim to be, a defence against the owner of the
account editing `install.json`. That boundary is stated in "Where each operation
commits" and has not moved.

### One handover state per directory

`install.json` schema 6 replaces the single `user_backup` + `handover` pair with
a list. Each entry says what kind it is, where it belongs, where it is being
held, the identity it had, and how far giving it back has got — `held`,
`pending`, `handed_back`. Per directory, because a process can stop after
returning two of three, and one flag for four directories cannot say which.

They are returned in a fixed order: configuration, data, cache, **state last**.
`install.json` lives under the state directory, so once that has gone home there
is no record left to write the next step into.

The configuration is still the commit point. Up to the moment somebody's own
`init.lua` is back at `~/.config/nvim` the operation is reversible and a failure
reinstates Chroma; past it, ownership has changed hands, and a failure to hand
back the data directory is reported and resumed rather than undone. Undoing it
would mean taking back something already given.

### Reconciliation asks which, not what

The rule that the filesystem wins over the record is unchanged, and the evidence
it rests on is now the identity. With `pending` recorded, the backup gone, and
the original path holding the very inode that was taken, the rename ran and
nothing else could have produced that. The earlier version asked whether the
directory still looked like a Chroma tree, which is a question somebody could
answer by deleting one file.

### Borrowing is decided by which installation this is

`CheckTarget` used to answer "nothing to back up" when `~/.config/nvim` was
absent. Somebody who had deleted their `init.lua` years ago but still had
everything in `~/.local/share/nvim` therefore had it bootstrapped into and then
removed. A default installation now always borrows; which directories are
actually there is the borrowing step's own question, and it skips the ones that
are not.

### A test seam belongs to the behaviour under test

The window between "the rename committed" and "the caller was told" cannot be
produced by permissions or a full disk, and it is the one where a transaction
either keeps a commit or rolls back past it. It used to be reachable through an
exported hook in `internal/atomicfile`, which put a way to make a primitive fail
into every binary that links it. The hook is now unexported and proves
atomicfile's own half of the boundary in atomicfile's own tests; the installer
holds its two durable writes in package variables and builds the same window
from those.

Doing that turned up a gap the old arrangement had hidden: the rule is written
down at two places, and only the update's was tested. A mutant that made
`rollback` undo a record it had already committed survived the whole suite.

## What the plain commands mean

Two defaults were wrong in the same way: they answered a question about the
machine with a fact about the shell.

`chroma install` — the command README documents and the one somebody types
first — refused, and said to name a release with `--version`. An installer whose
plain form does not install is not an installer. With neither `--version` nor
`--source-tree`, it installs the newest release. The default is filled in after
validation rather than as the flag's default, because validation refuses a
version and a source tree together and a flag default would make every
`--source-tree` run look like both were asked for.

`chroma doctor` defaulted `--tree` to `.`, so on a perfectly healthy managed
installation it answered:

```
$ cd /tmp && chroma doctor
no components directory in . — is that a Chroma Neovim tree?   (exit 2)
```

It now finds the installation the way every other managed command does, reads
that installation's own contract, and reports **the components its owner
actually chose**. Somebody who turned Kubernetes off is not running a machine
that is missing `kubectl`; they are running one that does not need it, and a
report saying otherwise describes an installation they do not have. An
installation with no selection document is core alone, which is what the
installer would have written.

`--tree` stays, as what it always really was: an explicit read-only override for
somebody working on a checkout. There it reports the whole contract, because a
checkout has no selection to narrow it by, and it says so in its first line.

The exit codes were already right and were confirmed by measurement rather than
assumed: a missing external tool is reported and exits 0, and a missing or
too-old tool of Chroma's own exits 4.

## One commit per release, decided once

A `workflow_dispatch` run takes its workflow definition and its default checkout
from the ref it was started on. Only the build job read the tag that was asked
for, so a release dispatched from `main` with an older tag ran every quality gate
against `main` and built the assets from the tag: the gate said "main is good"
and the archive came from somewhere else.

Measured before it was fixed, and it needed no release to demonstrate —
dispatched from `main` with a tag that does not exist at all:

```
success  quality / CLI test suite          ← all eight gates green
success  quality / Test suite
failure  Build and package                 ← only the checkout noticed
skipped  Publish
```

A gate that is green about a tag nobody created is a gate with no relationship to
what is being released.

A `resolve` job now decides the commit once, before anything else runs, and
everything downstream is given a SHA rather than a tag. `ci.yml` takes it as a
`workflow_call` input and every checkout in it uses it; the build checks out the
same SHA instead of resolving the tag a second time, because a tag is a pointer
its owner can move and two resolutions a CI run apart can differ. A tag that does
not exist is refused in the first job.

Both jobs print the commit they are about, so "the gate was green" can be checked
against "the gate was about this commit". The three cases, measured on the fixed
workflow:

```
tag push                          gate == build == the tag's commit,   published
dispatch, newer branch, old tag   gate == build == the tag's commit    (≠ caller)
dispatch, tag does not exist      resolve fails; quality, build and publish skipped
```

The middle one is what the dispatch trigger exists for, stated as something that
was run rather than as an intention: the workflow definition comes from the ref
the run was started on, so a tag can be re-run after a fixed workflow without
moving it, while the subject under test stays exactly the commit the tag names.
Dispatching the workflow on the old tag instead would bring back the old,
possibly broken, definition of the gate along with the old code.

## One installation, and what a dry run is allowed to touch

Two findings that turned out to share a shape: both were the CLI doing something
to the machine that the person running it had not asked for.

### One managed installation per user

A second installation was allowed, and produced a state this CLI could not get
out of. Measured: with an isolated installation recorded, `chroma install
--default` reported success, and afterwards every lifecycle command answered

```
Two Chroma installations are recorded and this cannot tell which you mean:
```

with no flag in the product to say which. Update, components, rollback and
uninstall all refused. A dead end the CLI created itself.

`install` now refuses before anything is downloaded, staged or moved, in both
directions, and the refusal names what is already there and what to do instead.

The alternative was to add a way of naming which installation each command is
about. That is a larger product for a configuration nobody asked for, and it
would still be wrong in one place a flag cannot reach: **the component selection
is one document per user**, shared by both, so two installations were never two
independent things in the first place.

### `--dry-run` means no change to this machine

Not "skip the main operation". Measured on an interrupted topology, which is the
only state where recovery has anything to do:

```
chroma update --dry-run
  gone:    nvim.chroma-backup-20260810T000000Z/     ← moved
  created: nvim.chroma-backup-20260809T000000Z/     ← new topology
  changed: chroma-nvim/
  created: run/chroma-nvim.lock
  "An interrupted rollback was found. v1.0.0 is being put back..."
```

A dry run took the lock, ran recovery, moved two directories and rewrote the
installation — then said it had written nothing.

The shape now, for `update`, `rollback` and `uninstall`:

```
load the record
describe the topology            ← read-only, always
if dry-run:  plan, render, exit  ← no lock, no recovery, no log
take the lock
repair
re-read the record               ← repair can move a generation
plan, render, confirm, operate
```

A dry run still says what a real run would have to put right first — detection is
a read, and only the repair is a write. The lock and the repair happen together
and before the plan, because a plan built against a topology an interrupted
transaction left behind describes a machine that is about to change.

`install` was already clean here: its lock moved after the plan and the
confirmation when the lock became global, so its dry run never reached one. That
is now held in place by a test rather than by luck.

## The record is the last thing to go

An uninstall that could not finish removed the record anyway, and the record is
the only description of what is left to finish. Measured in both shapes.

Isolated, with the data directory impossible to remove:

```
data directory left behind: true
state directory still there: false
record still there:          false        ← the map of what remains
```

A second run answered "No Chroma installation is recorded".

A takeover, with Chroma's cache impossible to move out of the way:

```
uninstall failed:   true
record still there: false
user's cache back:  false      ← still owed
user's state back:  true       ← handed back anyway
```

That is the worse of the two: somebody's cache directory left at a
`*.chroma-backup-*` path, and nothing anywhere recording that it is theirs.

**The state directory is the commit point of an uninstall, not an item on a
list.** `install.json` lives under it, so parting with it is the moment Chroma
stops being able to say what is unfinished. Both shapes now say the same thing:

```
phase 1   ownership handover up to the commit point (the configuration)
phase 2   everything else Chroma owns — hand-backs and removals, all retryable
          if any of it failed: the record stays, and this stops
phase 3   isolated:  remove the state directory        ← the commit
          takeover:  give the state directory back     ← the commit
```

Nothing reaches phase three while anything else is unfinished, and there is
deliberately nothing after it.

What this makes possible is the case that matters after schema 6: a run may stop
with the configuration and the data handed back, the cache still owed and the
state still held — and that is a correct state, as long as the record says
exactly that, a second run does not touch what has already gone home, and it
finishes the rest. It is a regression test, not a hope.

## Three small ones, and what they had in common

Two of them were a second definition of something the product already had.

**The plan asked whether a name was on PATH.** `doctor` reads what a tool says
its version is and holds it to the floor the contract states; the plan asked
`exec.LookPath` and called anything it found present. Measured with a stubbed
PATH: on a machine with git 2.18 and tree-sitter 0.25, the plan was complete and
`doctor` exited 4, at the same moment about the same executables. An
installation would have gone ahead against a machine that cannot run it.

`plan.Tool` is now `detect.Tool`, and `plan.Build` takes a detector rather than a
name lookup. It is called with the components the plan resolved and not the ones
that were asked for, because a component pulled in by `requires` needs its tools
described too. A recommended tool that is too old still does not stop anything —
`Complete()` is about required tools of Chroma's own, and that distinction is the
whole of it.

**`--tree` meant two things.** `doctor --tree /repo` read `/repo/components`;
`components --tree /repo` passed `/repo` to the loader as though it were the
contract directory, found no `*.json`, and listed nothing — with exit 0, which is
worse than refusing. One helper decides what the flag means now.

**A version out of a hand-written file could stop the CLI.** `strings.FieldsFunc`
returns nothing when the string is only separators, and the first element of that
was taken: `"-"`, `"+"`, `"v-"`, `"-rc1"` and friends panicked the parser in the
middle of reporting the problems in a contract. Two functions had the same hidden
precondition and neither could express it in its signature, so the split is one
function and the precondition is gone.

### And one that was worse than it looked

`ExecRunner` ignored `scanner.Err()`. The scanner stops on a line longer than its
buffer, which is indistinguishable from end-of-output unless asked — so a child
that printed one very long line and exited cleanly was reported as success, with
its output thrown away.

It is not a wrong answer, it is a hang. Stopping the scan is not the same as
being finished: the child goes on writing into a pipe nobody is emptying, fills
it, and blocks forever, so `Wait` never returns. Measured with a two-megabyte
line: the run continued until the test framework killed it at forty-five seconds.

The rest of the pipe is drained so the child can finish, the scan error is
carried out of the goroutine on a channel, and the three possible reasons are
ordered: a cancelled run reports the context, a failed child reports its own
failure and the tail of what it said, and an exit status of zero with unreadable
output is a failure too — because the installer decides whether an editor
bootstrapped correctly from what it reads there.

## Implementation order

Done, in this order. Kept because the reasoning for each step is in the commits
that carried it out, and because the order itself is the argument: nothing that
writes to a disk was built before the thing that could put it back.

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
11  complete Neovim provisioning            Mason installs everything it is asked to
12  TUI                                     line-oriented; it produces Options
13  release workflow                        a tag builds and publishes; last job writes
    ----------------------------------------- installer V1 ends here
14  update                                  generations: current and previous
15  components                              a selection is not a generation
16  rollback                                one slot, two directions
17  uninstall                               made vs borrowed
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
tag.** *Settled at stage 10:* bounded, and said out loud. A release is fetched,
verified and unpacked, and then its contract is read with the same reader the
editor uses — so a release built at another contract is refused by name, before
anything of the user's has been touched, with a message naming the release. The
reader was not loosened to a range: a contract number exists precisely so that
two sides which no longer agree stop rather than guess, and a CLI is a small
download beside the configuration it installs.

**2. `lua/chroma/bootstrap.lua` is a second contract between the CLI and a
release.** *Settled at stage 6:* the module exists, it exposes `install` and
`verify`, and `run` turns a failed step into an exit code — because
`nvim --headless -c 'lua ...'` reports a Lua error and then carries on to the
next command, so without it a failed bootstrap would end in a process that
exited zero. Its presence is checked when a source is prepared, before anything
has been moved, rather than discovered halfway through a transaction that then
has to be rolled back. A release from before it existed is refused by name.

**3. The selection is global; the installation is not.** `components.json` lives
at `$XDG_CONFIG_HOME/chroma/components.json`, one file, while `--default` and
the isolated install are two different targets. V1 does not support two parallel
installations, which is a fine limit — but the second install currently
overwrites the first one's selection without saying so, and `uninstall
--purge-selection` would remove a selection another installation is still
reading. *Needed by stage 4.*

**4. Profiles have nowhere to live.** *Settled at stage 4:* CLI knowledge, in
`internal/install/profiles.go`, the same shape as `toolver` and the package-name
registry. A profile is an opinion about which components go together, and an
opinion is not a fact about the product — the contract is read by the editor and
by anything else that ever wants it, while a profile is read by one installer on
one screen. Every id in a profile is checked against the contract being
installed, so a profile that has gone stale fails loudly instead of quietly
installing less than it promised; `everything` is derived from the contract
rather than listed, so it cannot fall behind a new component.

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

**7. `latest` and rate limits.** *Settled at stage 10:* a 403 carrying
`X-RateLimit-Remaining: 0` is reported as what it is — this address is being
rate-limited — with the reset time and the suggestion to set `GITHUB_TOKEN`,
which is used when present and never required. And `latest` is resolved to a tag
before the plan is shown, so what somebody agrees to is a version they can check
and the install state records one.

---

## What would change this design

A second consumer of the component contract — a web page, a different editor,
an Ansible role — would justify moving `components/` to its own artefact with a
published schema. Until then it is two readers in one repository, which is the
cheapest arrangement that cannot drift.
