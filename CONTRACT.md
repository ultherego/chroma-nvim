# DevOps nVim — Contract v1.0

The governing document. Changing it requires a deliberate decision and an entry
in the *Contract changes* section.

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

```
~/.config/nvim
├── init.lua
├── lua
│   ├── config
│   │   ├── autocmds.lua
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
│   └── devops
│       ├── ansible.lua
│       ├── kubernetes.lua
│       ├── terraform.lua
│       ├── aws.lua
│       └── utils.lua
├── after
├── README.md
└── LICENSE
```

One `plugins/*.lua` file = one domain. No junk-drawer files.

---

## Plugins

### Navigation
- `project.nvim`
- `fzf-lua`
- `oil.nvim`
- `yazi.nvim`

### UI
- `catppuccin`
- `which-key`
- `alpha`
- `aerial`
- `trouble`
- `render-markdown`
- `snacks.nvim` — **selected modules only**, the module list is a deliberate choice

### Git
- `gitsigns`
- `lazygit.nvim`

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

### DevOps
Terraform · Terragrunt · Helm · Docker · Kubernetes · YAML · Ansible

---

## Operational decisions

- **Repo:** `https://github.com/ultherego/dev-nvim.git`
- **Deployment:** `~/.config/nvim` → symlink to the repo working tree.
  Editing the repo takes effect in Neovim immediately.
- **Terraform:** the stack also covers `terragrunt` (`/usr/local/bin/terragrunt`).
- **Language:** all project files — docs, comments, commit messages — are in English.

---

## Custom code

This is where something genuinely good is meant to come out. Not helpers —
real plugins.

### `ansible-vault.nvim`
A real plugin. Not a helper.

### `kube.nvim`
- context
- namespace
- pods
- logs
- describe
- exec

### `terraform.nvim`
- init
- fmt
- validate
- plan
- apply
- destroy

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
