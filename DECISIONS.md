# Decisions

`CONTRACT.md` says what this configuration is. This says **why** — and, just as
often, why something is deliberately absent.

It exists because the expensive question about a configuration is never "what
does this line do". It is "why is it like that, and what breaks if I change
it". Six months from now that answer is gone unless it was written down.

Every entry follows the same shape: the decision, the reasoning, and what would
change it. If a decision has no answer to the last part, it is dogma, not a
decision.

---

## Contents

- [Working method](#working-method)
- [Baseline](#baseline)
- [Language servers](#language-servers)
- [Editing](#editing)
- [Keymaps and the terminal](#keymaps-and-the-terminal)
- [Our own modules](#our-own-modules)
- [Secrets](#secrets)
- [Infrastructure commands](#infrastructure-commands)
- [Testing and CI](#testing-and-ci)
- [Deliberate omissions](#deliberate-omissions)

---

## Working method

### Nothing is written from memory

**Decision.** For every plugin: read the current documentation, check for
breaking changes, then configure. No exceptions, including for plugins that
seem too simple to need it.

**Why.** This is the whole reason the project exists. Configurations written
from memory keep targeting APIs that no longer exist. In this repository's own
history, each of the following would have been written wrong:

| From memory | Reality |
|---|---|
| `require('lspconfig').X.setup{}` | deprecated, will become an error |
| `require('nvim-treesitter.configs').setup{}` | module does not exist on the `main` branch |
| `mason-lspconfig` `setup_handlers()` | removed in v2 |
| gitsigns `next_hunk`, `undo_stage_hunk` | deprecated |
| `TroubleToggle` | removed in v3 |
| `colorscheme catppuccin` | loads Neovim 0.12's own built-in, not the plugin |

That last one is the instructive case: it fails **silently**. The colours are
almost right and you lose a week.

**What would change it.** Nothing. The rule is cheap and the failures it
prevents are not.

### Claims are measured, not asserted

**Decision.** Where a belief can be tested, test it before writing it into a
comment.

**Why.** Comments that describe intent rather than behaviour are worse than no
comments, because they are trusted. Real examples from this repository, all
found by running something rather than reading it:

- A comment said plan files were `0600`. Terraform creates them under the
  ambient umask; they were `0644`.
- A comment said `backup` and `writebackup` were disabled per buffer. They are
  global options — the code could not have done it and did not.
- A comment said credentials were deliberately not passed to `ansible-vault`.
  The function passed them.
- `:VaultDecryptFile` announced "it will be re-encrypted on write" and did not
  attach the hook that makes that true.
- `:VaultEncrypt` claimed to encrypt the visual selection. It read the `'<` and
  `'>` marks, which outlive the selection that set them, so from normal mode it
  encrypted whatever had been selected earlier — leaving the value you meant to
  protect in the clear.

Each of those read as correct. None survived being exercised.

**What would change it.** Nothing.

### A fix is tested through its callers, not at the point of change

**Decision.** After changing a function's signature or an option's meaning,
exercise the code that *uses* it. Re-running the thing you just edited proves
nothing about the things that call it.

**Why.** Two of the four defects found while auditing this repository's own
modules were introduced by earlier fixes in it:

- `auth_for` was changed to resolve ansible.cfg from the buffer's directory,
  and all eight call sites were updated to pass a buffer. The function still
  took a directory. Every vault operation then handed a buffer number to
  `vim.system` as its working directory — encrypt, decrypt, reveal and
  transparent editing were all broken. It survived because the only thing
  re-tested afterwards was `:VaultStatus`, which does not go through
  `auth_for` at all.

- `transparent = false` was found not to disable transparent editing. Every
  earlier test that claimed to exercise that path had run with it enabled, so
  a security fix that looked verified was not.

Both changes were tested. Both tests looked green. Neither touched the path
that broke.

**What would change it.** Nothing. It costs one extra run.

### Assert on state, not on observed behaviour

**Decision.** Where a test can check that something is *registered*, *set* or
*absent*, prefer that over checking that the outcome looks right.

**Why.** The `transparent = false` bug is the case in point. Behaviour looked
correct — files opened decrypted, writes came back encrypted, no plaintext
reached disk — and every one of those observations was true for the wrong
reason: the automatic reader was doing the work the disabled path was credited
with. Counting the registered autocmds found it in one line.

Observed behaviour cannot distinguish "this works" from "something else
happens to be covering for it".

**What would change it.** Nothing.

### Report what was checked and found fine

**Decision.** An audit report lists the paths that turned out correct
alongside the ones that did not.

**Why.** Reporting only findings makes a codebase look worse than it is and
hides how much was actually examined. Of the twelve paths exercised in the
last round, eight were correct and two suspicions — an unbounded `generation`
table, the same file in two buffers — turned out not to be problems at all.
That is as much a result as the four defects.

### Survey before building

**Decision.** Before writing a custom plugin, look at what exists and judge it
on activity, licence, documentation and fit.

**Why.** A worse plugin somebody else maintains beats a better one only you
maintain. Applying this removed three planned modules and one planned
dependency:

- `kube.nvim` → `kubectl.nvim` already did all of it and more
- `lazygit.nvim` → the `snacks` module themes lazygit from the colourscheme
- `alpha` → the `snacks` dashboard, already a dependency
- `terraform.nvim` shrank from six commands to a plan/apply runner, because
  formatting and validation were already covered elsewhere

**What would change it.** A gap the survey shows is real. That is how
`ansible-vault.nvim` and the AWS module were justified: every candidate was a
single-person project with under ten stars, the most visible abandoned since
2023.

---

## Baseline

### Neovim 0.12, not "latest stable"

**Decision.** Target 0.12 explicitly, in the docs and in CI.

**Why.** 0.12 is not a minor bump. It brings the native LSP API
(`vim.lsp.config` / `vim.lsp.enable`), which makes the entire pre-0.11
configuration style obsolete, and it is the version nvim-treesitter's rewritten
`main` branch targets. Pinning CI to `stable` would let a future major change
break the config on somebody's machine rather than in a workflow run.

**What would change it.** A 0.13 that is verified against, not assumed
compatible with.

### Neovim's own defaults are not re-implemented

**Decision.** Do not map what the editor already maps.

**Why.** 0.12 ships `gc`/`gcc`, `]d`/`[d`, `]b`/`[b`, `]q`/`[q`, `<C-l>`, and
the LSP set `K`, `grn`, `gra`, `grr`, `gri`, `grt`. Most configurations still
define all of these by hand, which means carrying code that does nothing except
diverge from the editor over time.

This is why `lua/config/keymaps.lua` is short. It is not minimalism; it is that
there is little left to do.

**What would change it.** Nothing, though the list needs re-checking each
release.

---

## Language servers

### Configuration goes through `after/lsp/`, not `vim.lsp.config()` calls

**Decision.** Per-server settings live in `after/lsp/<server>.lua`.

**Why.** Neovim resolves LSP settings by merging, in order: `vim.lsp.config('*')`,
`lsp/<name>.lua` from the runtimepath (nvim-lspconfig's own), then
`after/lsp/<name>.lua`, then explicit `vim.lsp.config('<name>')` calls.

Using `after/lsp/` means changing one setting changes one setting. Everything
upstream provides stays. Verified: `after/lsp/yamlls.lua` adds 1321 SchemaStore
schemas while upstream's formatting and disabled telemetry survive untouched.

Writing `vim.lsp.config('yamlls', {...})` instead would sit at the highest
priority and quietly replace parts of what nvim-lspconfig ships.

**What would change it.** A setting that genuinely must override everything.

### `automatic_enable` is an explicit list

**Decision.** Name the servers rather than enabling everything Mason has.

**Why.** `automatic_enable = true` enables every server Mason has ever
installed, including one added by hand for an unrelated project months ago.
That widens what runs with no change to this repository, and can produce
duplicate diagnostics from competing servers.

Naming them makes the set a property of the configuration rather than of a
directory's contents.

**What would change it.** Nothing. Adding a server is one line.

### `tflint` runs as a language server, not as a linter

**Decision.** It is in `automatic_enable`, and deliberately **not** registered
with nvim-lint.

**Why.** tflint ships an LSP mode and nvim-lspconfig exposes a config for it,
so installing it as a Mason tool already starts it as a server. Registering it
in both places reports every finding twice.

**What would change it.** tflint dropping its LSP mode.

### `stylua` is excluded from `automatic_enable`

**Decision.** Installed as a formatter, explicitly not enabled as a server.

**Why.** Same mechanism as tflint, opposite conclusion: stylua also has an
`--lsp` mode, and without the exclusion it attaches to every Lua buffer and
competes with conform for formatting. Verified before excluding it.

### Helm needs a filetype plugin to work at all

**Decision.** `vim-helm` is installed despite being a syntax plugin with a
ten-month-old last commit.

**Why.** Neovim does not detect the `helm` filetype — a template beside
`Chart.yaml` is seen as plain YAML. `helm_ls` only attaches to `helm`, so
without detection it never starts, and `yamlls` instead tries to parse Go
templates as YAML and fills the file with errors.

**What would change it.** Neovim detecting the filetype, or a maintained
alternative.

---

## Editing

### Treesitter highlights and folds, but does not indent

**Decision.** `vim.treesitter.start()` and `foldexpr`, no `indentexpr`.

**Why.** Neovim ships mature indent scripts for every language that matters
here — yaml, terraform, hcl, json, lua, bash, python and go all have one in
`$VIMRUNTIME/indent`. Treesitter indentation is still described upstream as
experimental. Trading a known-good implementation for an experimental one is a
bad trade, and YAML is where it goes wrong first.

**What would change it.** Treesitter indentation losing the experimental label,
and a side-by-side comparison on real manifests.

### One icon provider

**Decision.** mini.icons, with `mock_nvim_web_devicons()` for plugins that ask
for the other one by name.

**Why.** Two icon providers means two sets of icons for the same filetypes and
twice the startup cost. The mock is the documented way to satisfy plugins that
hard-code the older name.

### Formatting falls back to the language server, except where it cannot

**Decision.** `lsp_format = "fallback"`, with no dedicated formatter for YAML,
Helm or Dockerfiles.

**Why.** Verified by reading `documentFormattingProvider` off each attached
client:

| Server | Formats |
|---|---|
| yamlls | yes |
| dockerls | yes |
| helm_ls | **no** |

So YAML and Dockerfiles are genuinely covered, and Helm templates are formatted
by nothing — which is the right answer anyway, since no YAML formatter can
safely handle Go templates interleaved with YAML.

The fallback does **not** rescue a missing binary. `terraform_fmt` needs the
terraform CLI, and terraform-ls is not a substitute: it shells out to
`terraform fmt` itself and answers "Terraform (CLI) is required". Terraform
files stay unformatted until the binary is on PATH. That is a machine
prerequisite, and `:checkhealth devops` reports it.

### Large files are not formatted on save, and say so

**Decision.** Above 512 KB, `format_on_save` skips and notifies. `<leader>xf`
still formats them.

**Why.** `format_on_save` is synchronous and bounded by `timeout_ms`. Past that
conform abandons the work — with no message. Measured: a 900 KB YAML took just
over a second through yamlls and saved completely unformatted, with nothing to
indicate it. Believing a file was formatted when it was not is worse than
knowing it was not.

The threshold sits below where that starts happening rather than being a round
number chosen for looks. Manual formatting runs async and is not bound by the
timeout at all.

**What would change it.** A formatter fast enough that the ceiling stops
mattering.

### GitHub Actions workflows keep the plain `yaml` filetype

**Decision.** actionlint is selected by path, not by giving workflows their own
filetype.

**Why.** A dedicated filetype would take them out of `yamlls`'s filetype list
and cost the schema validation that is most of the value of editing a workflow
in an editor. Matching `.github/workflows/*.yml` keeps both.

### Linters are split into fast and slow

**Decision.** yamllint and hadolint run on leaving insert mode; ansible-lint and
actionlint run on write and on demand only.

**Why.** Spawning ansible-lint on every `InsertLeave` is a noticeable drag on a
large role. The split keeps quick feedback quick without paying for the slow
tools continuously.

---

## Keymaps and the terminal

### Zellij takes keys before Neovim sees them

**Decision.** Plugin defaults that land on captured keys are remapped, not left
in place.

**Why.** Zellij's defaults bind mode switches to plain control keys in a
`shared_except "locked"` block, so they are intercepted while you type into
Neovim: `Ctrl-g q h o b s t p n`, plus most of `Alt`. Without remapping, eleven
mappings across oil, fzf-lua and blink.cmp would do nothing at all — including
next and previous completion item — with no error to explain why.

Silent breakage is worse than loud breakage. These remaps make it loud by
making it work.

**What would change it.** Not using Zellij. The remaps stay harmless in that
case; the upstream keys mostly work alongside them.

### Surround is on `gs`, not `s`

**Decision.** `gsa` / `gsd` / `gsr` rather than mini.surround's default `sa` /
`sd` / `sr`.

**Why.** The default prefix shadows Neovim's built-in `s` in normal *and*
visual mode. `s` is a perfectly good key. Vim's `gs` means "sleep for N
seconds", which nobody misses.

### `]t` and `[t` are left alone

**Decision.** todo-comments is reached through the picker, not through the
bracket motions upstream suggests.

**Why.** `]t` and `[t` are Neovim 0.12 defaults for tag navigation. Verified:
`]t` still resolves to `:tnext`.

### Aerial does not take `{` and `}`

**Decision.** `[s` and `]s` instead of upstream's example.

**Why.** `{` and `}` are paragraph motions, and aerial attaches to ordinary
source buffers — taking them would remove a core movement everywhere the
outline is active.

---

## Our own modules

### Each is a plugin, not a file in a shared namespace

**Decision.** `lua/ansible-vault/`, `lua/terraform/`, `lua/aws/` — each
self-contained, depending on nothing else in this configuration.

**Why.** The contract originally planned `lua/devops/ansible.lua` and friends.
Written that way they would be inseparable from this config. Written as plugins
they can be lifted into their own repositories without edits, which is the
stated goal for `ansible-vault.nvim`.

`lua/devops/` kept only what is genuinely about this configuration rather than
about a tool: the health check.

### The runtime-directory check is duplicated on purpose

**Decision.** `lua/ansible-vault/runtime.lua` and `lua/terraform/runtime.lua`
are the same policy written twice. An external audit asked for one shared
`lua/devops/runtime.lua` used by both. It was not taken.

**Why.** Both modules write short-lived secrets into `$XDG_RUNTIME_DIR` and
both must check it is what the XDG specification says it is. A shared helper
would be correct in any codebase where these files stay together — and would
end the one property the decision above exists to protect, since neither module
could then be lifted into its own repository without editing it. Thirty lines
of duplicated policy is a smaller price than that.

The cost is real and is not pretended away: two copies can drift. The check for
that is a test that runs every case against both and asserts they agree, which
is what catches a change made in one and forgotten in the other.

### External tools are asked, not re-implemented

**Decision.** `ansible-config dump` resolves vault settings;
`aws configure list-profiles` lists profiles; regions come from the account.

**Why.** Ansible's configuration precedence (`ANSIBLE_CONFIG`, `./ansible.cfg`,
`~/.ansible.cfg`, `/etc/ansible/ansible.cfg`) changes between releases.
Re-implementing it is a guess with a long shelf life. The AWS CLI already
understands config files, credentials files, SSO sessions and
`AWS_CONFIG_FILE`.

A hardcoded region list is wrong the day AWS opens a region.

**What would change it.** Those commands becoming unavailable — in which case
the modules should fail visibly, not guess.

### `:checkhealth devops` instead of scattered guards

**Decision.** One health module rather than `vim.fn.executable()` checks at
every call site.

**Why.** Most of this configuration drives external programs, and their absence
shows up as *silence*, not as an error: no terraform means formatting does
nothing; no bat means previews are blank. Guarding every call site would
scatter the same three lines across a dozen files and still not tell the user
what is missing overall.

Run against the machine this was built on, it immediately reported the two gaps
that had been found by hand: no terraform CLI, no kubeconfig.

---

## Secrets

### Plaintext never appears in a process argument

**Decision.** `ansible-vault encrypt_string` reads the value from stdin.

**Why.** It also accepts the string as a positional argument, which publishes
the secret to anyone running `ps`. Verified that stdin works, and that is the
only path used.

Ciphertext is treated as public, because it is — which is what frees stdin for
the plaintext.

### Plaintext never reaches the undo file

**Decision.** Buffers holding decrypted content get `noundofile`, `noswapfile`,
and — for scratch views — `buftype=nofile`, `bufhidden=wipe`.

**Why.** This configuration enables `undofile` globally. Without this, a
revealed secret would be written verbatim to `stdpath("state")/undo` and
outlive the session — a plaintext copy of the vault that nobody thinks to look
for.

Verified after a full encrypt/edit/write/reopen cycle by searching for a known
secret: nothing in the undo directory, nothing under `stdpath("state")`,
nothing beside the file.

### The write hook is a security requirement, not a convenience

**Decision.** `attach_writer` is attached after *any* decryption, including
manual, and lives outside the transparent-editing option.

**Why.** It was originally attached only by the automatic reader. With
`transparent = false`, or after a failed auto-decrypt, `:VaultDecryptFile`
followed by `:w` wrote the secret to disk under the vault's own name — while
telling the user the opposite.

It also removes the need to touch `backup`/`writebackup`: taking over
`BufWriteCmd` means Neovim's backup machinery never runs for the buffer. Those
options are global and cannot be set per buffer at all.

### There is one write path, not two

**Decision.** Every write this plugin performs goes through a single `persist`
helper: conflict check, atomic replacement, error handling, bookkeeping.

**Why.** There were two. The writer had a second branch, for buffers holding
ciphertext rather than plaintext, that called `vim.fn.writefile` directly — no
change detection, no atomicity, no check of the return value, and
`modified = false` set regardless. It ran after `:VaultEncryptFile`, which is
precisely when the buffer holds a vault.

A second path is not a shortcut, it is a copy of the safety rules that nobody
maintains. Merging them means a guard cannot be added to one and forgotten in
the other.

### One write hook per buffer

**Decision.** `attach_writer` clears any existing `BufWriteCmd` for the buffer
before creating one.

**Why.** It is called on every decrypt, and a buffer is decrypted again on
every `:edit!`. Without clearing, each reload added another hook, so one
`:write` ran the whole encrypt-and-persist sequence once per reload.

### Vault writes are atomic

**Decision.** Write to a sibling temp file, check the length, fsync, rename.

**Why.** Opening the target with `"w"` truncates it before the first byte is
written. An interruption between those moments destroys the vault. The previous
version also ignored the return values of `fs_write` and `fs_close` while
reporting success, so a half-written vault would have been announced as saved.

### Prompted passwords go to tmpfs, or nowhere

**Decision.** `$XDG_RUNTIME_DIR`, mode 0600, unlinked immediately. If that
variable is unset, refuse.

**Why.** Ansible only accepts a password as a *file*, so something has to be
written. `$XDG_RUNTIME_DIR` is tmpfs and user-only, so it never reaches
persistent storage. Falling back to `/tmp` would quietly do the thing this
module exists to avoid.

This is not a compromise ansible itself avoids: a vault password file on disk
is the normal, documented setup.

### Writes follow symlinks

**Decision.** The atomic write resolves the path before renaming onto it.

**Why.** `rename()` replaces whatever name it is given. Handed a symlink it
deletes the link and leaves a regular file, while the file the link pointed at
keeps its old contents — the write appears to succeed and the real vault
silently stays stale. Shared secrets linked into `group_vars` are a common
enough layout for this to matter. Verified before and after.

Hard links are not covered: `rename` breaks those too, and detecting them would
mean writing in place, which is exactly what the atomic write exists to avoid.

### Concurrent edits are detected, since the usual protections were removed

**Decision.** The file's mtime and size are recorded when it is decrypted and
compared before every write.

**Why.** Hardening these buffers removed both of Neovim's defences against two
editors clobbering each other. `noswapfile` takes away the "found a swap file"
warning, and taking over the write with `BufWriteCmd` bypasses the "file has
changed since editing started" check. Verified that a second writer landing
between read and write had its change silently overwritten.

Recording the state at read restores the protection without a swap file full of
plaintext. The remembered state is refreshed after each successful write —
without that the guard fires on the next save and the buffer becomes
unsaveable, which is a worse failure than the one it prevents. That mistake was
made and caught in testing.

### Registers and `shada` are out of scope, and said so

**Decision.** Yanking a revealed secret puts it in a register, and `shada`
persists registers between sessions. The plugin does not prevent this.

**Why.** A plugin cannot own the user's registers without breaking normal
editing. What it can do is say so plainly rather than implying a completeness
it does not have. `:help devops-nvim-vault-safe` documents it, along with the
one-line `shada` change that closes it for anyone who wants that trade.

---

## Infrastructure commands

### `apply` applies a file, never a fresh plan

**Decision.** `plan` writes to a file and shows it; `apply` applies that file.
No `-auto-approve`, anywhere.

**Why.** Terraform documents that passing a saved plan means it "performs the
operations in the saved plan without prompting you for confirmation" — the file
*is* the approval. So apply cannot execute anything other than what was on
screen. Drift between reading and applying becomes structurally impossible
rather than merely unlikely.

### Destroy is not a separate command with a scarier name

**Decision.** `:TerraformPlanDestroy` produces a plan to read like any other,
applied through the same step. Its confirmation requires typing `destroy`;
`yes` is rejected. It has no key mapping.

**Why.** A dedicated destroy button is a thing to press by accident. A destroy
*plan* is a thing to read. Requiring the word means the confirmation cannot be
answered by reflex.

### A plan is bound to the credentials it was made under

**Decision.** `AWS_PROFILE` and the region are recorded with the plan and
compared before apply. A difference refuses the apply.

**Why.** The plan file fixes *what* terraform will do. It does not fix *who* it
does it as — credentials come from the environment, which the AWS module
changes on the Neovim process. Planning against production, switching profile,
then applying would carry out the reviewed operations against the other
account.

This compares environment, not identity: it does not ask STS who the
credentials resolve to, because that is a network round trip on every plan.
`:AwsWhoami` answers that when it matters.

**What would change it.** Making the STS call cheap enough — cached per
profile, perhaps — to include in the comparison.

### Concurrent plans cannot overwrite each other

**Decision.** Each plan claims a generation; a callback whose generation is
stale discards its own file and returns.

**Why.** `vim.system` callbacks arrive in completion order, not start order. A
slower earlier plan could overwrite the newer one that had just been read, and
apply would then execute something other than what was on screen — breaking the
one guarantee the module exists to make.

### Command output never steals the cursor

**Decision.** The plan and apply windows open without taking focus.

**Why.** They open from an async callback. A plan can take a minute, and the
natural thing to do meanwhile is edit another file — at which point a split
that grabs the cursor sends your keystrokes into a non-modifiable scratch
buffer with no warning. Verified that it did exactly that before the change.

The output is visible either way; `q` closes it once you move to it.

### Plan files are tightened after terraform writes them

**Decision.** `chmod 0600` as soon as the file exists.

**Why.** Terraform creates the file itself, under the ambient umask; it came
out `0644` in testing. A plan can quote sensitive variable values, and
world-readable is the wrong default for that. It cannot be pre-created with the
right mode because terraform replaces it.

---

## Testing and CI

### Only our own code is tested

**Decision.** 26 cases covering the modules in `lua/`, and nothing covering
plugin configuration.

**Why.** There is no value in testing that conform formats Lua — conform has
its own tests. What is worth testing is code written here, at the points where
being wrong is expensive: parsing another tool's output, recognising an
encrypted block, detecting credential drift, detecting overriding credentials.

The suite loads mini.test and `lua/` only, not the configuration, so it
finishes in under a second and a failure cannot be somebody else's plugin.

**Verified to have teeth.** Deleting the region comparison in
`context_differs` — the exact gap an audit found — fails exactly one case with
a readable message. A suite that only ever passes proves nothing.

### Integration tests exist because the unit tests missed everything

**Decision.** A second suite drives the real `ansible-vault` CLI through
encrypt, decrypt, transparent editing, symlinks and concurrent writes.

**Why.** All seven defects found in these modules were in integration paths: a
signature that no longer matched its callers, a write hook that was never
attached, an option that disabled nothing, a rename that ate a symlink. The
unit tests cover pure functions and would not have caught a single one.

Each case reproduces one of those failures, so a regression turns a test red
rather than putting a secret on disk in the clear. Verified by mutation:
reverting the symlink fix fails exactly one case.

They skip when ansible is absent, so the suite still runs on a machine without
it — and CI installs ansible, because skipping there would quietly remove the
cover they exist to provide.

**What would change it.** Nothing.

### CI pins everything it runs

**Decision.** Actions by full commit SHA, fixed versions for stylua, selene and
tree-sitter-cli, Neovim pinned to the targeted version.

**Why.** A tag is a moving pointer the action's owner can repoint at any time —
a credential-shaped hole in a workflow that holds a token. Fixed tool versions
mean an upstream release cannot turn a green branch red without a commit here.
Pinning Neovim means a major bump fails in CI instead of on somebody's machine.

The readable tag stays in a comment so the pin can be audited without a lookup.

### selene has a minimal standard library

**Decision.** `vim.yml` declares `vim`, `jit` and `MiniTest` as opaque globals
rather than describing the Neovim API.

**Why.** A generated description of the whole API would go stale silently —
exactly the drift this project exists to avoid. Real API checking is the
language server's job, and lua_ls already does it in the editor. selene is here
for undefined variables, shadowing and unreachable code, which this is enough
for.

---

## Deliberate omissions

Things a reader might expect and will not find.

### No statusline plugin

The contract never listed one and nothing has needed it. Neovim's default
statusline carries the file, position and modified flag; the information a
plugin would add — git branch, diagnostics count — is already one keystroke
away in `:Trouble` and lazygit.

**What would change it.** Wanting something the default cannot show at all.

### No bufferline or tabline

Buffers are reached through `<leader>fb` and `]b`/`[b`; tabs belong to Zellij in
this workflow. A tabline would be a second, worse tab bar above the real one.

### No file tree sidebar

oil edits directories as buffers and yazi is a full file manager one key away.
A persistent tree is a third way to do the same thing, permanently occupying
screen width.

### No auto-session for projects

project.nvim finds the root and changes directory; persisted.nvim restores
buffers per directory and branch. Splitting those two jobs keeps each
replaceable.

### Treesitter textobject queries are not installed

mini.ai can generate treesitter-based textobjects through
`gen_spec.treesitter()`, but that needs query files this configuration does not
install. Writing the specs without them would be guesswork — rule #1 applies to
our own code too.

### Mason packages are pinned; parsers and the kubectl binary already were

`lazy-lock.json` pins plugins and says nothing about the binaries Mason
fetches, so all seventeen carry an explicit `package@version`. Without it a
fresh install six months from now gets different tool versions and different
diagnostics from the same configuration.

Two things that looked like the same gap turned out not to be, and were checked
before any work was done on them:

- **Treesitter parsers** are pinned upstream. nvim-treesitter's own
  `parsers.lua` carries an explicit `revision` for each of its 320 grammars, so
  pinning its commit pins the parsers.
- **The kubectl.nvim binary** is downloaded to match the plugin's checked-out
  release — verified as `v2.44.1` on both sides — so it follows the lockfile
  too.

The cost is real: seventeen versions to raise by hand. `:MasonVersions` prints
them in exactly the form the lists use, so raising them is run, compare, paste.
Pinning is only sustainable if bumping is mechanical — otherwise the pins rot,
which is worse than not pinning at all, because you get an old toolchain *and*
the illusion of a deliberate choice.

**What would change it.** Nothing, unless the bumping stops happening — at
which point unpinning honestly beats pretending.

### The repository does not test against real infrastructure

The terraform runner is exercised against a stub binary; the Kubernetes views
have never been run against a cluster, because the machine this was built on
has no kubeconfig. This is stated rather than implied by silence.

**What would change it.** A throwaway account and a cluster worth breaking.
