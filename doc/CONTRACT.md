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
| 🎨 | Catppuccin Mocha or Everforest, chosen when it is installed |

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

The tree below is what exists. It is the repository, which is not the same as
an installation — the entries marked *repository only* are how this is built
and proved, and never leave it. `config/autocmds.lua` is still absent because
nothing has needed it.

The own-code layout diverged from the original plan on purpose: each module is
a self-contained plugin in a directory of its own rather than a file in one
shared namespace, so any of them can be lifted into its own repository without
edits. They carry the project's name — `chroma-vault`, `chroma-terraform`,
`chroma-aws`, `chroma-ansible` — because they are its modules, not because the
name says what they do; `:help chroma-nvim-vault` and the module headers do
that.

`lua/chroma/` is the opposite category and has grown into it: not a tool, but
this configuration talking about itself — which components exist, which are
enabled, what the machine has, how the editor bootstraps, how a project
declares what to run, and what a plugin's subprocesses are allowed to see of
the environment.

```
chroma-nvim
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
│   ├── chroma-ansible            our own Ansible planner
│   └── chroma
│       ├── bootstrap.lua         what the CLI drives headlessly
│       ├── components.lua        reads components/, the Lua half
│       ├── health.lua            :checkhealth chroma
│       ├── kubernetes.lua        what a cluster subprocess sees of the environment
│       ├── modules.lua           which of our own modules a selection enables
│       ├── schemas.lua           logical schema name → URL and file patterns
│       ├── state.lua             the user's component selection
│       ├── theme.lua             the catalogue, and the colourscheme chosen
│       ├── tools.lua             what a component needs from the machine
│       └── tasks                 the execution layer, see below
├── after
├── components                  component contract, read by Lua and by the CLI
├── themes.json                 the colourschemes this release can draw
├── cli                         Go module: the installer and CLI (cli/DESIGN.md)
│                               repository only
├── doc
│   ├── chroma-nvim.txt         `:help chroma-nvim`
│   ├── tags                    generated, and CI fails if it is stale
│   ├── KEYMAPS.md              every mapping, on one page — repository only
│   ├── CONTRACT.md             this file — repository only
│   ├── DECISIONS.md            why each of it is the way it is — repository only
│   └── chroma-ansible-design.md  what `chroma-ansible` guarantees
│                               repository only
├── tests                       mini.test suites and their fixtures
│                               repository only
├── docker                      a machine to test installations onto
│                               repository only
├── assets                      the image README.md shows — repository only
├── README.md
└── LICENSE
```

`doc/` is the only documentation directory, and it holds two kinds of file.
`chroma-nvim.txt` and `tags` are `:help chroma-nvim`, which is a feature of the
program and is installed with it. `KEYMAPS.md`, `CONTRACT.md`, `DECISIONS.md`
and `chroma-ansible-design.md` are how the project is developed; they are read
in the repository and are **not** installed. `:helptags` reads `*.txt` and
ignores them either way.

**What an installation holds is the program, plus `README.md` and `LICENSE`.**
The list is `install.RuntimeEntries`, it exists once, and the packager and the
installer both read it — so `doc/` appears in it file by file rather than as a
directory. A new `doc/*.txt` therefore ships only once it is named there.

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
- `catppuccin` and `neanias/everforest-nvim` — one colourscheme, chosen at
  install time out of what `themes.json` offers. Both specs ship and exactly
  one is enabled; see "The colourscheme is a choice" in `DECISIONS.md`.
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
  playbook runner is deliberately not exposed, because it infers the command
  from the buffer: running one is `<leader>ar`, which chooses and shows every
  part, or `<leader>xr` for a command the repository declared. A separate
  concern from vault handling. Note: the upstream repo ships no licence.

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

The three modules that handle secrets or change infrastructure are **stable**.
They are in use, covered by the test suite, and each has been audited from
outside with every finding of a series dispositioned before the next began:
eleven rounds behind vault and terraform, and the round `chroma-ansible` was
promoted on.
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

### `chroma-ansible` — stable, in `lua/chroma-ansible/`
An Ansible execution planner, not a playbook runner. It takes a playbook, a
working directory and inventory sources chosen by the operator, asks Ansible
itself what they mean — `ansible-inventory --graph`, `--list-tags`,
`--list-hosts` — and turns the answers into an exact `argv` that is shown in
full before anything starts.

Stable by the same standard vault and terraform were held to: an external
audit closed with every finding dispositioned, the whole operator path
exercised against a real `ansible-core` rather than a stub, and a reading of
every module in one pass afterwards — which found one more defect, on the
failure path, and it is fixed. What it guarantees is in
`doc/chroma-ansible-design.md`, whose twenty sections are written to be cited
from the source.

The invariants that matter most, each with a section behind it:

