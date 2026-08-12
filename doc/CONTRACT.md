# Chroma Neovim — Contract v1.0

The governing document: what this configuration is. Changing it requires a
deliberate decision and an entry in the *Contract changes* section.

`DECISIONS.md` is the companion: **why** each choice was made, what was
rejected, and what would change it — including the things deliberately left
out.

---

## Goal

Not "a pretty config". **The best Neovim environment for DevOps.**

## Philosophy

| | |
|---|---|
| 🚀 | fast |
| 🧩 | modular |
| 🔧 | easy to extend |
| 📦 | actively maintained plugins only |
| 📝 | properly documented |
| 🎨 | Catppuccin Mocha |

## Workflow

```
Kitty → Zellij → Yazi → Neovim
```

Not VS Code.

---

## Rule #1 — zero code from memory

For **every** plugin, in this order:

1. read the current documentation (README + `doc/*.txt` from the plugin repo),
2. check for breaking changes (CHANGELOG / releases / issues),
3. only then write the configuration.

No exceptions. This rule is the reason this contract exists.

### Rule #1a — Neovim 0.12 is a floor, not a target

**Neovim >= 0.12** (LuaJIT). Newer is expected to work and is not refused for
being newer.

0.12 ships a native LSP API — `vim.lsp.config()`, `vim.lsp.enable()`,
`vim.lsp.is_enabled()`, `:lsp`, `:checkhealth vim.lsp`. The LSP layer is built
on that API, not on patterns from the 0.9/0.10 era. Any tutorial older than
0.11 is treated as outdated until verified.

That is why the floor is 0.12 — a real API that a real call needs, not the
version this was developed on. `:checkhealth chroma` asks the question that way
too: it looks for the editor APIs `lua/` actually calls and names the ones that
are absent, and reports the version to make the message useful rather than to
decide the answer. A 0.13 that keeps those APIs passes without a release here
saying it may.

---

## Structure

The tree below is what exists. `config/autocmds.lua` is still absent because
nothing has needed it.

The own-code layout diverged from the original plan on purpose: each module is
a self-contained plugin in a directory of its own rather than a file in one
shared namespace, so any of them can be lifted into its own repository without
edits. They carry the project's name — `chroma-vault`, `chroma-terraform`,
`chroma-aws` — because they are its modules, not because the name says what
they do; `:help chroma-nvim-vault` and the module headers do that.

`lua/chroma/` is the opposite category and has grown into it: not a tool, but
this configuration talking about itself — which components exist, which are
enabled, what the machine has, how the editor bootstraps, and how a project
declares what to run.

```
~/.config/nvim
├── init.lua
├── lua
│   ├── config
│   │   ├── autocmds.lua          (planned)
│   │   ├── commands.lua
│   │   ├── keymaps.lua
│   │   ├── lazy.lua
│   │   ├── options.lua
│   │   └── parsers.lua
│   ├── plugins
│   │   ├── navigation.lua
│   │   ├── ui.lua
│   │   ├── git.lua
│   │   ├── lsp.lua
│   │   ├── completion.lua
│   │   ├── treesitter.lua
│   │   ├── formatting.lua
│   │   ├── lint.lua
│   │   ├── editing.lua
│   │   ├── sessions.lua
│   │   └── devops.lua
│   ├── chroma-vault              our own plugin
│   ├── chroma-terraform          our own runner
│   ├── chroma-aws                our own profile/region switcher
│   └── chroma
│       ├── bootstrap.lua         what the CLI drives headlessly
│       ├── components.lua        reads components/, the Lua half
│       ├── health.lua            :checkhealth chroma
│       ├── modules.lua           which of our own modules a selection enables
│       ├── schemas.lua           logical schema name → URL and file patterns
│       ├── state.lua             the user's component selection
│       ├── tools.lua             what a component needs from the machine
│       └── tasks                 the execution layer, see below
├── after
├── components                  component contract, read by Lua and by the CLI
├── cli                         Go module: the installer and CLI (cli/DESIGN.md)
├── doc
│   ├── chroma-nvim.txt         `:help chroma-nvim`
│   ├── tags                    generated, and CI fails if it is stale
│   ├── KEYMAPS.md              every mapping, on one page
│   ├── CONTRACT.md             this file
│   ├── DECISIONS.md            why each of it is the way it is
│   └── chroma-ansible-design.md  frozen, not yet implemented
├── tests                       mini.test suites and their fixtures
├── docker                      a machine to test installations onto
├── assets
├── README.md
└── LICENSE
```

