# Keymaps

Every mapping this configuration defines, on one page.

The leader is <kbd>Space</kbd>, so `<leader>fg` is <kbd>Space</kbd> then
<kbd>f</kbd> then <kbd>g</kbd>. The local leader is `\` and nothing uses it.

This is the cheat sheet. `:help chroma-nvim-keymaps` is the same set with the
reasoning attached — why a key is where it is, and what it does not do. A test
holds both to the code, for everything under the leader: each such mapping in
`lua/` appears in both documents, and each one either document names still
exists in `lua/`. The keys that are not under the leader — `]h`, `gsa`, `K`,
the ones inside oil and inside a picker — are held there by reading, which is
why each lives under the plugin that binds it rather than in a list of its own.

Press <kbd>Space</kbd> and wait to have which-key answer this from inside the
editor. `<leader>?` lists what the current buffer adds.

---

## Prefixes

| Prefix | Group | When |
|---|---|---|
| `<leader>f` | Find | always |
| `<leader>p` | Project | always |
| `<leader>g` | Git | always |
| `<leader>l` | LSP | always |
| `<leader>b` | Buffers | always |
| `<leader>w` | Windows | always |
| `<leader>s` | Sessions | always |
| `<leader>x` | Tools | always |
| `<leader>t` | Terraform | component `terraform` |
| `<leader>k` | Kubernetes | component `kubernetes` |
| `<leader>a` | Ansible | component `ansible` or `vault` — see the note under *Ansible Vault* |
| `<leader>A` | AWS | component `aws` |

A prefix is assigned once, globally. A collision is a bug, not an
inconvenience, so the four domain groups are registered only when their
component is enabled rather than left as headings over empty lists.

---

## Find

| Key | Mode | Does |
|---|---|---|
| `<leader>ff` | n | Files |
| `<leader>fg` | n | **Grep — live search across the tree** |
| `<leader>fw` | n | Grep the word under the cursor |
| `<leader>fb` | n | Open buffers |
| `<leader>fo` | n | Recent files |
| `<leader>fh` | n | Help tags |
| `<leader>fk` | n | Keymaps |
| `<leader>fd` | n | Document diagnostics |
| `<leader>fr` | n | Resume the last picker |
| `<leader>fp` | n | Find path — leaves `:FindFile ` on the command line |
| `<leader>fe` | n | File explorer (oil) |
| `<leader>fy` | n, v | Yazi at the current file |
| `<leader>fY` | n | Yazi at the working directory |
| `<leader>ft` | n | Resume the last yazi session |
| `-` | n | oil, one directory up |

`<leader>ff` and `<leader>fp` answer different questions and neither replaces
the other. The first is the fuzzy finder, for when the name is roughly
remembered and the location is not. The second is for a path you already know:
it types the command and stops, and <kbd>Tab</kbd> completes directory by
directory the way it does anywhere else in Neovim.

### Inside a picker

fzf-lua's file actions, several of them moved off Zellij's keys:

| Key | Does |
|---|---|
| <kbd>Enter</kbd> | Open |
| <kbd>Ctrl</kbd>+<kbd>v</kbd> | Open in a vertical split |
| <kbd>Ctrl</kbd>+<kbd>x</kbd> | Open in a horizontal split |
| <kbd>Alt</kbd>+<kbd>.</kbd> | Toggle hidden files |
| <kbd>Alt</kbd>+<kbd>,</kbd> | Toggle ignored files |
| <kbd>Alt</kbd>+<kbd>/</kbd> | Toggle following symlinks |
| <kbd>Alt</kbd>+<kbd>q</kbd> | Selection to the quickfix list |
| <kbd>Alt</kbd>+<kbd>Q</kbd> | Selection to the location list |

### Inside oil

| Key | Does |
|---|---|
| <kbd>Ctrl</kbd>+<kbd>v</kbd> | Open in a vertical split |
| <kbd>Ctrl</kbd>+<kbd>x</kbd> | Open in a horizontal split |
| `gp` | Preview |

oil's own <kbd>Ctrl</kbd>+<kbd>s</kbd>, <kbd>Ctrl</kbd>+<kbd>h</kbd>,
<kbd>Ctrl</kbd>+<kbd>t</kbd> and <kbd>Ctrl</kbd>+<kbd>p</kbd> are switched off
rather than left dead: Zellij takes all four before Neovim sees them.
Everything else oil binds is upstream's.

### Inside yazi

<kbd>F1</kbd> shows yazi's own help. The rest is yazi's.

---

## Project

| Key | Mode | Does |
|---|---|---|
| `<leader>pp` | n | Projects |

---

## Buffers

| Key | Mode | Does |
|---|---|---|
| `<leader>bb` | n | Previous buffer |
| `<leader>bd` | n | Delete this buffer |
| `<leader>bD` | n | Delete it anyway |

---

## Windows

| Key | Mode | Does |
|---|---|---|
| `<leader>ws` | n | Split horizontally |
| `<leader>wv` | n | Split vertically |
| `<leader>wc` | n | Close this window |
| `<leader>wo` | n | Close every other window |
| `<leader>w=` | n | Equalise the sizes |

---

## Tools

| Key | Mode | Does |
|---|---|---|
| `<leader>xr` | n | **Run Task** |
| `<leader>xf` | n, v | Format the buffer or the selection |
| `<leader>xF` | n | Toggle format on save, globally |
| `<leader>xb` | n | Toggle format on save, this buffer |
| `<leader>xi` | n | Formatter info (`:ConformInfo`) |
| `<leader>xl` | n | Lint now |
| `<leader>xt` | n | Todo comments |
| `<leader>xT` | n | Todo comments to the quickfix list |
| `<leader>xs` | n | Shell — a terminal at the bottom, toggled |
| `<leader>xx` | n | Diagnostics, whole workspace |
| `<leader>xX` | n | Diagnostics, this buffer |
| `<leader>xq` | n | Quickfix list |
| `<leader>xL` | n | Location list |

`<leader>xr` reads `.chroma/tasks.json` and runs what the project declares —
which command, from which directory, with which environment. Nothing is
inferred from the buffer.

The first task in a repository takes two steps. Neovim asks about trust,
naming it "exrc"; choose *view*, read the file, leave it, run `:trust` with
**no argument**, and press `<leader>xr` again. Editing the file invalidates the
decision, so the cycle repeats — the trust is in the bytes, not the path. Never
run `:trust <file>`: Neovim's own documentation warns of a TOCTOU risk there
and directs you to view first. The whole flow is `:help chroma-nvim-tasks`,
and the invariants behind it are in `CONTRACT.md`, under *The execution layer*.

`<leader>xs` toggles: snacks identifies a terminal by its command, directory,
environment and count, so the same shell comes back rather than a new one.
A task is the opposite — every run is its own process in its own terminal.

Above 512 KB a buffer is not formatted on save and says so; `<leader>xf` still
formats it, because manual formatting runs asynchronously and is not bound by
the save timeout.

`<leader>xf` refuses exactly one buffer and says why: a decrypted vault. A
formatter is a subprocess handed the buffer, which is not a thing to do with a
plaintext secret. Saving never formats one either — this one says it out loud
because here it was asked for.

---

## Git

| Key | Mode | Does |
|---|---|---|
| `]h` | n | Next hunk |
| `[h` | n | Previous hunk |
| `<leader>gs` | n | Stage the hunk — stages, or unstages one already staged |
| `<leader>gs` | v | Stage the selected lines |
| `<leader>gr` | n | Reset the hunk |
| `<leader>gr` | v | Reset the selected lines |
| `<leader>gS` | n | Stage the buffer |
| `<leader>gR` | n | Reset the buffer |
| `<leader>gp` | n | Preview the hunk inline |
| `<leader>gb` | n | Blame this line, in full |
| `<leader>gB` | n | Toggle inline blame |
| `<leader>gd` | n | Diff against the index |
| `<leader>gg` | n | Lazygit |
| `<leader>gl` | n | Lazygit log |
| `<leader>gf` | n | Lazygit history of this file |
| `<leader>gc` | n | Search commits |
| `<leader>gC` | n | Search commits touching this buffer |
| `ih` | o, x | The hunk, as a text object — `dih`, `vih`, `yih` |

In a diff split `]h` and `[h` fall through to Neovim's own `]c` and `[c`, so
both idioms work in the place where the built-in one is the right answer.

**gitsigns never attaches to a buffer holding a decrypted vault.** Staging
writes the git index rather than the working tree, so `<leader>gS` on such a
buffer would put the plaintext into git, past everything guarding the file.

---

## LSP

| Key | Mode | Does |
|---|---|---|
| `<leader>li` | n | LSP status (`:checkhealth vim.lsp`) |
| `<leader>ls` | n | Document symbols |
| `<leader>lS` | n | Workspace symbols, live |
| `<leader>ld` | n | Document diagnostics |
| `<leader>lm` | n | Mason |
| `<leader>lo` | n | Outline (aerial) |
| `<leader>lt` | n | References and definitions, in a panel |
| `[s` | n | Previous symbol — while aerial is attached |
| `]s` | n | Next symbol — while aerial is attached |

Aerial takes `[s` and `]s` rather than the `{` and `}` upstream suggests: it
attaches to ordinary source buffers, where those are the paragraph motions.

Outline and diagnostics are deliberately two things. `<leader>lo` answers what
is in this file and where; `<leader>xx` answers what is wrong and where.

### What Neovim already provides

None of these is defined here. Neovim 0.12 ships them, and redefining them
means carrying code that does nothing except drift from the editor:

| Key | Does |
|---|---|
| `grn` | Rename |
| `gra` | Code action |
| `grr` | References |
| `gri` | Implementations |
| `grt` | Type definition |
| `K` | Hover |
| `gO` | Document symbols |
| `gcc`, `gc{motion}` | Comment |
| `]d`, `[d` | Next, previous diagnostic |
| `]b`, `[b` | Next, previous buffer |
| `]q`, `[q` | Next, previous quickfix entry |

---

## Sessions

| Key | Mode | Does |
|---|---|---|
| `<leader>ss` | n | Select a session |
| `<leader>sl` | n | Load the session for this directory |
| `<leader>sL` | n | Load the last session |
| `<leader>sw` | n | Save now |
| `<leader>st` | n | Toggle session recording |
| `<leader>sd` | n | Delete this session |

A session is per directory **and per git branch**: infrastructure repositories
tend to keep one branch per environment.

---

## Terraform, OpenTofu, Terragrunt

Component `terraform`.

| Key | Mode | Does |
|---|---|---|
| `<leader>ti` | n | Init |
| `<leader>tv` | n | Validate |
| `<leader>tp` | n | Plan |
| `<leader>ta` | n | Apply the reviewed plan |
| `<leader>td` | n | Discard the reviewed plan |

`q` closes an output window.

**`apply` applies a file, never a fresh plan**, and the plan it applies is the
one that was on screen. There is no `-auto-approve` anywhere, and destroy has
no mapping on purpose: `:TerraformPlanDestroy` produces a plan to read like any
other, and its confirmation requires typing `destroy` — `yes` is rejected.

---

## Kubernetes

Component `kubernetes`.

| Key | Mode | Does |
|---|---|---|
| `<leader>kk` | n | Toggle the cluster view |
| `<leader>kt` | n | The cluster view in a new tab |
| `<leader>kx` | n | Switch context |
| `<leader>kn` | n | Switch namespace |

Inside a `k8s_*` buffer, three of kubectl.nvim's defaults are moved because
Zellij captures the originals:

| Key | Does |
|---|---|
| <kbd>Ctrl</kbd>+<kbd>e</kbd> | Picker view — upstream's <kbd>Ctrl</kbd>+<kbd>p</kbd> |
| `gn` | Namespace view — upstream's <kbd>Ctrl</kbd>+<kbd>n</kbd> |
| `gH` | Toggle headers — upstream's <kbd>Alt</kbd>+<kbd>h</kbd> |

---

## AWS

Component `aws`.

| Key | Mode | Does |
|---|---|---|
| `<leader>Ap` | n | Pick a profile |
| `<leader>Ar` | n | Pick a region |
| `<leader>As` | n | What profile and region are set |
| `<leader>Aw` | n | Who these credentials are (`sts get-caller-identity`) |
| `<leader>Ac` | n | Restore the environment Neovim started with |

These set `AWS_PROFILE` and `AWS_REGION` on the Neovim process, so every
subprocess inherits them — the Terraform runner included, which is why a plan
records the profile it was made under and refuses an apply under another.

---

## Ansible

Component `ansible`, which requires only `core`.

| Key | Mode | Does |
|---|---|---|
| `<leader>ar` | n | Plan and run an Ansible playbook |
| `<leader>aR` | n | Repeat the last Ansible invocation |

`<leader>ar` asks for the playbook, the working directory, the inventory
sources, tags, a limit and the CLI overrides, then shows the exact argument
vector and asks once. Nothing runs before that yes, and Ansible is only started
after a separate consent naming the directory, playbook and inventory it is
about to use.

An inventory source is resolved against the frozen working directory as you
type it, and one that is not there is refused on the spot, naming the full path
Ansible would have opened. Ansible would not have refused it: a missing `-i` is
a warning, an inventory of nothing, and a run that reports `skipping: no hosts
matched` and exits green.

`<leader>aR` goes straight to that final preview with the last invocation's
decisions and still asks. It re-resolves `ansible-playbook` and re-checks the
paths, and it never repeats the previous run's host count — an inventory can
have changed since.

Both are also `:AnsibleRun` and `:AnsibleRepeat`.

**`<leader>ar` was removed once, in `568c28e`, and this is not that key coming
back.** The old one inferred the playbook and the command from the current
buffer. This one infers nothing: the buffer is offered as one row in a picker,
and every part of the invocation is chosen and then shown before it runs.

---

## Ansible Vault

Component `vault`, which requires only `core`.

| Key | Mode | Does |
|---|---|---|
| `<leader>av` | n | Reveal the `!vault` value under the cursor |
| `<leader>av` | v | Encrypt the selection in place |
| `<leader>aV` | n | Where the vault password comes from |
| `<leader>ae` | n | Encrypt the whole file |
| `<leader>ad` | n | Decrypt the whole file |
| `<leader>aw` | n | View an encrypted file without decrypting it on disk |
| `<leader>ak` | n | Rekey an encrypted file |

`q` or <kbd>Esc</kbd> closes a revealed value.

**The group heading follows either component.** These seven keys belong to
`vault` and the two above belong to `ansible`, and the two components are
independent, so the heading appears when either is enabled — labelled *Ansible*
either way, because Ansible Vault is Ansible's. It used to follow `ansible`
alone while every key under it came from `vault`, which was wrong in both
directions: `vault` on and `ansible` off gave seven working keys and no
heading, and the reverse gave a heading over nothing. It was then gated on
`vault` alone, which was right for exactly as long as `ansible` contributed no
key of its own.

---

## Ansible files

`nvim-ansible` has **no mapping for running a playbook**, and that is a removal
rather than an omission: the one it had inferred the playbook from the buffer,
and inference is what was retired, not the running.

There are two ways to run a playbook and neither guesses. `<leader>ar` plans
one: every part is chosen, then shown, then confirmed. `<leader>xr` runs the
command the repository declared in `.chroma/tasks.json`, which is the way to
reach a wrapper — `make`, `uv run`, a company CLI — since the planner starts
`ansible-playbook` itself and nothing else.

What the plugin still provides:

| Key | Where | Does |
|---|---|---|
| `K` | `yaml.ansible` | Module documentation through `ansible-doc` |
| `gf` | a role or path | Jump to it, through an extended `'path'` |

---

## Editing

| Key | Mode | Does |
|---|---|---|
| `<leader>p` | v | Paste over the selection without losing the yank |
| `J` | v | Move the selection down, reindenting |
| `K` | v | Move the selection up, reindenting |
| `<` | v | Shift left and stay in visual mode |
| `>` | v | Shift right and stay in visual mode |

`J` and `K` are visual-mode only. Normal-mode `J` still joins lines and normal
mode `K` is still hover.

### Surround

mini.surround, on `gs` rather than the default `s`, which would shadow a
perfectly good built-in in both normal and visual mode. Vim's `gs` means
"sleep for N seconds", which nobody misses.

| Key | Mode | Does |
|---|---|---|
| `gsa` | n, v | Add surrounding |
| `gsd` | n | Delete surrounding |
| `gsr` | n | Replace surrounding |
| `gsf` | n | Find surrounding, to the right |
| `gsF` | n | Find surrounding, to the left |
| `gsh` | n | Highlight surrounding |

### Completion

blink.cmp, with two of its keys moved because Zellij eats
<kbd>Ctrl</kbd>+<kbd>n</kbd> and <kbd>Ctrl</kbd>+<kbd>p</kbd>. The originals
are still mapped and work perfectly well outside Zellij:

| Key | Does |
|---|---|
| <kbd>Ctrl</kbd>+<kbd>j</kbd> | Next item — added here |
| <kbd>Ctrl</kbd>+<kbd>k</kbd> | Previous item — added here |
| <kbd>Ctrl</kbd>+<kbd>l</kbd> | Signature help — moved here, since `<C-k>` was taken |
| <kbd>Ctrl</kbd>+<kbd>d</kbd> | Scroll the documentation down — added here |
| <kbd>Ctrl</kbd>+<kbd>u</kbd> | Scroll the documentation up — added here |
| <kbd>Ctrl</kbd>+<kbd>y</kbd> | Accept |
| <kbd>Ctrl</kbd>+<kbd>Space</kbd> | Show, then toggle the documentation |
| <kbd>Ctrl</kbd>+<kbd>e</kbd> | Cancel |
| <kbd>Ctrl</kbd>+<kbd>b</kbd>, <kbd>Ctrl</kbd>+<kbd>f</kbd> | Scroll the documentation |
| <kbd>Ctrl</kbd>+<kbd>n</kbd>, <kbd>Ctrl</kbd>+<kbd>p</kbd> | Next, previous item |
| <kbd>Tab</kbd>, <kbd>Shift</kbd>+<kbd>Tab</kbd> | Forward, back through a snippet |

Everything from <kbd>Ctrl</kbd>+<kbd>y</kbd> down is blink's `default` preset,
unchanged, and is listed because it is reachable rather than because it is
configured here.

---

## Which-key

| Key | Mode | Does |
|---|---|---|
| `<leader>?` | n | What this buffer adds |

---

## Dashboard

Single letters, on the start screen only. Each runs a mapping from this page,
so the dashboard cannot drift from the rest of it.

| Key | Does |
|---|---|
| `f` | Find file — `<leader>ff` |
| `g` | Grep — `<leader>fg` |
| `r` | Recent files — `<leader>fo` |
| `p` | Projects — `<leader>pp` |
| `e` | File explorer — `<leader>fe` |
| `c` | Open the configuration |
| `l` | Lazy |
| `m` | Mason |
| `q` | Quit |

---

## Things with no mapping, deliberately

| Command | Why |
|---|---|
| `:TerraformPlanDestroy` | A destroy button is a thing to press by accident; a destroy *plan* is a thing to read |
| `:VaultEncrypt` | The visual-mode `<leader>av` is the form that has a selection to act on |
| `:VaultView`, `:VaultRekey` | Mapped, above — the commands exist for scripting and for `:h` |
| `:Lint` | `<leader>xl` is the mapping; the command is what CI and a script use |
| `:MasonVersions` | Prints pinned versions in the form the lists use; run when bumping them |
| `:FindFile` | Mapped to `<leader>fp`, which types it and stops |
| `:checkhealth chroma` | Asked when something is wrong, not on a key |

---

## What is not here

Upstream defaults of plugins this configuration does not reconfigure — every
mini.ai text object, the whole of lazygit, everything yazi binds inside itself.
Those belong to their own documentation. What this page promises is that
everything **Chroma** defines or deliberately relies on is on it, and a test
fails if that stops being true.
