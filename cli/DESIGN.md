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
  "contract": 1,
  "id": "terraform",
  "name": "Terraform / OpenTofu",
  "requires": ["core"],
  "tools": {
    "required": [
      { "any": ["terraform", "tofu"], "reason": "plan, apply and formatting all shell out" }
    ],
    "recommended": [
      { "id": "terraform-ls", "reason": "completion and diagnostics" },
      { "id": "tflint", "reason": "linting, as a language server" }
    ]
  },
  "nvim": {
    "plugins": ["plugins.devops"],
    "modules": ["chroma-terraform"]
  }
}
```

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

## The installed state

`~/.local/state/<appname>/install.json` — state, not configuration, so it is not
in the config directory where a `git pull` would see it as untracked.

```json
{
  "contract": 1,
  "version": "v2.1.0",
  "appname": "chroma-nvim",
  "installed_at": "2026-08-08T21:40:00Z",
  "profile": "custom",
  "components": ["core", "terraform", "kubernetes", "aws"],
  "backup": null
}
```

It is what makes `update` quiet — it upgrades the same components to the next
release rather than asking again — and what `components` edits. The Lua side
reads `components` and nothing else; the rest is the CLI's business.

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

## What would change this design

A second consumer of the component contract — a web page, a different editor,
an Ansible role — would justify moving `components/` to its own artefact with a
published schema. Until then it is two readers in one repository, which is the
cheapest arrangement that cannot drift.