`doc/` is the only documentation directory, and everything in it is installed
along with the configuration. The two governing documents are there rather than
at the root on purpose: what this thing promises, and why, is worth having
beside an installation and not only in a clone. `:helptags` reads `*.txt` and
ignores them.

One `plugins/*.lua` file = one domain. No junk-drawer files.

---

## Plugins

### Navigation
- `DrKJeff16/project.nvim` — the maintained fork. `ahmedkhalf/project.nvim`
  is rejected: no commit since August 2024, 96 open issues, deprecated API calls.
- `fzf-lua`
- `oil.nvim`
- `yazi.nvim`
- `mini.icons` — the single icon provider for the whole config

### UI
- `catppuccin`
- `which-key`
- `aerial` — code outline: what is in this file and where
- `trouble` — diagnostic, quickfix and LSP lists: what is wrong and where.
  Its `symbols` mode stays unused so it does not duplicate aerial.
- `render-markdown`
- `snacks.nvim` — **selected modules only**. Enabled so far: `lazygit`,
  `dashboard`. The dashboard replaces the planned `alpha`; alpha is still
  maintained, so this is deduplication rather than rejection — snacks was
  already a dependency and its dashboard finds fzf-lua by itself.

### Git
- `gitsigns`
- lazygit through the `snacks.nvim` lazygit module. `kdheepak/lazygit.nvim`
  is rejected: last push 2025-12, 52 open issues, and no colourscheme
  integration. The snacks module generates a lazygit theme from the active
  Neovim colourscheme, which is what the Catppuccin rule actually requires,
  and snacks is on the plugin list already.

### LSP
- `mason.nvim`
- `mason-lspconfig.nvim`
- `mason-tool-installer.nvim`
- `nvim-lspconfig`

> To verify during implementation: the division of responsibility between the
> native `vim.lsp.config/enable` (0.12) and `nvim-lspconfig` / `mason-lspconfig`.
> Settled by documentation, not by assumption.

### Completion
- `blink.cmp`
- `friendly-snippets`

### Syntax
- `nvim-treesitter`

### Formatting
- `conform.nvim`

### Lint
- `nvim-lint`

### Sessions
- `persisted.nvim` — chosen over `auto-session` (larger surface, 28 open
  issues) and `persistence.nvim` (no push in nine months). Sessions are per
  directory and per git branch.

### DevOps
Terraform · Terragrunt · Helm · Docker · Kubernetes · YAML · Ansible

- `kubectl.nvim` — full Kubernetes workflow (see *Custom code* for why this
  replaced the planned `kube.nvim`)
- `nvim-ansible` — the `yaml.ansible` filetype that ansible-lint and ansiblels
  need, `K` on a module through `ansible-doc`, and `gf` into a role. Its own
  playbook runner is deliberately not exposed: how a repository runs Ansible is
  what that repository says, and an editor with one declared and one inferred
  way of running things has two. A separate concern from vault handling. Note:
  the upstream repo ships no licence.

---

## Operational decisions

- **Repo:** `https://github.com/ultherego/chroma-nvim.git`
- **Deployment:** the repository is itself a Neovim configuration directory.
  Clone it to `~/.config/nvim`, or clone it anywhere and symlink — nothing
  depends on the location. `README.md` covers both, plus the `$NVIM_APPNAME`
  route for running it beside an existing configuration.
