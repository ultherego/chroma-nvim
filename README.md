<div align="center">

# DevOps nVim

**The best Neovim environment for DevOps.**

🚀 fast · 🧩 modular · 🔧 easy to extend · 📦 maintained plugins only · 📝 documented · 🎨 Catppuccin Mocha

</div>

---

A Neovim configuration for people who work with Terraform, Terragrunt,
Kubernetes, Helm, Ansible, Docker and YAML, and who live in a terminal rather
than an IDE. Not a general-purpose config with DevOps bolted on — DevOps is the
starting point.

```
Kitty → Zellij → Yazi → Neovim
```

**Full documentation lives in the editor:** `:help devops-nvim`

## Status

| Layer | State |
|---|---|
| Bootstrap, colourscheme | done |
| Options, keymaps, which-key | done |
| Navigation — fzf-lua, oil, yazi, project | done |
| LSP — mason, native `vim.lsp` API, 9 servers | done |
| Completion — blink.cmp | done |
| Treesitter | done |
| Formatting — conform.nvim | done |
| Lint — nvim-lint | done |
| Git — gitsigns, lazygit via snacks | done |
| Editing — surround, pairs, text objects, todo | done |
| UI extras | not yet |
| `ansible-vault.nvim`, `terraform.nvim` | not yet |

Startup is currently ~23 ms.

> **Note:** Terraform formatting needs the `terraform` CLI on your PATH.
> terraform-ls is not a substitute — it shells out to `terraform fmt` itself.
> See `:help devops-nvim-formatting-tf`.

## Requirements

- **Neovim ≥ 0.12** — uses the native LSP API and the rewritten nvim-treesitter
- `git ≥ 2.19`, `curl`, `tar`, a C compiler
- `tree-sitter-cli ≥ 0.26.1` **from your system package manager**, not npm
- `ripgrep`, `fd`, `fzf > 0.36`
- A Nerd Font
- Optional but assumed: `lazygit`, `yazi`
- DevOps tooling as needed: `terraform`/`tofu`, `terragrunt`, `kubectl`, `helm`, `ansible`

Language servers and linters install themselves through Mason.

## Installation

```sh
git clone https://github.com/ultherego/dev-nvim.git ~/Projekty/DevOpsNvim
ln -s ~/Projekty/DevOpsNvim ~/.config/nvim
nvim
```

First start bootstraps lazy.nvim, installs the plugins, and lets Mason fetch the
language servers while treesitter compiles parsers. Give it a minute, then check
`:Lazy`, `:Mason` and `:checkhealth`.

To try it alongside an existing config instead:

```sh
ln -s ~/Projekty/DevOpsNvim ~/.config/devops-nvim
NVIM_APPNAME=devops-nvim nvim
```

## Keymaps

Leader is <kbd>Space</kbd>. Press it and wait — which-key shows the rest. Every
prefix is assigned once, globally:

| | | | |
|---|---|---|---|
| `f` Find | `p` Project | `g` Git | `l` LSP |
| `t` Terraform | `k` Kubernetes | `a` Ansible | `A` AWS |
| `b` Buffers | `w` Windows | `s` Sessions | `x` Tools |

Most-used:

```
<leader>ff   files            <leader>fe   file explorer (oil)
<leader>fg   grep             <leader>fy   yazi
<leader>fb   buffers          <leader>pp   projects
-            parent directory (oil)
```

Neovim 0.12 already provides `gc`/`gcc`, `]d`/`[d`, `]b`/`[b`, `K`, `grn`, `gra`,
`grr`, `gri`, `grt`. This config does not redefine them.

Full list: `:help devops-nvim-keymaps`

## A word about Zellij

Zellij binds mode switches to plain control keys and intercepts them before
Neovim sees them — `Ctrl-g q h o b s t p n`, plus most of `Alt`. Several plugin
defaults land squarely on those keys and would silently never fire.

This config remaps them: oil's `<C-s>`/`<C-h>`/`<C-t>`/`<C-p>`, fzf-lua's
`ctrl-s` and `alt-h`/`alt-i`/`alt-f`, and blink.cmp's `<C-n>`/`<C-p>`/`<C-b>`.

If you do not use Zellij, none of this hurts you. Details and the full list:
`:help devops-nvim-zellij`

## The two rules

**Zero code from memory.** For every plugin: read the current documentation,
check breaking changes, then configure. This project exists because configs
written from memory kept targeting APIs that no longer exist — the deprecated
`lspconfig` setup pattern, the nvim-treesitter branch split, mason-lspconfig
dropping `setup_handlers`, Neovim shipping its own `catppuccin` colourscheme.
Every one of those would have been written wrong from memory.

**Survey before building.** Check what already exists before writing a custom
plugin, and judge it on activity, licence and fit. A worse plugin somebody else
maintains beats a better one only you maintain — unless the gap is real.

Full terms: [`CONTRACT.md`](./CONTRACT.md)

## Regenerating the help tags

After editing `doc/devops-nvim.txt`:

```vim
:helptags doc
```

## Licence

[MIT](./LICENSE)
