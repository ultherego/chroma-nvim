<div align="center">

<img src="assets/chroma-neovim.png" alt="Chroma Neovim" width="420">

**A Neovim environment for infrastructure work.**

🚀 fast · 🧩 modular · 🔧 easy to extend · 📦 maintained plugins only · 📝 documented · 🎨 Catppuccin Mocha

</div>

---

Chroma Neovim is a ready-to-use Neovim configuration for people who work with
infrastructure from a terminal. It brings the language servers, formatters,
linters, parsers and plugins for:

**Terraform / OpenTofu** · **Kubernetes** · **Helm** · **Ansible** ·
**Ansible Vault** · **AWS** · **Docker** · **GitHub Actions** · **YAML**

It is modular. Each of those is a component you can switch on or off, and the
editor loads only what you chose — a configuration with Kubernetes off installs
no `kubectl.nvim`, enables no `helm_ls`, and compiles no Helm parsers. See
`:help chroma-nvim-components`.

## Requirements

| Dependency | Version |
|---|---|
| Neovim | ≥ 0.12 |
| git | ≥ 2.19 |
| tree-sitter CLI | ≥ 0.26.1, from your package manager rather than npm |
| fzf | ≥ 0.36 |
| ripgrep, fd, bat | any |
| curl, tar, unzip, gzip | any |
| A C compiler | any |

A Nerd Font is recommended. That table is the whole list, and the versions in
it are floors rather than pins — each one is a requirement stated by something
Chroma depends on: lazy.nvim needs partial clones, nvim-treesitter names its CLI
version, fzf-lua names its fzf. Anything newer works.

## External tools

Terraform, OpenTofu, kubectl, Helm, Ansible, the AWS CLI and Docker are **not
installed or managed by Chroma**, and enabling a component does not ask for
them. Choosing Kubernetes asks for Chroma's Kubernetes features — the plugin,
the language server, the schemas, the parser. The `kubectl` those features shell
out to is yours to provide, and Chroma will not install, upgrade or shadow it.

So a missing one never blocks an installation. `chroma install` says at the end
which are not on PATH, `:checkhealth chroma` and `chroma doctor` say it again
whenever you ask, and the feature that needs one tells you when you use it —
which is the moment it matters. If you run OpenTofu rather than Terraform, that
is simply what the Terraform component uses.

What Chroma does pin is its own runtime — plugins, language servers, formatters,
linters and parsers, installed through lazy.nvim and Mason — so that one release
installs the same editor twice. You never have to think about that half.

## Installation

Download `chroma` for your machine from the
[latest release](https://github.com/ultherego/chroma-nvim/releases/latest),
check it against the published `SHA256SUMS`, and run it:

```sh
curl -fsSLO https://github.com/ultherego/chroma-nvim/releases/latest/download/chroma-linux-amd64
curl -fsSLO https://github.com/ultherego/chroma-nvim/releases/latest/download/SHA256SUMS
sha256sum --ignore-missing -c SHA256SUMS
chmod +x chroma-linux-amd64 && sudo mv chroma-linux-amd64 /usr/local/bin/chroma

chroma install
```

It asks where to put the configuration and which components you want, shows the
whole plan, and writes nothing until you agree. In a terminal the questions are
selectors you move through; over a pipe or into a file they are printed and
typed, and `--plain` (or `CHROMA_PLAIN=1`) takes the printed ones in a terminal
too. Nothing else changes with it — the plan you agree to is the same either way.

By default it installs beside whatever Neovim configuration you already have:

```sh
NVIM_APPNAME=chroma-nvim nvim
```

Choosing the other placement takes over Neovim's own directories and keeps what
was there, to be given back if you ever uninstall. Not just `~/.config/nvim`:
Neovim reads `~/.local/share/nvim`, `~/.local/state/nvim` and `~/.cache/nvim`
too, so all four are moved aside and all four are returned — your plugins, your
undo history and your shada included.

There is one managed installation per machine. If Chroma is already installed,
`install` says so and points you at `update`, `components` or `uninstall`
instead of making a second one.

Everything the installer fetches is verified before it is unpacked: the archive
is checked against the checksum published with the release, and unpacking
refuses anything that is not a plain file or directory under the release's own
prefix. Every operation is a transaction — if a step fails, what you had is put
back and the record still describes it.

## Components

A component is one technology's support: its language servers, linters,
formatters, parsers, plugins and schemas. What you did not choose is not
installed and not loaded.

```sh
chroma components                          # choose, starting from what you have
chroma components --set terraform,helm     # or say it outright
```

Changing components does not change which release you are on, and changing
release does not change your components.

## Managing an installation

```sh
chroma doctor      # is the Chroma on this machine healthy, and what is it missing
chroma update      # move to another release, keeping your components
chroma rollback    # go back to the previous one, keeping your components
```

An update keeps the release it replaced, so `rollback` is a local operation
rather than a re-download. Rolling back again returns you to where you were.

## Uninstalling

```sh
chroma uninstall
```

It prints the exact list of paths before it removes anything. What Chroma made
— the configuration, the kept generations, the plugins, the Mason packages, the
parsers, the cache, the state and your component selection — is removed. Anything
that was in Neovim's own directories before Chroma took them over is **given
back**, not deleted, and Chroma refuses to move a directory it cannot show is the
one it was left. External tools and Neovim itself are never touched.

If part of the removal fails, the record stays where it is and says what is left
to finish, so running it again completes the rest rather than starting from a
machine nothing describes.

## Development

The repository is itself a Neovim configuration directory, which is how it is
worked on. This is not the installation route: it skips the release
verification, the transaction, the install state and everything `update`,
`rollback` and `uninstall` depend on.

```sh
git clone https://github.com/ultherego/chroma-nvim.git ~/.config/chroma-nvim
NVIM_APPNAME=chroma-nvim nvim
```

`doc/CONTRACT.md` covers the test suite, the linters and how installations are
tested in a container. `chroma install --source-tree .` installs a checkout
through the real installer, which is how the two are kept honest.

## Troubleshooting

Most of this configuration drives external programs, and when one is missing
the symptom is usually silence rather than an error. `:checkhealth chroma`
reports what is absent, what stops working without it, and which components are
enabled. `chroma doctor` answers the same question from a shell. `:Lazy` and
`:Mason` cover the plugins and the packages.

If something behaves oddly rather than being absent, `:help
chroma-nvim-troubleshooting` lists the cases that have come up before and what
each one turned out to be.

## Documentation

**The keymaps:** [`doc/KEYMAPS.md`](./doc/KEYMAPS.md) — every mapping this
configuration defines, on one page, with the ones it deliberately leaves to
Neovim. A test fails if it and the editor stop agreeing.

**In the editor:** `:help chroma-nvim` — the same keymaps with the reasoning
attached, every component, the safety model of the modules that handle secrets
and run infrastructure commands, and what they do and do not guarantee.

**Why it is like this:** [`doc/DECISIONS.md`](./doc/DECISIONS.md) — the
reasoning behind every choice, and what is deliberately absent.
[`doc/CONTRACT.md`](./doc/CONTRACT.md) — the rules this project is built under.
[`cli/DESIGN.md`](./cli/DESIGN.md) — the installer. All of these are installed
with the configuration, so they are beside `:help chroma-nvim` too.

## License

[MIT](./LICENSE)