- **Terraform:** the stack also covers `terragrunt`.
- **Language:** all project files — docs, comments, commit messages — are in English.
- **Two languages, one repository.** The configuration is Lua; the installer and
  CLI are Go, in `cli/`, as a module of their own with its own toolchain and its
  own CI jobs. They share one release lifecycle and exactly one interface: the
  component contract in `components/`. Nothing in `lua/` imports Go and nothing
  in `cli/` parses Lua. Rule #1 applies to the Go ecosystem in full.

### What the CLI may depend on

The Go module went from zero dependencies to a handful, deliberately and once.
The rule that replaced "none" is not "whatever helps": **minimal reviewed
libraries, confined to the packages that face a person.**

| | |
|---|---|
| **Where** | `internal/tui` (the questions) and `internal/report` (the printing), and nowhere else. Nothing that decides anything may import them. |
| **What** | `charm.land/huh/v2` for selectors, `charm.land/lipgloss/v2` for tables, and what those two pull in. |
| **How pinned** | Exact versions in `go.mod`, hashes in `go.sum`. CI runs `go mod verify` and then `go mod tidy` against a clean diff, so a dependency cannot arrive inside a commit about something else. |
| **What it may not cost** | The binary stays static and single-file, and the CLI keeps working with no terminal at all. |

The last line is the test of the whole arrangement, and it is a real one: delete
both packages and every command still installs, updates and reports — over a
pipe, in CI, into a file, with the printed questions that are the correct
implementation for those and not a fallback. A dependency that could not be
deleted this way would be a dependency in the wrong place.

`--plain`, or `CHROMA_PLAIN=1`, forces that path on a terminal too. It exists so
the two can be compared on one machine, and so a terminal that draws the
selectors badly is an inconvenience rather than a blocked installation.

Adding one is a contract change with a row in the table below, and the questions
are Rule #1's: what does it cost in modules and owners, what breaks if it is
abandoned, and what does the CLI do when it is deleted.

---

## Development

**The test suite.** The modules that touch secrets and infrastructure — vault,
terraform, AWS — and the component layer that decides what runs are covered by
it, because being wrong in any of them is expensive.

```sh
nvim --headless --noplugin -u tests/minimal_init.lua \
     -c "lua MiniTest.run()" -c "qa!"
```

It loads mini.test and `lua/` only, not the configuration.

**It needs `XDG_RUNTIME_DIR` set, and a shell that has none fails the vault
suite wholesale.** That is the modules doing their job — a prompted password
goes to the private runtime directory or nowhere — but the failure reads like a
regression rather than like a missing environment, so it is worth knowing
before the first red run. Session shells that are not logged in through a
seat manager routinely have no such variable.

**Every new test must be killed by a mutation.** Break the thing it claims to
cover, watch it fail, put it back. A test that passes either way is worse than
no test: it is a claim of cover that nobody will check again. Most of what the
external audits have found in this repository was of exactly that shape.

**The help tags are generated.** After editing `doc/chroma-nvim.txt`:

```vim
:helptags doc
```

CI fails if `doc/tags` is out of date, so this is not optional.

**The CLI** is a Go module in `cli/` with its own tests, formatting and vet
jobs. `cd cli && go test ./...`. Note that `selene` lints this repository as
Lua 5.1, so `goto` and its labels do not parse — measured, after writing one.

**A green `go test` on this machine does not mean the CLI builds.** CI
cross-compiles for linux/amd64, linux/arm64 and darwin/arm64; a development
machine builds one of the three, so anything platform-specific compiles here and
fails there. Measured: reading a modification time as `stat.Mtim` is correct on
Linux and does not exist on Darwin, where the field is `Mtimespec`, and the
whole test suite was green before the cross-compile gate found it. Before
committing anything that touches `syscall`, and cheaply enough to do always:

```sh
cd cli
for target in linux/amd64 linux/arm64 darwin/arm64; do
  GOOS="${target%/*}" GOARCH="${target#*/}" CGO_ENABLED=0 go build -o /dev/null ./cmd/chroma
done
```

