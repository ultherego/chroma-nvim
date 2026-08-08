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
**Why it is like this:** [`DECISIONS.md`](./DECISIONS.md) — the reasoning behind
every choice, and what is deliberately absent

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
| `ansible-vault.nvim` — inline values, whole files, transparent editing, rekey | beta |
| `terraform.nvim` — plan / review / apply, terragrunt-aware | beta |
| Sessions — persisted.nvim | done |
| AWS — own profile/region switcher | done |

**Beta** means the two own modules that handle secrets and change
infrastructure are in use and covered by tests, but their safety model has been
revised three times under external audit and is not yet claimed to be settled.
What they do and do not guarantee is written out in
[Safety model](#safety-model) below; nothing there is aspirational.

Startup is ~25 ms with 32 plugins, measured locally with
`nvim --headless --startuptime` on CachyOS; treat it as an indication, not a
promise for your machine.

> **Note:** Terraform formatting needs the `terraform` CLI on your PATH.
> terraform-ls is not a substitute — it shells out to `terraform fmt` itself.
> See `:help devops-nvim-formatting-tf`.

## Requirements

- **Neovim ≥ 0.12** — uses the native LSP API and the rewritten nvim-treesitter
- `git ≥ 2.19`, `curl`, `tar`, `unzip`, `gzip`, a C compiler — `unzip` and
  `gzip` are what Mason unpacks its packages with
- `tree-sitter-cli ≥ 0.26.1` **from your system package manager**, not npm
- `ripgrep`, `fd`, `fzf > 0.36`, `bat` (used by fzf-lua's `fzf-native` preview profile)
- A Nerd Font
- Optional but assumed: `lazygit`, `yazi`
- DevOps tooling as needed: `terraform`/`tofu`, `terragrunt`, `kubectl`, `helm`, `ansible`

Language servers and linters install themselves through Mason, at versions
pinned in `lua/plugins/lsp.lua`. `:MasonVersions` prints what is installed, in
the form those lists use.

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

Full terms: [`CONTRACT.md`](./CONTRACT.md) · reasoning:
[`DECISIONS.md`](./DECISIONS.md)

## Safety model

Both own modules do something that is expensive to get wrong — one handles
secrets, the other changes infrastructure. This is what they actually promise.
The distinction between a guarantee and a mitigation is kept deliberately
sharp, because the earlier version of this section claimed more than the code
did.

### `terraform.nvim`

**The saved plan fixes the exact planned action set.** `:TerraformApply`
applies that file and nothing else, so it cannot execute an action set other
than the one written out at plan time.

**The executable is pinned.** The path `terraform`, `tofu` or `terragrunt`
resolved to when the plan was made is recorded and used for the apply. If it is
gone, the apply is refused rather than falling back to whichever of the three
is still on PATH — a terraform plan applied by tofu, or an apply that bypasses
terragrunt, is not the reviewed operation.

**Two independent checks cover credentials**, and they are different layers,
not one feature:

| | Checks | Default |
|---|---|---|
| Environment | `AWS_PROFILE` and the region are recorded with the plan and compared before apply | always on |
| Identity | `aws sts get-caller-identity` — both account ID and principal ARN | `strict_aws_identity`, off |

The environment check catches the ordinary mistake of switching profile between
reading a plan and applying it. It does not catch new static credentials, an
SSO session refreshed against a different account, an edited
`~/.aws/credentials`, the same profile name now assuming a different role, or
credential environment variables, which take precedence over the profile
entirely. Those need `strict_aws_identity`.

With `strict_aws_identity = true`, `aws sts get-caller-identity` runs during
plan and again before apply. Both the account ID and the principal ARN must
match. If identity cannot be verified before an apply whose plan was
identity-bound, the apply is refused. The result is never cached: a cache is a
way of being told which credentials were in effect earlier, which is the thing
being guarded against. It is off by default because it costs a network round
trip on every plan and every apply.

**The reviewed plan is bound to its contents.** A SHA-256 is taken after the
plan file is protected and again after the review window has been shown; they
must match, or the plan is discarded. Before an apply the file is hashed once
more and compared, ahead of the identity lookup and the confirmation prompt —
and again immediately after you confirm, which is what covers the seconds those
two spend waiting on the network and on a person. The digest is read to the end
of the file, not to a size measured beforehand. A difference refuses the apply.
That makes "the bytes applied are the bytes reviewed" exact and catches
accidental replacement — it is not protection
against a hostile process running as you, which could rewrite this plugin just
as easily.

**A plan counts as reviewed only once the review window has actually opened.**
If rendering it fails, the new plan file is deleted and any previously reviewed
plan for that directory is invalidated, so there is nothing left to apply.

**Plan files are cleaned up, as far as a session can do it.** One is removed
after the apply that spent it, when a newer plan supersedes it, when a review
cannot be shown and on `:TerraformDiscard`; the removal is checked rather than
assumed, and a file that stays behind is named so you can remove it yourself. On
exit the runner attempts to remove all reviewed and currently known pending plan
artifacts, including one whose command is still running — terraform writes the
file, so it exists before the callback that records it. What that command writes
after Neovim has gone is out of reach.

**Concurrency.** At most one of planning, applying and initializing per
directory. A running apply refuses a second apply, a new plan, an `init` and a
`discard`; a running `init` refuses a plan, an apply, a second init and a
`validate`; a running plan refuses an `init`. Two overlapping plans are ordered
by when they were requested, not by which finished first. A directory is
claimed before the process starts, and released again by every path that fails
to start one — including the one where starting raises instead of returning,
which happens when the directory has been removed or replaced by a file while
the identity lookup was in flight.

**`:TerraformInit` discards the reviewed plan.** It can bring in a new provider
version, a changed module source or a different backend, and the saved plan was
computed against none of them.

**Asking for a plan invalidates the one you already reviewed** — when you ask,
not when the new plan succeeds. While it runs, an apply is refused; if it ends
in "No changes" or an error, nothing is left to apply. A new plan is a statement
that the old picture is out of date, so the old picture does not outlive it.

**What is not guaranteed.** External infrastructure, credentials and remote
state may still change independently between plan and apply. Terraform itself
detects state drift when the apply runs; this runner does not, and does not
claim to.

### `ansible-vault.nvim`

**Writes are atomic and checked.** A vault is replaced by writing a sibling
file and renaming over the target, so a crash or a full disk leaves the old
contents rather than a truncated file. Symlinks are followed, so the link
survives and the file it points at is what changes.

**Concurrent edits are detected.** Vault buffers carry `noswapfile` and take
over the write, which removes both of Neovim's own protections; a fingerprint
of mtime including nanoseconds, size, inode and device is recorded at read and
compared before write. A file changed — or atomically replaced — underneath the
buffer refuses the write instead of overwriting it.

**Hard links are refused, not broken.** Renaming over one name leaves every
other name for that inode pointing at the old contents. Rather than silently
diverge, the write is refused and says so. `:VaultRekey` is held to the same
policy, where the stakes are higher: `ansible-vault` overwrites the inode before
unlinking it, so through a hard link it destroys what the other name holds
instead of leaving it stale.

**`:VaultRekey` re-encrypts to a configured Vault identity** from
`vault_identity_list`, not to an arbitrary one-off password. A password typed
once cannot be found again by ansible, which would leave a file nothing can
open; with no identity configured the command refuses and says what to set up.

**Converting a plaintext file discards its undo history.** `:VaultEncryptFile`
turns off `'undofile'` and deletes the existing undo file, which would otherwise
keep every earlier state of the buffer — the secret in the clear, under
`stdpath("state")`. If it cannot be deleted the conversion is refused rather
than completed. The safe writer is attached before the buffer changes, so the
first write goes through conflict detection and atomic replacement, and Neovim's
own write — which would back up the plaintext file it replaces — never runs.

**Atomic replacement makes a new file.** The vault is rewritten as a sibling and
renamed over the target, so the result is a new inode with mode 0600. Custom
ACLs, extended attributes, security labels and group ownership are not
guaranteed to survive that. For a secrets file 0600 is the right default, which
is why it is not preserved rather than merged.

**What is kept off disk, exactly.** Decrypted Vault contents are prevented from
being persisted through swap files, persistent undo, the Vault write paths, and
password staging outside the validated runtime directory. A prompted password is
staged in `$XDG_RUNTIME_DIR`, which is checked first — absolute, a directory,
owned by you, mode 0700 — with a private subdirectory inside it; if that check
fails the operation is refused rather than falling back to `/tmp`. Removing that
file is attempted whether the command succeeded, failed or never started, and
the removal is checked rather than assumed; if it cannot be removed you get an
error naming the path. Decrypted
buffers get `noundofile`, `noswapfile` and `nomodeline`. The same
runtime-directory validation guards terraform plan files, which quote variable
values.

**The plaintext appears only once its writer is in place.** Decryption produces
a string first; the buffer is filled after the hardening, the fingerprint and
the write hook are all installed, and the marker saying "this buffer holds
plaintext" is set last of all. A failure anywhere in that sequence leaves the
buffer holding the ciphertext it was opened with. The marker is also cleared
whenever the file is re-read, because `:edit!` brings the ciphertext back while
buffer variables survive, and the writer checks the buffer's actual contents
before re-encrypting them.

**What is outside that guarantee.** Neovim registers, ShaDa, the system
clipboard and external clipboard managers. This configuration sets
`clipboard=unnamedplus`, so ordinary editing — `yy`, `dd`, `dw`, `cw`, `x` —
can put plaintext from a decrypted vault on the system clipboard, and Neovim's
default `'shada'` persists register contents across sessions. `'clipboard'` and
ShaDa are global, not per buffer, so a plugin cannot narrow them to Vault
buffers without deciding how the rest of the editor behaves.

### Stricter workflow

For work where that matters, use a separate session rather than a setting:

```fish
nvim -i NONE secrets.yml
```

`-i NONE` disables reading and writing ShaDa, so registers do not outlive the
session. Drop `clipboard=unnamedplus` for that session too — otherwise yanks and
deletes still reach the system clipboard.

Two things this does not do. It has no control over a clipboard manager, which
may already have taken a copy of anything that reached the clipboard. And an
explicit `"+y` still copies a secret out, because that is the user asking for
it — no session setting turns a deliberate copy into a refused one.

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