| | |
|---|---|
| Authority | Ansible is asked what an inventory and a playbook mean; no YAML is parsed here. §10 |
| Inspection | Never at startup, never in the background, never as a side effect of a selection. One consent, bound to the working directory, the playbooks and the inventory sources it named, before the first subprocess. §6 |
| Data | `--graph`, never `--list`: `--list` prints every host variable in plaintext and no flag suppresses it. No subprocess output is written to a message, a notification or a file. §7 |
| Context | One frozen directory, one frozen environment and one set of sources for every subprocess **and** for the run: the environment is captured when the run starts, so the inspections that produced a host count and the playbook that acts on it cannot be in different ones. `:cd` afterwards cannot move it. Inventory sources are resolved against that directory as they are typed and stored resolved, because Ansible answers a missing `-i` with a warning and exit 0 rather than a failure. §3, §5 |
| Degradation | A failed inspection offers Ansible's own output and a way to carry on by hand. Failure to inspect is not failure to execute. §16 |
| Overrides | Inherit or override, never on/off: an omitted flag is not a claim that the behaviour is off. §10 |
| Credentials | No password is collected, stored, forwarded or logged. `-K` and `--ask-vault-pass` ask Ansible to prompt in its own terminal. §11 |
| Gates | The exact array is shown, and only an explicit affirmative starts it. §15 |
| Repeat | `<leader>aR` goes to that same preview, re-resolves the executable, re-checks the paths, and never repeats the previous run's host count or its environment. §14 |
| Ownership | One run owns the planner. Starting either key ends whatever was running, and an answer to a question that outlived its run changes nothing. An inspection is visible while it runs and `:AnsibleCancel` ends it; there is no timeout, because the system being asked has no schedule. §13 |

**There is no bridge to Project Tasks**, in either direction. A task declaring
`argv: ["ansible-playbook", …]` is a task, and this planner is not reachable
from one — the same boundary Managed Terraform has, enforced the same way.

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

There is exactly one way to run something **generically**, and it is declared.
That is why the old `<leader>ar` and `require("ansible").run()` were removed
rather than shipped beside this: they inferred the command from the buffer, and
an editor with one declared and one inferred way of running things has two.

What inference cost is not what a domain runner costs. `chroma-terraform` runs
`terraform`, and `chroma-ansible` runs `ansible-playbook` through a planner
where the operator chooses every part and reads the exact array before it
starts. Neither guesses, and neither is reachable from a task. The generic layer
stays domain-blind in both directions.

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
| `t` | Terraform | with `terraform` |
| `k` | Kubernetes | with `kubernetes` |
| `a` | Ansible | with `ansible` or `vault` |
| `A` | AWS | with `aws` |

Letter prefixes are assigned once, globally — a keymap conflict is a bug,
not an inconvenience. The four domain groups are registered only when the
component that defines the keys under them is enabled, so which-key describes
the editor somebody has rather than the one they could have had.

