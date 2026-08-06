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
| LSP — mason, native `vim.lsp` API, 10 servers | done |
| Completion — blink.cmp | done |
| Treesitter | done |
| Formatting — conform.nvim | done |
| Lint — nvim-lint | done |
| Git — gitsigns, lazygit via snacks | done |
| Editing — surround, pairs, text objects, todo | done |
| UI — dashboard, aerial, trouble, markdown | done |
| DevOps — kubectl.nvim, nvim-ansible | done |
| Health check, CI, lint config | done |
| `ansible-vault.nvim` — inline values, whole files, transparent editing, rekey | done |
| `terraform.nvim` — plan / review / apply, terragrunt-aware | done |
| Sessions — persisted.nvim | done |
| AWS — own profile/region switcher | done |

Startup is ~25 ms with 32 plugins, measured locally with
`nvim --headless --startuptime` on CachyOS; treat it as an indication, not a
promise for your machine.

> **Note:** Terraform formatting needs the `terraform` CLI on your PATH.
> terraform-ls is not a substitute — it shells out to `terraform fmt` itself.
> See `:help devops-nvim-formatting-tf`.

## Requirements

- **Neovim ≥ 0.12** — uses the native LSP API and the rewritten nvim-treesitter
- `git ≥ 2.19`, `curl`, `tar`, a C compiler
- `tree-sitter-cli ≥ 0.26.1` **from your system package manager**, not npm
- `ripgrep`, `fd`, `fzf > 0.36`, `bat` (used by fzf-lua's `fzf-native` preview profile)
- A Nerd Font
- Optional but assumed: `lazygit`, `yazi`
- DevOps tooling as needed: `terraform`/`tofu`, `terragrunt`, `kubectl`, `helm`, `ansible`

Language servers and linters install themselves through Mason.

## Installation

This repository **is** a Neovim configuration directory. It does not install
into one — it becomes one.

### Try it without touching your setup

`$NVIM_APPNAME` makes Neovim use a different configuration directory, so this
runs beside whatever you already have. Nothing is overwritten, and nothing is
shared — plugins, sessions and Mason packages all live under the new name.

```sh
git clone https://github.com/ultherego/dev-nvim.git ~/.config/devops-nvim
NVIM_APPNAME=devops-nvim nvim
```

Keep it around with an alias in your shell config:

```sh
alias dvim='NVIM_APPNAME=devops-nvim nvim'        # bash / zsh
alias --save dvim 'NVIM_APPNAME=devops-nvim nvim' # fish
```

### Adopt it as your main config

Once you've decided. Move any existing config aside first — `ln -s` won't
replace a directory, and you'll want the old one back if you change your mind.

```sh
[ -e ~/.config/nvim ] && mv ~/.config/nvim ~/.config/nvim.backup

git clone https://github.com/ultherego/dev-nvim.git ~/.config/nvim
nvim
```

Prefer to keep the clone with your other projects and symlink it? That works
too — nothing here depends on where the clone lives:

```sh
git clone https://github.com/ultherego/dev-nvim.git ~/src/devops-nvim
mkdir -p ~/.config
ln -s ~/src/devops-nvim ~/.config/nvim
```

### First start

lazy.nvim bootstraps itself, installs the plugins, and Mason fetches the
language servers while treesitter compiles parsers. Give it a minute, then:

```vim
:checkhealth devops
```

Read that one first. Most of this config drives external programs, and when
one is missing the symptom is usually silence rather than an error — it tells
you what's absent and what stops working without it. `:Lazy`, `:Mason` and the
full `:checkhealth` cover the rest.

### Uninstalling

Nothing is installed outside these directories:

```
~/.config/nvim        (or ~/.config/<appname>)
~/.local/share/nvim   plugins, Mason packages, treesitter parsers
~/.local/state/nvim   undo history, sessions, logs
```

Remove those, restore any backup you moved aside, and no trace remains.

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

## If you use Zellij

Skip this if you don't — the remappings below are harmless either way.

Zellij's defaults put mode switches on plain control keys and intercept them
in every mode, including while you're typing into Neovim: `Ctrl-g q h o b s t
p n`, plus most of `Alt`. Several plugin defaults land squarely on those keys
and would silently never fire.

This config remaps them — oil's `<C-s>`/`<C-h>`/`<C-t>`/`<C-p>`, fzf-lua's
`ctrl-s` and `alt-h`/`alt-i`/`alt-f`, and blink.cmp's `<C-n>`/`<C-p>`/`<C-b>`.
Without that, eleven mappings would do nothing at all, with no error to explain
why — including next and previous completion item.

Check what your Zellij actually takes:

```sh
rg 'bind "Ctrl' ~/.config/zellij/config.kdl
```

Neovim's own `Ctrl-h` and `Ctrl-o` can't be recovered by any editor config —
lock Zellij with `Ctrl-g` when you need them. Details: `:help
devops-nvim-zellij`

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

## Tests

The own modules — vault, terraform, AWS — have a suite, because they touch
secrets and infrastructure:

```sh
nvim --headless --noplugin -u tests/minimal_init.lua \
     -c "lua MiniTest.run()" -c "qa!"
```

It loads mini.test and `lua/` only, not the configuration, so it finishes in
under a second.

## Regenerating the help tags

After editing `doc/devops-nvim.txt`:

```vim
:helptags doc
```

## Licence

[MIT](./LICENSE)
