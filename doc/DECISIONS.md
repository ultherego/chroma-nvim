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
- [The execution layer](#the-execution-layer)
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
- `chroma-terraform.nvim` shrank from six commands to a plan/apply runner, because
  formatting and validation were already covered elsewhere

**What would change it.** A gap the survey shows is real. That is how
`chroma-vault.nvim` and the AWS module were justified: every candidate was a
single-person project with under ten stars, the most visible abandoned since
2023.

---

## Baseline

### Neovim 0.12 is a floor; CI pins a version, the configuration does not

**Decision.** Require `>= 0.12`, and check it by asking for the APIs `lua/`
calls rather than by comparing versions. CI still runs one pinned build.

**Why.** 0.12 is not a minor bump. It brings the native LSP API
(`vim.lsp.config` / `vim.lsp.enable`), which makes the entire pre-0.11
configuration style obsolete, and it is the version nvim-treesitter's rewritten
`main` branch targets. That is a real reason for a floor.

It is not a reason to refuse 0.13. Chroma is a configuration, not a
distribution of the editor: it uses the Neovim somebody already has, and the
only fair question is whether that editor provides what Chroma calls. So
`:checkhealth chroma` looks for `vim.lsp.config`, `vim.lsp.enable`,
`vim.lsp.get_clients` and `vim.lsp.buf_detach_client` — measured by reading
`lua/`, and none of them deprecated upstream as of this writing — and the
version appears in the message rather than in the condition.

The two are different jobs. CI pins an exact build because a test that runs
against a moving target tells you nothing about what changed; the configuration
takes a floor because a user's editor is theirs.

**What would change it.** Upstream renaming or removing one of those APIs, in
which case Chroma follows and the health check already names what went.

### The user's environment is not pinned; Chroma's own runtime is

**Decision.** Three classes of dependency, two policies.

| | examples | policy |
|---|---|---|
| Chroma's runtime needs | Neovim, git, curl, tar | floor, only where an upstream states one |
| The user's own tools | terraform, tofu, kubectl, helm, ansible, aws, docker | reported, never installed, never touched |
| Chroma's internal runtime | plugins, LSP servers, formatters, parsers | pinned, reproducible |

**Why.** A configuration that installs its own terraform beside the one on the
machine has taken over a system it was invited into. So the middle row is not
"install it for them if they agree" — it is not Chroma's to install at all.
There is no package-manager table, no `sudo`, and nothing that could grow into
one; an earlier design had `pacman -S` behind a confirmation and it was deleted
rather than left unused.

Enabling a component asks for Chroma's features for that technology, not for
the CLI they drive. So a missing `kubectl` never blocks an installation: the
installer says at the end which external tools are not on PATH, `doctor` says
it again on request, and the feature that shells out to it says so when used —
which is the moment somebody can act on it. The boundary is `core`: a tool
`core` asks for is Chroma's own and can stop an installation, a tool any other
component asks for cannot.

The internal runtime is the opposite case, and the reason is measured rather
than argued: a release built with `lazy.sync` installed plugin versions that
differed from the ones the lockfile named, so two installations of the same
release were not the same editor. `install({lockfile = true})` plus `restore()`
fixed that. The user never has to know it happened.

The three version floors that do exist are each somebody else's stated
requirement, not a memory of a development machine — `git >= 2.19` because
lazy.nvim needs partial clones, `tree-sitter >= 0.26.1` and `fzf >= 0.36`
because nvim-treesitter and fzf-lua say so. A floor with no such source does
not belong in the contract.

**What would change it.** A component that genuinely cannot work below some
version of a user tool. Then that floor is written down with its reason, and
still as a floor.

### Contract 5 removes `exact`

**Decision.** A tool version is `min` and/or `max` — a compatibility boundary.
The `exact` field is gone, and the contract number moves from 4 to 5.

**Why.** It was the one way the schema could say "this machine must run kubectl
1.35.2", which is Chroma deciding the version of a tool that is not its own —
the thing the decision above says it does not do. Nothing used it.

Leaving it in place and forbidding it in prose would have been the worst of the
three options: a schema that permits what the policy forbids is a trap with a
delay on it. Somebody reads `Version.Exact`, sees both readers implement it
including the conflict validation, and quite reasonably concludes it is
supported. Then the argument is "it works, but you may not" — which is not an
argument anybody wins. A schema should not be able to express what the product
will not do.

**Why a bump rather than an edit.** Both readers are strict about unknown
fields, so removing `exact` changes what "contract 4" means: the same document
would be valid to an older reader and invalid to a newer one. That divergence,
silent and in a file two languages share, is exactly what the number is for.

**What would change it.** Nothing about a user's tool. If Chroma's own runtime
ever needed one specific version of something, that is a pin on Chroma's side —
a lockfile or a Mason pin — not a constraint on the machine.

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
prerequisite, and `:checkhealth chroma` reports it.

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

What is measured is the buffer, not the file. The decision is made before the
write, so the file on disk is the previous version and a buffer that has never
been saved has no file at all — measuring that was how a buffer grown past the
ceiling got formatted synchronously anyway.

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

### A heading follows its keys

**Decision.** A which-key group heading is registered when the component that
defines the keys under it is enabled — not when the component it is named after
is. `<leader>a` is labelled *Ansible* and follows `vault`.

**Why.** All seven keys under `<leader>a` come from `chroma-vault`, and
`ansible` contributes none. The heading followed `ansible` anyway, and since the
two components are independent that produced two wrong editors rather than one:
`vault` without `ansible` had seven working keys and no heading, and `ansible`
without `vault` had a heading over an empty list, which reads as a feature that
is present and broken rather than one that was not selected.

Both directions are covered by a test, because a fix that repaired one of them
would look complete.

The label stays *Ansible* — Ansible Vault is Ansible's, and naming the group
after the component would tell somebody the key belongs to a product called
Vault. This is why the contract's keymap table has a column naming the gating
component instead of saying "with the component".

**What would change it.** A component that contributes its own keys under
`<leader>a`. Then the heading follows either of them, and the gate becomes a
list rather than one name.

---

## Our own modules

### Each is a plugin, not a file in a shared namespace

**Decision.** `lua/chroma-vault/`, `lua/chroma-terraform/`, `lua/chroma-aws/` — each
self-contained, depending on nothing else in this configuration.

**Why.** The contract originally planned `lua/chroma/ansible.lua` and friends.
Written that way they would be inseparable from this config. Written as plugins
they can be lifted into their own repositories without edits, which is the
stated goal for `chroma-vault.nvim`.

`lua/chroma/` kept only what is genuinely about this configuration rather than
about a tool: the health check.

### The runtime-directory check is duplicated on purpose

**Decision.** `lua/chroma-vault/runtime.lua` and `lua/chroma-terraform/runtime.lua`
are the same policy written twice. An external audit asked for one shared
`lua/chroma/runtime.lua` used by both. It was not taken.

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

### `:checkhealth chroma` instead of scattered guards

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

### Inline encryption gets documentation, not the whole-file writer

**Decision.** `:VaultEncrypt` encrypts a value and leaves the file an ordinary
buffer written by Neovim. Its limits are written down (`:help
chroma-nvim-vault-inline`) rather than closed.

**Why.** An audit observed, correctly, that the guarantees this plugin makes for
Vault files do not hold for a value encrypted inside `group_vars/all.yml`: the
plaintext was in that file before the command ran, so its persistent undo, an
earlier backup copy, a register or the clipboard may hold it, and nothing here
scrubs them.

Attaching the whole-file writer would not be a smaller version of
`:VaultEncryptFile`. That command performs a security transition — it discards
the file's undo history, takes over `:write`, and normalises the result to a new
inode with mode 0600. Doing all of that to an ordinary variables file because
one value in it is now encrypted changes properties the user did not ask to
change, and the surprising part would arrive later, at some unrelated `:w`.

The two commands are different operations: one encrypts a value, the other
converts a file. A guarantee for mixed files would be its own design — a writer
that knows which regions are sensitive — not a line of setup borrowed from the
whole-file path.

**What would change it.** A sensitive-region-aware writer, designed and tested
as a feature rather than added as a side effect of an encrypt command.

### One write hook per buffer

**Decision.** `attach_writer` clears any existing `BufWriteCmd` for the buffer
before creating one.

**Why.** It is called on every decrypt, and a buffer is decrypted again on
every `:edit!`. Without clearing, each reload added another hook, so one
`:write` ran the whole encrypt-and-persist sequence once per reload.

### Vault writes are atomic, and then made durable

**Decision.** Write to a sibling temp file, check the length, fsync, rename,
then fsync the directory the rename changed.

**Why.** Opening the target with `"w"` truncates it before the first byte is
written. An interruption between those moments destroys the vault. The previous
version also ignored the return values of `fs_write` and `fs_close` while
reporting success, so a half-written vault would have been announced as saved.

Syncing the file is not the same as syncing the name that points at it. The
rename is atomic against a crashing process, but the directory entry it changed
can still be lost to a power cut, leaving the old contents behind after a
write that was reported as done. One fsync of the parent directory closes that,
and it is cheap because it happens once per save.

A failure there is reported and not turned into a failed write. Every other
error in this sequence leaves the vault untouched, so refusing is honest; this
one arrives after the file is already in place. Calling it "could not write"
would be false, and leaving the buffer modified would invite a second write of
work that already reached the disk.

### Prompted passwords go to the runtime directory, or nowhere

**Decision.** `$XDG_RUNTIME_DIR`, mode 0600, unlinked immediately. If that
variable is unset or fails validation, refuse.

**Why.** Ansible only accepts a password as a *file*, so something has to be
written. The runtime directory is the one place the system promises is yours
alone and cleared at the end of the session: the XDG specification requires 0700
and owner-only access, a local file system, and contents that do not survive a
reboot or a full logout. Falling back to `/tmp` would quietly do the thing this
module exists to avoid.

It does **not** promise tmpfs. The specification says the directory *might*
reside in runtime memory, and nothing here checks the file system type, so the
claim this project makes is privacy and session lifetime — not that the bytes
never touched a disk. Verifying tmpfs would mean a platform-specific mount
check, which is a different feature from validating the directory.

This is not a compromise ansible itself avoids: a vault password file on disk
is the normal, documented setup.

### libuv failures are return values, not exceptions

**Decision.** Check what `vim.uv.fs_*` returns. `pcall` around one of these calls
is not error handling.

**Why.** Verified: `vim.uv.fs_chmod` on a file it cannot touch returns `nil` and
an error string — `EPERM: operation not permitted` — and raises nothing, so
`pcall` reports success whatever happened. That is exactly how a Terraform plan
the runner had failed to tighten to 0600 was saved as though it had been. The
same holds for `fs_write`, `fs_close`, `fs_fsync`, `fs_rename` and `fs_unlink`,
and it is why several of them are checked one after another rather than run as a
block.

Unlinking used to be the exception to this: a file that may already be gone was
removed under `pcall`, on the grounds that failing to remove it did not matter.
It did — a staged password or a plan file that stayed behind was reported as
removed. Every one of those now goes through an `unlink_checked` that treats
"already gone" as success and anything else as the failure it is, and says so
with the path.

The one `pcall` around a libuv call that remains is the `fs_chmod` each
`runtime.lua` applies to the subdirectory it just created, and it is not
standing in for a check: the directory's mode is read back and validated
immediately afterwards, so the chmod is an attempt and the validation is the
answer.

**What would change it.** Nothing likely. It is a property of luv's synchronous
API, checked rather than assumed after it produced one real defect.

### Writes follow symlinks

**Decision.** The atomic write resolves the path before renaming onto it.

**Why.** `rename()` replaces whatever name it is given. Handed a symlink it
deletes the link and leaves a regular file, while the file the link pointed at
keeps its old contents — the write appears to succeed and the real vault
silently stays stale. Shared secrets linked into `group_vars` are a common
enough layout for this to matter. Verified before and after.

**What changed it.** Hard links used to be listed here as not covered, on the
reasoning that detecting them would mean writing in place — exactly what the
atomic write exists to avoid. That was a false choice: the third option is to
refuse, which is what happens now. `rename` updates one name and leaves the
others on the old contents, so the write stops and says how many links there
are.

`:VaultRekey` is held to the same policy, and there the stakes are higher than
for a write. Measured against ansible-core 2.21.2: `ansible-vault rekey`
overwrites the inode before unlinking it, so through a hard link the other name
is left holding random bytes that no longer decrypt. Not divergence —
destruction.

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

### Registers, ShaDa and the clipboard are outside the Vault guarantee

**Decision.** Say so, rather than build a strict mode that narrows them.

**Why.** The plugin can keep plaintext out of swap files, persistent undo, its
own write paths and password staging, because all four are per buffer or per
operation. `'clipboard'` and `'shada'` are neither: they are global, and this
configuration sets `clipboard=unnamedplus`, which routes unnamed-register
operations through the system clipboard. Not only `yy` — `dd`, `dw`, `cw` and
`x` use that register too, so plaintext can reach the clipboard without anyone
deciding to copy it, and the default `'shada'` persists register contents
between sessions.

A per-buffer strict mode would have to track several vault buffers at once,
nested entry and exit, and restoring global state on every path out, including
the ones that error. It would be most likely to fail exactly where it was
trusted most, and clearing registers on `BufLeave` would not help: a clipboard
manager may already hold a copy, and `:wshada` may already have written one.

So the documentation states the boundary and offers a workflow — `nvim -i NONE`
without `clipboard=unnamedplus` — instead of an option that would imply more
than it delivers. `:help chroma-nvim-vault-safe` carries it. README once said
"Secrets never reach persistent storage", which was not true with this
configuration's own clipboard setting.

**What would change it.** Buffer-local control over register routing, or a
reason strong enough to justify a mode with its own state model and tests. It
would then be a feature in its own right, not a hardening pass.

---

## Infrastructure commands

### `apply` applies a file, never a fresh plan

**Decision.** `plan` writes to a file and shows it; `apply` applies that file.
No `-auto-approve`, anywhere.

**Why.** Terraform documents that passing a saved plan means it "performs the
operations in the saved plan without prompting you for confirmation" — the file
*is* the approval. So apply cannot execute an action set other than the one
that was on screen.

This entry used to end "drift between reading and applying becomes structurally
impossible rather than merely unlikely". That was wrong, and wrong in the
direction that matters — it promised more than the code did. The saved plan
fixes the planned action set. It does not fix the program that carries it out
(see the pinned executable, below), who it runs as (see the credential
entries), or the state of the world at the far end. Infrastructure,
credentials and remote state can all change independently in between.

### The executable is pinned to the plan

**Decision.** The path `terraform`, `tofu` or `terragrunt` resolved to when the
plan was made is recorded with it and used for the apply. If it is gone, the
apply is refused.

**Why.** The plan file fixes the action set, not the program executing it. PATH
changes, terraform gets uninstalled leaving tofu to answer for the name, a
terragrunt.hcl appears in the directory. Any of the three would then carry out
"the reviewed plan" as something other than the reviewed operation. There is no
safe substitute, so there is no fallback.

### A plan is reviewed only once it has actually been shown

**Decision.** If the review window cannot be opened, the new plan file is
deleted and any previously reviewed plan for that directory is invalidated.

**Why.** Review is what makes a plan appliable, so a plan nobody saw must not
be appliable. The window can genuinely fail — E36, when the layout leaves no
room for a split — and the alternative shape, catching the failure and
recording the plan anyway, converts a visible error into a silent one: the
interface broke and the plan counts as read. The previous plan goes too because
asking for a new plan supersedes it; leaving it would let apply run something
the user had not just reviewed.

**What would change it.** Nothing that keeps the review step meaningful.

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

By default this compares environment, not identity: it does not ask STS who the
credentials resolve to, because that is a network round trip on every plan.
`:AwsWhoami` answers that when it matters.

The environment is a weak proxy and the gap is not small. With AWS_PROFILE
unchanged, all of these still change who the apply runs as: new static
credentials, an SSO session refreshed against another account, an edited
`~/.aws/credentials`, the same profile name now assuming a different role, and
credential environment variables, which take precedence over the profile
entirely.

**What changed it.** `strict_aws_identity`, off by default. With it on, the
account and principal ARN come from `aws sts get-caller-identity`, are recorded
with the plan, and are compared before the apply — a different account or a
different principal refuses, and so does losing the ability to ask after a plan
was bound to an answer.

It is opt-in rather than default because the cost is a network round trip on
every plan and every apply, and the environment comparison already catches the
ordinary mistake of switching profile between reading and applying. It is not
cached: a cache is a way of being told which credentials were in effect
earlier, which is the thing being guarded against.

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

## The execution layer

The invariants are in `CONTRACT.md` under the same heading. These are the four
decisions that shaped them, and — at the end — what each was measured against.

The contract was frozen in writing before a line of it was implemented, and
nothing in it was renegotiated during the implementation. That is the only
evidence a freeze is worth doing, and it is the reason anything from the list
in *Deliberate omissions* arrives the same way.

### A repository declares what to run; Chroma does not infer it

**Decision.** `.chroma/tasks.json` says what a command is, where it runs and
with what environment. Chroma runs that and adds nothing.

**Why.** There is no correct way to lay out or run infrastructure. Two
repositories using the same tool put playbooks in `playbooks/`, `plays/` or
`automation/beta/`, and run them as `ansible-playbook site.yml -i
inventories/prod`, as eight flags including `--ask-vault-pass`, or as `make
deploy ENV=prod`. All three are right. Chroma cannot safely guess which
directory a command belongs in, whether `-K` is wanted, or whether the real
entry point is a wrapper somebody's employer requires instead of `terraform`.

So the layer implements a *task* — an executable, a directory, an environment —
and `ansible-playbook`, `terragrunt`, `make` and an internal company CLI are
the same kind of thing to it. `group` is metadata: a task in group `terraform`
gets no Terraform behaviour and no default arguments, because the engine has no
reason to know that `make docs` is a different kind of thing from `terraform
plan`.

**What would change it.** Nothing about inference. Richer declarations —
inputs, `${file}`, more `cwd` modes — are in *Deliberate omissions* below and
stay declarations when they arrive.

### The Ansible runner went, and the plugin stayed

**Decision.** `<leader>ar` and `require("ansible").run()` were removed in the
same milestone that added `<leader>xr`. `nvim-ansible` stays for filetype
detection, `ansible-doc` through `keywordprg`, and `gf` into a role.

**Why.** Shipping both would put the thesis of this layer and its exact
negation side by side in one editor: one keymap where the project declares what
to run, one where a plugin infers it from the buffer. Two answers to one
question is the failure this design exists to remove, and leaving the old one
in place "for now" is how it becomes permanent.

The required `ansible` executable went with it, because the component required
it for exactly one stated reason — running a playbook from the buffer — and
that is the thing that was retired. What remains of the plugin was read at the
pinned version: it needs `ansible-doc`, guarded by `executable()`, and nothing
else. So `ansible-doc` arrives as **optional** rather than recommended, which
is what the level already means: it improves the component when present and
changes nothing when absent.

**What changed it.** An owner decision on 2026-08-12. This entry keeps its
reasoning because the reason the old runner went is not the reason it is being
replaced.

Ansible gets a module of its own, `chroma-ansible`, beside `chroma-terraform`
rather than inside the task layer. The argument that settled it is symmetry:
`chroma-terraform` has been a domain runner standing beside generic tasks since
before generic tasks existed, so Ansible reaching the same standing follows the
rule instead of carving an exception in it. The sentence this paragraph replaced
— *"Nothing. A playbook runner is a task somebody writes"* — is withdrawn, and
withdrawn deliberately rather than quietly overtaken.

Nothing above this paragraph is withdrawn with it. The old `<leader>ar` inferred
the playbook from the buffer, and that inference is what made it the negation of
this layer; the planner asks for every part of a run explicitly. The generic
layer stays domain-blind in both directions: a task declaring
`argv: ["ansible-playbook", …]` remains an ordinary task, and the module will
not read `.chroma/tasks.json`.

The design is frozen in `chroma-ansible-design.md`, which ships beside this
file. No code exists yet, so `<leader>ar` is unmapped today and the contract
records its removal, not its return.

### Project tasks have their own version floor, and below it they fail closed

**Decision.** Chroma's floor stays 0.12. Project tasks need 0.12.3, refuse
below it, and `:checkhealth chroma` reports that gate as its own line.

**Why.** The floor is upstream's, not a preference: `799cbfff8` (2026-05-20)
escapes the path before the `view` command in `vim.secure.read()`, and checking
`runtime/lua/vim/secure.lua` per tag puts it in v0.12.3 and v0.12.4 and absent
from v0.12.0 to v0.12.2. A security boundary is not built on an unpatched
implementation, and 0.12.2 is still a correct Chroma — it just has one feature
it cannot have.

Health had to change with it. It used to end green whenever every editor API
was present, which on 0.12.2 was a green report about an editor where tasks
refuse to run. Worse, the threshold lived privately in `health.lua`, so health
said "unavailable" while the runtime checked nothing at all. Both now ask
`chroma.tasks.availability`.

**What would change it.** Nothing that keeps the boundary. If the floor ever
rises again it rises in one module.

### The bytes that were trusted are the bytes that are parsed

**Decision.** The trust adapter takes one snapshot of the file, and that
snapshot is what is hashed, what is authorised, and what is parsed. Definitions
are re-read on every Run Task and never cached for a session.

**Why.** Reading the file to hash it and then calling `vim.secure.read()` reads
it twice, and a file can change in between — the precheck says trusted, the
contents change, and the modal appears after Chroma has promised there would
not be one. Reading lines and joining them would produce a second
representation that can differ in line endings and in a final newline, so
Chroma would be answering a different question from the one Neovim answered.

Caching is the same mistake in time rather than in representation. The
component contract is read once per session on purpose, because it is part of
an immutable release tree; a project's task file is a file somebody is editing.
Copying that cache here produces a Run Task that still says "untrusted" after
the user has trusted it, with no error anywhere.

The coupling this buys — Chroma parses Neovim's own trust database — is
deliberate and carries two obligations: a test pins the format, so an upstream
change surfaces as a failing test rather than as a wrong sentence about
security, and a parse failure degrades to a generic refusal rather than to a
guess.

**What would change it.** Upstream offering a way to ask "is this file trusted,
and at which contents" without side effects. Then the adapter is deleted, not
loosened.

### What was measured, and against which version

Not decoration. Each of the four rules above rests on one of these, and each
was run rather than read about. A later measurement supersedes the note; it
does not supersede the rule.

**Neovim 0.12.4, `runtime/lua/vim/secure.lua`.** `vim.secure.read()` offers
`ignore / view / deny` for a file; `allow` exists only for a directory — which
is why the source has to be proved a regular file before `read()` is called at
all, or the decision about directory trust belongs to whoever created the
directory. `view` opens the file and returns `nil`, so trusting a file means
viewing it and then running `:trust`. `deny` is recorded as `!` and silences
every later prompt, which is why *denied* has to be reported as denied rather
than as "no tasks". The database is `$XDG_STATE_HOME/nvim/trust`, one `hash
path` per line, keyed by the real path, with file decisions bound to a `sha256`
of the contents — so editing `tasks.json` invalidates the decision. `:trust`
documents a TOCTOU risk for `:trust [file]` and directs users to view and then
run it with no argument, which is why Chroma's instructions never name a path.

**The 0.12.3 floor.** Upstream `799cbfff8` (2026-05-20), *"fix(vim.secure):
read() command injection vulnerability"*, escapes the path before the `view`
command. Checked in `runtime/lua/vim/secure.lua` at each release: absent in
v0.12.0, v0.12.1 and v0.12.2; present in v0.12.3 and v0.12.4. Schema 1 hands
`read()` a path whose variable part is the user's own clone location, so the
exposure is small — but it is small by accident of this design, and the first
change that discovers task files in repository-controlled subdirectories would
make it real. A security boundary is not built on an unpatched implementation.

**snacks.nvim at the pinned `882c996`.** `terminal.open()` starts a new
terminal and passes the command to `jobstart` with `cwd`, `env` and `term =
true`; a table command therefore runs without a shell, and `env` extends the
inherited environment rather than replacing it. A terminal's identity is its
command, directory, environment and count — the task id is not among them, so
two different tasks running `terraform plan` in one directory would collide,
and each run needs its own count. `auto_close` defaults on through
`interactive`: it closes a terminal whose process exited 0 and keeps one that
failed, reporting the status. Task execution sets `auto_close = false` so a
successful run stays readable — and that same switch is what installs the
failure notice, since the `TermClose` handler that reports a non-zero status
lives *inside* the `auto_close` branch. Turning the closing off turns the
reporting off with it, which is why Chroma installs a `TermClose` of its own
that reports and closes nothing.

**`jobstart` validates `argv[0]` before it looks at `env` and `cwd`.** Measured
on 0.12.4 with an executable present only in the task's `PATH`, and again with
one present only in the task's working directory: both give `E475: … is not
executable`, and inside the terminal library that happens after the window
already exists. It raises rather than returning an error. That is the whole
reason `argv[0]` is resolved to an absolute path before a terminal is opened,
and why the preview shows the resolved path — the preview and the executor read
one prepared array, so they cannot describe different commands.

---

## Testing and CI

### Only our own code is tested

**Decision.** Around four hundred cases covering the modules in `lua/`, and
nothing covering plugin configuration.

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

### An unreadable selection runs core alone, not everything

`$XDG_CONFIG_HOME/chroma/components.json` has three outcomes rather than two.
Absent means legacy: every component, because a configuration from before any
of this existed must not lose Terraform to an update. Valid means the selection.
Present and unreadable means core alone, said loudly.

The third one used to be the first one. That was right for about a week — while
nothing recorded what anybody wanted, running everything was the only honest
answer to a file nobody could parse. The moment an explicit selection existed
the argument inverted: the file being there says a choice was made, and one of
the things it could have said is `"selected": []`. Falling back to everything
answers a deliberate core-only with Terraform, Vault, AWS, Kubernetes and
Ansible, on the strength of a byte that failed to decode.

Core alone is also wrong — it is not what was chosen either — but it is wrong in
the direction that starts an editor, names the problem, and switches nothing on
that nobody asked for. Callers are told which of the three they are in, rather
than being handed a boolean that cannot express it.

**What would change it.** A record of the last selection that read cleanly.
With one, safe mode could be "what you had yesterday" instead of "the minimum",
which is better than both. Nothing writes one yet.

### A partial contract is not a contract

`components.load()` reports every file it could not read and returns the rest.
That is right for `:checkhealth chroma`, which exists to list what is wrong, and
it was wrong for deciding what runs: the runtime took the first return value and
dropped the problems on the floor.

The failure was measured rather than argued about. Make `core.json` unreadable
and `core` is simply absent from the set; `enabled` skips ids it does not know,
so a selection of Terraform resolved to Terraform **alone** — a component
running without the one thing every component requires — and the mode came back
as `selected`, which asserts that nothing is wrong. A missing components
directory arrived at the same place by a different route: no components, no
problems, and a legacy startup with nothing in it.

So the contract is checked before the selection is, and a contract with any
problem in it, or with no `core` in it, drops to safe mode. Even one unreadable
optional component is enough, and that is deliberate: the file that failed to
parse is the file that would have said what depends on what, so there is nothing
left to resolve a selection against.

**What would change it.** Nothing about the rule. If the noise ever becomes a
problem — one broken optional component switching off a whole editor — the
answer is a better error, not a partial contract.

### The component contract says what, and a registry says how

`components/*.json` carries `"schemas": ["kubernetes"]`. It does not carry the
schema URL, the Kubernetes version it is pinned to, or the eight file patterns
it applies to — those live in `lua/chroma/schemas.lua`, exactly as how to ask an
executable for its version lives in the CLI's `toolver` and not in the manifest
that requires it.

The contract is meant to be readable by a web page or a different editor. A
`fileMatch` array in yaml-language-server's settings shape is not a fact about
Kubernetes support; it is a fact about one language server, and the day it moves
the manifests would have to be rewritten to describe a product that had not
changed.

The same split decided where the boundary of a disabled component sits.
Switching off `github-actions` removes actionlint. It does not reach into the
SchemaStore catalogue and remove GitHub's workflow schema, because that
catalogue is a Core capability that recognises documents on its own: a disabled
component takes away what Chroma switched on for that domain, and does not make
Core pretend it cannot read a file. The rule is written down in
`../cli/DESIGN.md`
because it is the kind of line that gets redrawn by accident.

**What would change it.** A component whose only sensible contribution is a
schema the catalogue already covers — at which point the line above would have
to be argued again rather than assumed.

### The repository does not test against real infrastructure

The terraform runner is exercised against a stub binary; the Kubernetes views
have never been run against a cluster, because the machine this was built on
has no kubeconfig. This is stated rather than implied by silence.

**What would change it.** A throwaway account and a cluster worth breaking.

### What schema 1 of a task deliberately does not have

Each of these was designed and then left out, so that the first version of the
execution model could be proved end to end. They are recorded because a list of
things nobody got round to and a list of things somebody decided against look
identical six months later.

```text
inputs (text, select, path) and ${input.NAME}
${file}, ${file_dir}, and the definition of a file-backed buffer
cwd.mode = file
cwd.mode = nearest, with markers
cwd.mode = prompt, with a directory picker
global and user-level tasks, and their provenance in the picker
shell tasks, for a command that genuinely needs a shell
domain shortcuts that open the picker pre-filtered by group
task run history and a UI for returning to a run
```

`file` and `nearest` both depend on what the current buffer is, and schema 1
has no current-file semantics at all — deliberately, because the first vertical
slice is then testable without oil buffers, dashboards, terminals and unnamed
buffers. When they arrive they bring their own definition with them: a buffer
whose name is a local path that exists and is a regular file, and `nearest`
searching upward from that file's directory, stopping at the project root
inclusive, and refusing when no marker is found.

`inputs` went because the example that motivated it — one Ansible task with a
choice of inventory — is two tasks today, and nothing about the execution model
is left unproven by writing it that way.

The one that cannot be retrofitted was therefore built in from the first day:
every run gets a `run_id` from a single counter per Neovim session, so two
parallel runs of one task never share a terminal identity. There is no run
history and no way back to an earlier run — only the identity that a history
would need.

**What would change it.** Each on its own evidence, and each frozen in writing
before it is built, which is how schema 1 was done.

### blink.cmp is pinned by tag rather than by commit

Every other plugin is pinned by `lazy-lock.json` alone. blink.cmp also carries
`tag = "v1.10.2"` in its spec, and the reason is a property of that particular
release rather than a preference about pinning.

v1.10.2 is commit `78336bc`, which the lockfile names — and that commit is
**not an ancestor of `main`**. It exists only as the tip of the v1 line.
A ref that a clone always brings with it is a pin that cannot be missed; a
commit off the default branch is one a narrower fetch can fail to find, and
what stays on disk then is `main`, which is v2.

Measured on CI: one profile in three came up on v2 and failed with
`module 'blink.lib' not found`. v2 requires Neovim 0.12+ and a second plugin,
`saghen/blink.lib`, so adopting it is a decision of its own and not something
to arrive at because a clone resolved differently one morning.

**What would change it.** Moving to v2 deliberately, which brings the extra
dependency with it; or upstream making the v1 tag reachable from a branch a
default clone fetches, which would leave the lockfile enough on its own.