That component is not always the one the heading is named after, which is why
the column names it, and one heading follows two of them. `<leader>a` is
shared: `chroma-ansible` contributes `<leader>ar` and `<leader>aR`, and
`chroma-vault` contributes the seven Vault operations. The two components are
independent, so the heading is registered when either is enabled — see
`DECISIONS.md`, "A heading follows its keys".

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
| 2026-08-12 | The `<leader>a` group heading is gated on `vault` instead of `ansible`; the label stays *Ansible* | every key under it is an Ansible Vault key and the two components are independent, so the old gate was wrong in both directions at once — working keys with no heading, or a heading over an empty list |
| 2026-08-12 | Added `chroma-ansible`, an Ansible execution planner: `<leader>ar` and `<leader>aR`, `:AnsibleRun` and `:AnsibleRepeat`. `<leader>ar` is the key retired on 2026-08-11, reclaimed for a different model | the key came back, the model did not. The retired one inferred the playbook and the command from the buffer; this one has the operator choose the playbook, the working directory and the inventory, asks Ansible what they mean, shows the exact argument vector and runs nothing without an explicit yes. Domain runners already exist beside the generic layer — `chroma-terraform` is one — so this is symmetry rather than an exception, and the generic layer stays domain-blind in both directions |
| 2026-08-12 | The `ansible` component requires `ansible-playbook` and `ansible-inventory`, and contributes the `chroma-ansible` module; `ansible-doc` stays optional | the planner promises to run playbooks and to list what an inventory declares, so a machine without either binary cannot do what the component says. Both ship in ansible-core, so requiring both costs no extra installation and stops a partial install from looking healthy. This reverses the other half of `568c28e` |
| 2026-08-12 | The `<leader>a` group heading is gated on `ansible` **or** `vault` | the planner gave `ansible` two keys of its own. Gating on `vault` alone was right only while `ansible` contributed none |
| 2026-08-13 | `chroma-ansible` resolves an inventory source against the frozen working directory as it is typed, refuses one that is not a readable file or a directory, and stores the resolved path | found in use. Ansible answers a `-i` that is not there with a warning on stderr and **exit 0** — an empty inventory for the graph, and `skipping: no hosts matched` for the run — so nothing downstream could tell a mistyped path from an inventory with nothing in it. The prompt's completion is anchored at Neovim's directory and the run at the frozen one, which is exactly where the two disagree |
| 2026-08-14 | One planner run owns the interaction: starting `<leader>ar` or `<leader>aR` ends whatever was running, and a question that outlived its run changes nothing when answered | generations settle which answer inside a run is current and cannot settle anything between two, because starting a second leaves the first's generation where it was. The half that bit: answering a picker calls a setter, and a setter bumps a generation — so a run the operator had left made itself current again by being answered, and carried on towards a preview nobody was looking for |
| 2026-08-14 | `:AnsibleCancel` — an inspection is visible while it runs and can be stopped | §13.4 always said cancelling was the operator's, and there was nothing to cancel with: between two questions the editor did nothing at all, for as long as the system being asked took. There is still no timeout, because a dynamic inventory has no schedule to hold it to |
| 2026-08-14 | One planner run uses one frozen environment, captured when the run starts, for every inspection and for the execution | §3.5 promised an exact environment and two of the three exactnesses were kept. Chroma changes `vim.env` itself — `chroma-aws` writes the profile and the region — so switching profile mid-planning had `--list-hosts` resolve against one account and the playbook run against another, with the same argv and a host count that described neither. The preview names the few values that change what an invocation means and prints no others: an environment holds credentials |
| 2026-08-15 | A failed inspection shows Ansible's output in a window of Neovim's own, and the menu of ways onwards is the screen after it | §16 promised the output whole and the planner passed it to `vim.ui.select` as a prompt. Measured on the pinned set: that is fzf-lua's, a prompt there is one line of an fzf command line, and the operator was shown `Inventory inspection failed` with three ways to carry on and no reason. The same measurement gave the second half — fzf-lua passes the prompt in the fzf process's argv, so output naming hosts and paths was readable from the process table, which is what §7.4 exists to prevent |
| 2026-08-15 | `chroma-ansible` promoted from beta to stable | the external audit on `v2.7.0` closed 9/9 with every finding dispositioned; the whole operator path — `<leader>ar` through a real `ansible-core` to a real terminal, `<leader>aR`, and `:AnsibleCancel` on a live inspection — was exercised in a container rather than against stubs; and every module was then read in one pass, which found one further defect on the failure path and closed it |
| 2026-08-15 | Every subprocess `kubectl.nvim` builds is given the editor's environment as it is at that moment, with the plugin's own values on top — `lua/chroma/kubernetes.lua`, installed from that plugin's `config` | the plugin spawns with `clear_env = true` and keeps four variables, so a credential helper never saw the profile `<leader>Ap` had just changed. No allowlist and no provider names: Chroma has no opinion on how a cluster authenticates, and `components/kubernetes.json` still requires `kubectl` alone. Measured on the pinned set: `vim.system` reads a string-keyed environment table and ignores the array part, so the plugin's own `kubectl_cmd.env` was reaching no child at all — the normalisation that makes "the plugin's values win" true is also what makes them arrive |
| 2026-08-16 | An installation holds the program, plus `README.md` and `LICENSE`. `doc/` is named file by file in `install.RuntimeEntries` — `chroma-nvim.txt` and `tags` in, `CONTRACT.md`, `DECISIONS.md`, `KEYMAPS.md` and `chroma-ansible-design.md` out — and `assets/` is out | owner decision, reversing the 2026-08-12 half of "one documentation directory, and it ships". `:help chroma-nvim` is a feature; a document about how the project is developed is not, and neither is the image `README.md` shows on GitHub. It was 570 KB of an installed 1.2 MB that nothing in the editor reads. `README.md` stays and links to the documents in the repository, so nothing became unreachable |
| 2026-08-19 | The colourscheme is chosen when Chroma is installed, out of what the release offers: `themes.json` at the root of the tree says what can be drawn, `$XDG_CONFIG_HOME/chroma/theme.json` says which one was picked, and `chroma install --theme` names it without being asked. Catppuccin Mocha stays the default; Everforest is the second | the look was one name written into four files, so changing it meant editing a configuration an update replaces wholesale. The two documents are the component selection's shape and exist for its reasons: the choice belongs to the person and outlives releases installed over it, and a CLI newer than the release it is installing must not offer a colourscheme that release cannot draw — `:colorscheme catppuccin` on a tree without the plugin loads Neovim 0.12's own built-in and fails silently, which is the failure `DECISIONS.md` line 51 already records. Not a field in `components.json`: rollback keeps the selection document while restoring an older reader, and an unknown field there means safe mode — core alone — over a colourscheme |
