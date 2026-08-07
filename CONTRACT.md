# DevOps nVim — Contract v1.0

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

### Rule #1a — the baseline is Neovim 0.12

Target environment: **NVIM v0.12.4** (LuaJIT 2.1).

0.12 ships a native LSP API — `vim.lsp.config()`, `vim.lsp.enable()`,
`vim.lsp.is_enabled()`, `:lsp`, `:checkhealth vim.lsp`. The LSP layer is built
on that API, not on patterns from the 0.9/0.10 era. Any tutorial older than
0.11 is treated as outdated until verified.

---

## Structure

The tree below is what exists. `config/autocmds.lua` is still absent because
nothing has needed it. `README.md` carries the per-layer status.

The own-code layout diverged from the original plan on purpose: each module is
a self-contained plugin under its own name rather than a file under a shared
`lua/devops/` namespace, so any of them can be lifted into its own repository
without edits. `lua/devops/` kept only what is genuinely about this
configuration rather than about a tool — the health check.

```
~/.config/nvim
├── init.lua
├── lua
│   ├── config
│   │   ├── autocmds.lua          (planned)
│   │   ├── commands.lua
│   │   ├── keymaps.lua
│   │   ├── lazy.lua
│   │   └── options.lua
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
│   │   └── devops.lua
│   ├── ansible-vault             our own plugin
│   ├── terraform                 our own runner
│   ├── aws                       our own profile/region switcher
│   └── devops
│       └── health.lua            :checkhealth devops
├── after
├── README.md
└── LICENSE
```

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
- `nvim-ansible` — running playbooks and roles; a separate concern from vault
  handling. Note: the upstream repo ships no licence.

---

## Operational decisions

- **Repo:** `https://github.com/ultherego/dev-nvim.git`
- **Deployment:** the repository is itself a Neovim configuration directory.
  Clone it to `~/.config/nvim`, or clone it anywhere and symlink — nothing
  depends on the location. `README.md` covers both, plus the `$NVIM_APPNAME`
  route for running it beside an existing configuration.
- **Terraform:** the stack also covers `terragrunt`.
- **Language:** all project files — docs, comments, commit messages — are in English.

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

Both modules that handle secrets or change infrastructure are **beta**. They
are in use and covered by the test suite, but their safety model has been
revised three times under external audit, so it is not claimed to be settled.
What they guarantee is written out in `README.md` under *Safety model* and in
`:help devops-nvim-vault` and `:help devops-nvim-terraform`. Nothing there
describes an intention; every line describes current behaviour.

### `ansible-vault.nvim` — beta, in `lua/ansible-vault/`
The one genuine gap. Every existing candidate is a single-person project with
0–7 stars, the most visible one abandoned since 2023. Nothing meets the bar of
"actively maintained + properly documented", so this is ours to build.

### `terraform.nvim` — beta, a thin runner, in `lua/terraform/`
Most of the originally planned scope is already covered by plugins this config
installs anyway:

| Originally planned | Actually provided by |
|---|---|
| `fmt` | conform.nvim `terraform_fmt`, and `terragrunt_hclfmt` for terragrunt files. Requires the `terraform` CLI — the LSP is not a fallback, it shells out to `terraform fmt` itself. |
| `validate` | `tflint`, running as a language server. It is deliberately **not** registered with nvim-lint as well; that would double every finding. |
| `init` | implemented after all as `:TerraformInit`; it is one keystroke from where you already are |

What remains is a `plan` / `apply` / `destroy` runner. Existing options were
rejected: `mvaldes14/terraform.nvim` had no push for a year, and
`telescope-terraform.nvim` is built on telescope, which this config does not use.

### `aws` — built, in `lua/aws/`
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

## Keymaps

Nothing accidental. Everything grouped under `<Space>`.

| Group | Scope |
|---|---|
| Find | search |
| Project | projects |
| Git | git |
| LSP | LSP |
| Terraform | terraform |
| Kubernetes | kubernetes |
| Ansible | ansible |
| AWS | aws |
| Buffers | buffers |
| Windows | windows |
| Sessions | sessions |
| Tools | tools |

Letter prefixes are assigned once, globally — a keymap conflict is a bug,
not an inconvenience.

---

## Contract changes

| Date | Change | Reason |
|---|---|---|
| 2026-08-06 | v1.0 — contract established | project start |
| 2026-08-06 | Renamed UltherNvim → DevOps nVim; all project files switched to English; `lua/ulther/` → `lua/devops/` | owner decision |
| 2026-08-06 | Added rule #2 (survey before building); dropped `kube.nvim` for `kubectl.nvim`; narrowed `terraform.nvim` to a plan/apply/destroy runner | plugin survey showed the planned scope was partly already solved |
| 2026-08-06 | `lazygit.nvim` replaced by the `snacks.nvim` lazygit module | upstream stale and has no colourscheme integration; snacks was already a dependency |
| 2026-08-06 | `alpha` replaced by the `snacks.nvim` dashboard module | snacks was already a dependency; alpha remains maintained, so this is deduplication, not rejection |
| 2026-08-06 | Added `persisted.nvim` for Sessions and a own `lua/aws/` module for the AWS group | both groups were reserved but unfilled; no adoptable AWS plugin exists |