The lesson generalises past the compiler. `go test ./...` also passes or fails
according to what the machine underneath it does: the tools on its PATH, and the
filesystem its temporary directories are on. Two of the same day's failures were
that — a gate that needed `tree-sitter`, and an identity proof that ext4
invalidates and btrfs does not. Anything whose result could depend on the
machine belongs in a container, and `golang:1.24-bookworm` is a serviceable
stand-in for the CI runner because it has Go, git and none of the rest:

```sh
docker run --rm -v "$PWD:/src:ro" golang:1.24-bookworm \
  bash -c 'cp -r /src /work && cd /work/cli && go test ./...'
```

**Installations are tested in a container, never on a development machine.**
`chroma install` fetches plugins, Mason packages and treesitter parsers; running
that against somebody's home directory writes hundreds of megabytes that no
single deletion undoes. `docker/Dockerfile` builds a machine to install onto,
and `--rm` is the cleanup:

```sh
docker build -t chroma-test docker/
cd cli && go build -o ../dist/chroma ./cmd/chroma && cd ..
docker run --rm -t -v "$PWD:/src:ro" -v "$PWD/dist/chroma:/usr/local/bin/chroma:ro" \
  chroma-test chroma install --source-tree /src --components '' --yes
```

The repository goes in read-only, so nothing the container does can reach back
out. It is Ubuntu rather than the maintainer's distribution on purpose: a
configuration that only installs on the machine it was written on is not
installable.

**Every finished command needs one test through the built binary and the public
dispatch.** Testing the implementation of a subcommand is not testing that
anybody can reach it: `rollback` was written, built, vetted and unit tested
while `chroma rollback` answered "not implemented yet", because the line that
dispatches it had never been added. Nothing below the entry point could see the
gap.

The cheap version of this is a smoke run — `chroma <command> --dry-run` or
`--help` against the compiled binary — and it catches the whole class of "the
code exists and the user has no way to it". `cmd/chroma` now also holds the
structural half: dispatch is a table, and two tests keep it and the usage text
in step in both directions.

**`actionlint` needs `shellcheck` on PATH, or it checks strictly less than CI
does.** Without it the shellcheck integration is skipped silently and every
`run:` block goes unread — a local pass then means nothing. CI's runner has
shellcheck, so the difference surfaces there. Run it as:

```sh
actionlint -shellcheck "$(command -v shellcheck)"
```

which fails outright when shellcheck is absent instead of quietly passing. One
consequence worth knowing: a single-quoted `run:` block is shell to shellcheck
even when its contents are Lua, so backticks in a comment inside one read as a
command substitution (SC2016).

---

## Rule #2 — survey before building

Before writing any custom plugin, survey what already exists: search, then
judge candidates on activity (last push, open issues), licence, documentation
and fit with the rest of this config. Write custom code only where the survey
shows a real gap.

A worse plugin that someone else maintains still beats a better one that only
we maintain — unless the gap is genuine.

---

## Custom code

Scope set by the survey of 2026-08-06, not by assumption.

Both modules that handle secrets or change infrastructure are **stable**. They
are in use, covered by the test suite, and have been through eleven external
audits, with the findings of each series dispositioned before the next began.
The archived rounds are in the history, under `docs(audit): archive … project
audit`; there is no inbox file at the root any more, and a round in progress
lives outside the repository until it is archived.
What they guarantee is written out in `:help chroma-nvim-vault` and `:help
chroma-nvim-terraform`, each with a section on what it does **not** cover.
Nothing there describes an intention; every line describes current behaviour.

### `chroma-vault.nvim` — stable, in `lua/chroma-vault/`
The one genuine gap. Every existing candidate is a single-person project with
0–7 stars, the most visible one abandoned since 2023. Nothing meets the bar of
"actively maintained + properly documented", so this is ours to build.

### `chroma-terraform.nvim` — stable, a thin runner, in `lua/chroma-terraform/`
Most of the originally planned scope is already covered by plugins this config
installs anyway:

| Originally planned | Actually provided by |
|---|---|
| `fmt` | conform.nvim `terraform_fmt`, falling back to `tofu_fmt` where only OpenTofu is installed, and `terragrunt_hclfmt` for terragrunt files. Requires one of those CLIs — the LSP is not a fallback, it shells out to `terraform fmt` itself. |
| `validate` | `tflint`, running as a language server. It is deliberately **not** registered with nvim-lint as well; that would double every finding. |
| `init` | implemented after all as `:TerraformInit`; it is one keystroke from where you already are |

What remains is a `plan` / `apply` / `destroy` runner. Existing options were
rejected: `mvaldes14/terraform.nvim` had no push for a year, and
`telescope-terraform.nvim` is built on telescope, which this config does not use.

### `aws` — built, in `lua/chroma-aws/`
Not in the original plan, but the contract reserved an AWS keymap group and
the survey found nothing to fill it with: `nvim-aws-cli` has no stars and no
commit since March 2025, `nvimawscli` has twelve and manages EC2 instances.
Scope is deliberately one thing — set AWS_PROFILE and AWS_REGION on the Neovim
process so every subprocess, the terraform runner included, inherits them.

### ~~`kube.nvim`~~ — dropped, use `kubectl.nvim`
[Ramilito/kubectl.nvim](https://github.com/Ramilito/kubectl.nvim) covers the
entire planned scope — context, namespace, pods, logs, describe, exec — and
adds port-forwarding, diffs, log tailing, column sorting and a Helm view.
Apache-2.0, released the same day as this survey, no telescope dependency.

Two things accepted deliberately:
- it loads a prebuilt Rust binary via `blink.download` (the blink ecosystem is
  already present through blink.cmp);
- the repo contains a `kubectl-telemetry` crate. It is an optional Cargo
  feature, built only by the `build_dev` target; release builds omit it, and
  it is tracing instrumentation (tokio-console, OTLP to a local collector),
  not analytics.

---

## The execution layer

Chroma does not learn the shape of anybody's infrastructure. A repository says,
in `.chroma/tasks.json`, what a given operation is: **what to run, from which
directory, with which environment.** `ansible-playbook`, `terragrunt`, `make`
and an internal company CLI are one kind of thing to it — an executable.

Tasks are **core**, not a component, and live in `lua/chroma/tasks/`. The
reasoning, and the measurements each rule rests on, are in `DECISIONS.md` under
the same heading. The invariants:

| | |
|---|---|
| Source | `.chroma/tasks.json`, searched **upward only** from Neovim's working directory; the first entry of that name wins, valid or not. It must resolve to a readable regular file. |
| Schema | `schema` is required and is `1`. Document is `{schema, tasks}` exactly; a task is `id`, `name`, `cwd`, `argv` required and `group`, `env` optional. Unknown fields, `null`, empty strings, duplicate ids and non-string `argv` elements are all refusals that name the task and the field. |
| Trust | Evaluated only on an explicit Run Task, never at startup, and never cached for a session. File trust only — never directory trust, and Chroma never tells anybody to run `:trust <file>`. `denied` is reported as denied, not as "no tasks". |
| Working directory | `project` or a `relative` path below it. `realpath(cwd)` must equal or be a descendant of `realpath(project root)`, compared by path components. After discovery, Neovim's own directory is never consulted again. |
| Execution | `argv` only, no shell. `argv[0]` is resolved against the task's effective `PATH` and directory and handed over absolute; `argv[1..]` reach the process byte for byte. `env` overrides the inherited environment rather than replacing it. |
| Gates | The preview shows what will run, and only an explicit affirmative starts it. Escape, dismissal and silence all mean no. |
| Process | One Run is one new process with its own `run_id`, in a terminal that survives every exit status. |

**Project tasks need Neovim >= 0.12.3** — one feature's floor, not a raise of
Chroma's. It is upstream's: `799cbfff8` fixes a command injection in
`vim.secure.read()`'s `view` path and is absent from 0.12.0–0.12.2. Below it
tasks fail closed and `:checkhealth chroma` reports that gate as its own line.

**There is no bridge to Managed Terraform.** A custom task running `terraform
plan` produces nothing `:TerraformApply` may accept; the managed lifecycle is
keyed by one directory holding one hashed plan. `lua/chroma/tasks/**` may not
depend on Managed Terraform, and an architecture test enforces it.

There is exactly one way to run something, and it is declared. That is why
`<leader>ar` and `require("ansible").run()` were removed rather than shipped
beside this: an editor with one declared and one inferred way of running things
has two.

---

## Keymaps

Nothing accidental. Everything grouped under `<Space>`.

| Prefix | Group | Shown |
|---|---|---|
| `f` | Find | always |
| `p` | Project | always |
| `g` | Git | always |
| `l` | LSP | always |
| `b` | Buffers | always |
| `w` | Windows | always |
| `s` | Sessions | always |
| `x` | Tools | always |
| `t` | Terraform | with the component |
| `k` | Kubernetes | with the component |
| `a` | Ansible | with the component |
| `A` | AWS | with the component |

Letter prefixes are assigned once, globally — a keymap conflict is a bug,
not an inconvenience. The four domain groups are registered only when their
component is enabled, so which-key describes the editor somebody has rather
than the one they could have had.

Run Task is `<leader>xr`, under Tools rather than under a domain: a task is not
a Terraform thing or an Ansible thing, and putting it beside `<leader>tp` would
say it was.

---

## Contract changes

| Date | Change | Reason |
|---|---|---|
| 2026-08-06 | v1.0 — contract established | project start |
| 2026-08-06 | Renamed UltherNvim → Chroma Neovim; all project files switched to English; `lua/ulther/` → `lua/chroma/` | owner decision |
| 2026-08-06 | Added rule #2 (survey before building); dropped `kube.nvim` for `kubectl.nvim`; narrowed `chroma-terraform.nvim` to a plan/apply/destroy runner | plugin survey showed the planned scope was partly already solved |
| 2026-08-06 | `lazygit.nvim` replaced by the `snacks.nvim` lazygit module | upstream stale and has no colourscheme integration; snacks was already a dependency |
| 2026-08-06 | `alpha` replaced by the `snacks.nvim` dashboard module | snacks was already a dependency; alpha remains maintained, so this is deduplication, not rejection |
| 2026-08-06 | Added `persisted.nvim` for Sessions and a own `lua/chroma-aws/` module for the AWS group | both groups were reserved but unfilled; no adoptable AWS plugin exists |
| 2026-08-08 | `chroma-vault.nvim` and `chroma-terraform.nvim` promoted from beta to stable | fifth external audit closed, every finding dispositioned; release gate met on 97050e1 with CI green |
| 2026-08-08 | Renamed DevOps nVim → Chroma Neovim: repository, `$NVIM_APPNAME`, help file and tag prefix, `:checkhealth chroma`, and the own modules to `chroma-vault` / `chroma-terraform` / `chroma-aws` | owner decision; the project has a name and a logo of its own rather than a description |
| 2026-08-08 | Added a Go module in `cli/` for the installer and CLI, and a `components/` contract read by both languages | distribution is the next stage; the component list must exist once, not once per consumer |
| 2026-08-11 | The CLI may take third-party libraries, in `internal/tui` and `internal/report` only: `huh` for the selectors, `lipgloss` for the tables | owner decision; a full-screen interface needs raw mode, cursor addressing and a redraw loop, and the standard library has none of the three. The boundary is what keeps it honest — both packages can be deleted and every command still works over a pipe |
| 2026-08-11 | Added the execution layer: `.chroma/tasks.json`, `<leader>xr`, and a second version floor of 0.12.3 for that one feature | there is no correct way to lay out or run infrastructure, so Chroma stops inferring and lets a repository declare. The floor is upstream's fix to `vim.secure.read()`, not a preference |
| 2026-08-11 | Retired the Ansible execution path: `<leader>ar` and `require("ansible").run()` removed, the required `ansible` tool replaced by an optional `ansible-doc`; `nvim-ansible` stays for filetype detection, `ansible-doc` and `gf` | one editor may not have both a declared and an inferred way of running the same thing. The tool was required for exactly the reason that was retired |
