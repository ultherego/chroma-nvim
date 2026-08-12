# chroma-ansible — design

**Status: signed off, implementation in progress.** Nothing here is left for
whoever writes the code to decide, and since 2026-08-12 nothing is left for the
owner to decide either — *Sign-off* at the end carries the five answers and the
two corrections that came back with them.

The architectural decision behind the module was taken the same day: Ansible
gets a first-class domain module beside `chroma-terraform`, `chroma-vault` and
`chroma-aws`, and the entry in `DECISIONS.md` reading *"What would change it.
Nothing. A playbook runner is a task somebody writes"* is deliberately
withdrawn.

Where a rule rests on how another program behaves, §20 says what was run and on
which version. Everything here was measured against **ansible-core 2.21.2**,
**Neovim 0.12.4** and **snacks.nvim at the pinned `882c996`**. Nothing rests on
how an API ought to work.

Section numbers are meant to be cited from source comments, as
`doc/CONTRACT.md` and `doc/DECISIONS.md` already are. They may be rewritten;
they may not be renumbered without following the citations.

---

## Contents

```text
 1  Scope and non-goals            11  Vault and the credential boundary
 2  Relationship to Project Tasks  12  Check and diff
 3  Execution context              13  Async generation model
 4  Playbook selection             14  Repeat the last run
 5  Inventory sources              15  Preview and confirmation
 6  Active-inspection boundary     16  Failure and degradation
 7  Inventory graph inspection     17  Component contract
 8  Tag inspection                 18  Keymaps
 9  Limits and target validation   19  Tests and mutations
10  Ansible CLI overrides          20  Measured assumptions
```

---

## 1. Scope and non-goals

### 1.1 What this is

An **execution planner**. It takes the operator from

```text
playbook + inventory + operator decisions
```

to

```text
an exact argv, an exact working directory, an exact environment
```

and starts that process in a terminal. It does not interpret Ansible semantics
of its own: where a fact about Ansible is needed, **Ansible is asked**, through
`ansible-inventory` and `ansible-playbook`'s own listing modes.

That is the same rule `chroma-vault` and `chroma-aws` already follow —
`DECISIONS.md`, *"External tools are asked, not re-implemented"*. Ansible's
configuration precedence, inventory plugins, group hierarchies, tag expansion
and host patterns change between releases; re-implementing any of them in Lua
is a guess with a long shelf life.

### 1.2 What this is not

| Not | Because |
|---|---|
| A YAML parser for playbooks or inventories | §1.1. Ansible is the semantic authority |
| A secret manager | §11. Ansible prompts in its own terminal |
| A wrapper for company orchestration | §2.3. `make ansible-prod` is a Project Task |
| A guarantee about which hosts will be affected | §9.4. Dynamic inventory resolves at run time |
| A replacement for `nvim-ansible` | The plugin keeps filetype detection, `ansible-doc` and `gf` |

### 1.3 Zero configuration

The module works after installation, with no file written anywhere:

```text
nvim → <leader>ar → …
```

Configuration may exist later as an optimisation — default remote user,
favourite inventory directories — under one rule: **configuration shortens the
workflow, it never unlocks functionality.** Nothing in this document depends on
a configuration file existing, and no step may be reachable only through one.

Nothing writes to the operator's repository. Ever.

---

## 2. Relationship to Project Tasks

### 2.1 Two questions, not two roads to one answer

```text
<leader>xr   Project Tasks    the repository declares; Chroma is domain-blind
<leader>ar   chroma-ansible   the operator declares; Chroma knows Ansible
```

A Project Task answers *"carry out this declaration"*. The planner answers
*"help me build a standard Ansible invocation"*. The first is written once into
`.chroma/tasks.json` and repeated by everyone who clones the repository; the
second is composed by one operator for one run.

### 2.2 No bridge, and it is enforced

A Project Task may carry `argv: ["ansible-playbook", …]`, exactly as it may
carry `["terraform", "plan"]` today. Such a task **does not become part of
chroma-ansible**: it is not discoverable from the planner, it does not seed the
repeat slot, and the planner produces nothing a task may consume.

This is the boundary Managed Terraform already has, and it is enforced the same
way — an architecture test:

```text
rule      lua/chroma/tasks/** must not depend on chroma-ansible, and
          lua/chroma-ansible/** must not depend on chroma.tasks
mutation  add require("chroma.tasks.run") to the planner's executor
expected  the architecture test fails
```

### 2.3 Where the boundary of this module is

Standard `ansible-playbook` invocation is this module's. Anything else —
`make ansible-prod`, `uv run ansible-playbook`, `./company-infra ansible run` —
is a Project Task, and that is not a gap to close later by guessing. A wrapper
that changes the meaning of the flags is a wrapper this module cannot introspect
through, because `--list-tags` on the wrapper is not `--list-tags` on Ansible.

### 2.4 The old `<leader>ar` is not coming back

The keymap returns; the model does not.

```text
retired (568c28e)   buffer → the plugin infers the playbook
                           → the plugin infers the invocation → run

this module         operator selects the playbook
                    → operator selects the execution directory
                    → operator selects inventory sources
                    → Ansible is asked what those mean
                    → operator selects the scope
                    → exact argv → preview → explicit yes → run
```

The reason the old runner was removed still holds: an editor may not have one
declared and one inferred way of running the same thing. Nothing in this module
infers. The current buffer appears as a **suggestion** (§4.2) and is never
execution authority.

---

## 3. Execution context

### 3.1 Why the working directory is not cosmetic

Ansible resolves its configuration in this order, and **does not search
upward**: `ANSIBLE_CONFIG`, then `ansible.cfg` in the *current directory*, then
`~/.ansible.cfg`, then `/etc/ansible/ansible.cfg`. That file can decide
`roles_path`, `collections_path`, `inventory`, vault settings, callback
plugins, become defaults, forks and SSH behaviour.

So the working directory is part of what the command *means*, not where it
happens to be typed.

### 3.2 Neovim's directory is a candidate, never an authority

> **Neovim's current directory may be offered as one candidate before planning.
> It is never execution authority by itself.**
>
> **Once the operator chooses an execution directory, its canonical path is
> frozen for inspection, preview and execution. Later `:cd`, `:lcd` and `:tcd`
> changes cannot alter the run.**

This extends the invariant Project Tasks already has rather than reversing it.
`:cd`, `:lcd`, `:tcd`, `project.nvim` and oil all move the editor's idea of
where it is, which makes it far too easy to change by accident for something
that decides where `ansible-playbook` runs.

### 3.3 The choice

After the playbook is selected, the operator picks from candidates, deduplicated
by canonical path, in this order:

```text
Working directory

> /work/operations              Neovim's directory      ansible.cfg present
  /work/operations/plays        playbook directory      no ansible.cfg
  /work                        parent of the playbook  no ansible.cfg
  Choose another…
```

`ansible.cfg present` is a `stat`, and it is a **fact about the filesystem, not
a claim about Ansible**. The interface may not say or imply that Ansible would
find any of these by itself: it would not, by §3.1, unless the directory is the
one chosen.

Ancestors of the playbook that hold an `ansible.cfg` may be offered as
additional candidates under the same rule.

### 3.4 Freezing

The chosen path is resolved with `realpath` once and stored on the planner run.
Every subsequent step reads that value. Nothing calls `getcwd()` again.

If the frozen directory has stopped being a readable directory by the time the
process is started, the run is refused by name (§16).

### 3.5 One context for every subprocess

> **The same executable, the same frozen working directory, the same effective
> environment, the same inventory sources and the same explicit CLI overrides
> are used for every subprocess of one planner run.**

That covers `ansible-inventory --graph`, `ansible-playbook --list-tags`,
`--list-hosts`, `--list-tasks` and the final `ansible-playbook`. Inspecting
tags from one directory and executing from another would show the operator
information generated by a different Ansible than the one that runs.

**With one exclusion, which is measured rather than reasoned.** An inspection
subprocess never carries a flag that makes Ansible prompt, because it has
nowhere to prompt: it runs under `vim.system` with no terminal attached, so a
prompt is a hang or an error, not a question.

On 2.21.2, `ansible-playbook --list-tags -K` does **not** prompt — become
credentials are wanted when connecting, not when listing — while
`ansible-playbook --list-tags --ask-vault-pass` **does**, and without a terminal
it ends in `EOFError (ctrl-d) on prompt for (default)`.

So `--ask-vault-pass` is execution-only. `-K` is excluded as well, though it
happens to be harmless today: it cannot affect what a listing reports, so
carrying it buys nothing, and the version where it does start prompting is a
version this planner would hang under.

The consequence is stated rather than hidden: an inventory that genuinely needs
a vault password to be read will fail inspection and still run. That is §16's
rule — failure to inspect is not failure to execute — and not a special case.

---

## 4. Playbook selection

### 4.1 The model is a list from the first commit

`ansible-playbook` accepts `playbook [playbook …]`. The internal model is

```lua
playbooks = { "plays/site_upgrade.yml" }
```

not a single string. **M1 selects exactly one**, and the builder emits every
element of the list, so accepting several later is a change to the picker and
to nothing else.

### 4.2 The current buffer is a suggestion

```text
Playbook

> Current buffer: plays/site_upgrade.yml
  Choose another…
```

The suggestion appears when the current buffer is backed by a readable regular
file whose name ends in `.yml` or `.yaml`. That is the whole of the test:
Chroma does not read the file to decide whether it looks like a playbook,
because deciding that is Ansible's job and getting it wrong in either direction
is worse than asking.

If the buffer is not such a file — a dashboard, a terminal, oil, an unnamed
buffer — the suggestion is absent and the picker opens directly.

### 4.3 Choosing another

`vim.ui.input` with `completion = "file"`. The starting point is the directory
of the current buffer when it has one, and Neovim's directory otherwise.

Nothing scans the filesystem for playbooks. A playbook is not required to be
inside a git repository, a project, or anywhere in particular — Ansible imposes
no such rule, so neither does this.

### 4.4 What is checked, and what is not

Before the planner continues, each selected path must resolve to a **readable
regular file** — a symlink to one is acceptable. Anything else is a named
refusal.

Its contents are not read, not parsed and not validated. A playbook that is
broken is discovered by Ansible, in §8, with Ansible's own error.

---

## 5. Inventory sources

### 5.1 A list, in order, unsorted

`-i` may be given several times and **the order is significant**, so the model
is a list and the planner never sorts it:

```lua
inventory = { "../inventory/common", "../inventory/prod" }
```

M1's picker adds one source at a time and can remove one; the argv builder
emits one `-i` per element, in the stored order.

### 5.2 "Source", not "hosts file"

An Ansible inventory may be a file, a directory, an executable script, or a
plugin configuration that contacts EC2, VMware, LDAP or a CMDB. The interface
therefore accepts a **file or a directory** and never calls the thing a
`hosts.yml`.

Paths are relative to the frozen working directory (§3), which is what makes
`../inventories/dev/hosts.yml` mean one thing.

### 5.3 Inheriting Ansible's own configuration

```text
Inventory

> Use Ansible configuration
  Add a source…
```

`Use Ansible configuration` means exactly one thing: **no `-i` is passed.** The
planner does not try to discover what Ansible's default inventory would be and
then pass it explicitly — that would replace Ansible's precedence with Chroma's
guess at it, and the two can differ.

This choice does not weaken §6. It strengthens the case for the gate: with no
explicit source, what will be contacted is decided by configuration the
operator has not been shown.

---

## 6. The active-inspection boundary

### 6.1 Passive and active

```text
PASSIVE — no Ansible process
    select playbooks, working directory, inventory paths
    stat, realpath, is-it-a-regular-file
    show candidates and the current buffer suggestion

                    ↓  explicit affirmative, default No

ACTIVE — Ansible runs
    ansible-inventory --graph
    ansible-playbook --list-tags
    ansible-playbook --list-hosts
    ansible-playbook --list-tasks
    the run itself
```

> **Selecting a path in a picker must never start an Ansible process.**

Never at `VimEnter`, never at `BufEnter`, never on a timer, never as a
background refresh, and never as a side effect of a selection.

### 6.2 Why this gate exists

`ansible-inventory --graph` is not a file read. An inventory may be an
executable script, and an inventory plugin may contact an external system.
`ansible.cfg` in the working directory can point `callback_plugins`, `library`
and `roles_path` at code that Ansible then loads. Pointing a file picker at a
directory is not consent to run what is in it.

### 6.3 The gate

Before the **first** Ansible subprocess of a planner run:

```text
Ansible inspection

Chroma is about to run Ansible using:

  Working directory   /work/operations
  Playbook            plays/site_upgrade.yml
  Inventory           ../inventories/dev/hosts.yml

Inspection may execute inventory scripts and plugins configured for this
workspace, and may contact external systems.

Inspect? [y/N]
```

The default is **No**. Escape, a dismissed prompt and an answer that never
arrives all mean no, exactly as the Project Tasks confirmation does.

When inventory is `Use Ansible configuration`, the inventory line reads
`from Ansible configuration (not shown)` and the gate is shown all the same —
see §5.3.

### 6.4 The scope of one consent

One yes opens **every** introspection call belonging to that one planner run.
It is not cached globally, not cached per directory, and not remembered between
runs. Cancelling the planner and starting again asks again.

**The consent is bound to the three values the prompt named**: the frozen
working directory, the playbook list, and the inventory sources in order.
Changing any of them invalidates it and the gate is asked again — including when
the change happens by going back a step rather than by starting over.

That is not extra caution, it is the only reading that keeps the prompt honest.
The gate does not ask "may Chroma run Ansible"; it names a directory, a playbook
and an inventory source and asks about *those*. A yes that outlived them would
have been obtained for one execution context and spent on another, which is the
whole failure the gate exists to prevent.

The consent does not cover the run itself. That has its own confirmation (§15),
and no yes at this gate implies one there.

### 6.5 Why not `vim.secure`

Project Tasks require `vim.secure` trust before *reading* `.chroma/tasks.json`,
and the asymmetry is deliberate rather than an oversight.

`vim.secure` binds a decision to the exact bytes of one file. Here the file is
not the boundary: behaviour also comes from `ansible.cfg`, inventory plugins,
callback plugins, collections, filter plugins, roles and inventory scripts.
Trusting `inventory.yml` would say nothing about any of them, and a prompt that
appears to cover the execution context while covering one file is worse than no
prompt — it converts an unbounded risk into a bounded-looking one.

The gate above names what is about to happen instead of pretending to have
verified it.

---

## 7. Inventory graph inspection

### 7.1 `--graph`, not `--list`

```bash
ansible-inventory -i SOURCE [-i SOURCE …] --graph
```

The planner needs group names, host names and the hierarchy. `--list` also
returns **every host variable, in plaintext** — measured, §20.3 — and there is
no flag that suppresses them: `--vars` only *adds* variables to `--graph`.

Taking `--list` and promising to discard the rest would be four promises to keep
on every error path, including ones that log. Not asking is one decision that
cannot be forgotten. This is the same reasoning that keeps a marker file out of
a directory Chroma has promised to return untouched.

### 7.2 The cost, accepted explicitly

`--graph` emits a text tree, not JSON, so this module carries a parser for
somebody else's output format. That is a real maintenance cost and it is taken
on purpose: maintaining a parser for a minimal, secret-free output beats
maintaining the claim *"we read every host variable and promise never to print
one by accident"*.

The parser is fed fixtures captured from real `ansible-core 2.21.2` output
covering nested groups, empty groups, `@all` and `@ungrouped`, hosts appearing
in several groups, host aliases, several `-i` sources merged, dynamic
inventory, names with unusual characters, and truncated output.

### 7.3 Parsing is all or nothing

> **A partially parsed graph is a failed inspection.**

Any line the parser does not recognise, any indentation deeper than one level
below the line before it, and any output that does not end in a newline: the
result is discarded whole and reported as an inspection failure (§16). Partial
results are never shown.

The reason is not tidiness. A tree that parses to *some* of the groups looks
exactly like a small inventory, and the operator would choose a limit from a
list that silently omits the group they wanted.

**What the parser can and cannot see, stated rather than implied.** Measured on
2.21.2, every graph ends with a newline, including the two-line one an empty
inventory produces — so output stopping mid-line is detectable, and it has to
be, because a host name cut in half parses perfectly well as a shorter host
name. A cut landing exactly on a line boundary is **not** detectable here: it
is a syntactically complete, smaller tree. That case belongs to the layer that
ran the subprocess — a non-zero exit or a stderr Ansible wrote — and this parser
does not pretend to cover it.

### 7.4 What is kept

Group names, host names and the parent-child relation. Nothing else from the
subprocess is retained, and **the raw output of any Ansible subprocess is never
written to a Chroma log**.

### 7.5 Large inventories

Groups are listed first. Hosts are reached by entering a group or by searching;
the planner does not render thirty thousand rows because an inventory has thirty
thousand hosts.

---

## 8. Tag inspection

```bash
ansible-playbook [-i …] --list-tags PLAYBOOK…
```

```text
Tags reported by Ansible

> No tag filter
  common
  site_upgrade
  security
  Custom tag…
```

### 8.1 "Reported by", not "all"

Ansible expands static `import_*` at parse time, so their tags appear; tags
inside dynamically `include_*`d files do not. Calling the list *all tags* would
be false, and the operator would conclude a tag does not exist when it does.

`Custom tag…` therefore always exists, and is not a fallback for failure — it is
how a tag Ansible cannot list is reached.

### 8.2 Tags are multi-select

`--tags` accumulates across repetitions — measured, §20.2 — so a multi-select
produces one flag per tag and no string is joined:

```text
--tags common --tags security
```

### 8.3 Roles are not a filter

A role may arrive through `roles:`, `import_role:` or `include_role:`, and a tag
attached to a role behaves differently for static and dynamic reuse. Offering
"pick a role" and translating it to `--tags role-name` would be Chroma inventing
Ansible semantics.

Roles referenced by a playbook may be shown as metadata later. They are never a
scope selector.

### 8.4 Inventory is not required here

`--list-tags` succeeds with no inventory, warning that the host pattern matched
nothing — measured, §20.4. The planner still passes the selected inventory
sources, because §3.5 requires one context for every subprocess, but a run with
`Use Ansible configuration` and no reachable inventory still lists tags.

---

## 9. Limits and target validation

### 9.1 The choice

```text
Limit

> No limit

Groups
  webservers
  dbservers

Hosts
  Search hosts…

Custom pattern…
```

M1 offers no limit, one group, one host, or a custom pattern. It does **not**
offer multi-select of hosts: combining two hosts means generating a host
pattern, and whether that is `host1,host2` or `host1:host2` is a semantic
decision that belongs to the operator, who can type it.

### 9.2 `No limit` is not `-l all`

Choosing no limit emits **nothing**. It means *no CLI limit override*, not
*target everything*. The playbook's own `hosts:` stays the authority, and
`-l all` would override it.

### 9.3 Custom patterns are passed through

```text
webservers:&production
all:!maintenance
host01,host02
```

The string reaches `argv` byte for byte. Chroma does not parse it, validate it,
or expand it. There is no shell anywhere in this module.

`ansible-inventory --graph -l PATTERN` is **not** a validator: `-l` is ignored
by `--graph` — measured, §20.6.

### 9.4 Target preview, and what it promises

```bash
ansible-playbook … --list-hosts
```

```text
Targets reported now
  4 hosts   web01 web02 dns03 dns04
```

This is the only honest validation of a pattern, because it answers *"which
hosts will this playbook, with this inventory, under this limit, address"*
rather than *"is this pattern meaningful to the inventory"*.

> **The result is a snapshot taken now, not a guarantee.** With dynamic
> inventory an autoscaling group can change between the preview and the run.

So the wording is `Targets reported now`, never `Exactly these hosts will run`.
Chroma's unchanging promise is over `argv`, `cwd` and `env` — not over somebody
else's infrastructure.

Failure here does not block the run (§16).

---

## 10. Ansible CLI overrides

Every option in this section is framed as **inherit or override**, never as
on/off. Command-line options do not sit at the top of Ansible's precedence in
every case; playbook keywords and variables can outrank them. Saying
`Become = no` would be a claim about the run that Chroma cannot make.

```text
Remote user                     Become CLI override
> Inherit from Ansible          > Inherit from Ansible
  deploy      last used        Enable (-b)
  Custom…

Ask become password             Vault
> No CLI prompt flag            > Inherit from Ansible
  Yes (-K)                        Ask for a password (--ask-vault-pass)
```

| Choice | argv |
|---|---|
| Inherit | *nothing* |
| Remote user `deploy` | `-u deploy` |
| Become enable | `-b` |
| Ask become password | `-K` |
| Ask vault password | `--ask-vault-pass` |

### 10.1 `-b` and `-K` are separate questions

They are separate options in Ansible, and `-K` is meaningful without `-b`:
become may be enabled by the playbook or by configuration, and the password
still has to be asked for. Binding them into one yes/no would make one
reachable only through the other.

### 10.2 Preview wording

The preview says `CLI remote-user override: deploy`, not
`Remote user = deploy`, for the reason at the top of this section.

### 10.3 Vault ids

`--vault-id dev@…` and multiple ids are real and common. M1 offers inherit and
`--ask-vault-pass` only; the model stores a list of vault options so that adding
ids is a picker change. `Vault IDs…` is named in §16 as absent, not forgotten.

---

## 11. Vault and the credential boundary

> **Chroma never collects, stores, forwards, caches or writes a password.**

Not to a configuration file, not to session state, not to the repeat slot
(§14.3), not to a log, and not into `argv`.

`-K`, `--ask-vault-pass`, `sudo`, an SSH passphrase and an `aws sso login`
prompt are answered **in the terminal Ansible runs in**, by Ansible. That is
simpler and safer than any arrangement in which Chroma has the secret.

`chroma-vault` is a separate component and a separate concern. Its keys share
the `<leader>a` prefix (§18) because Ansible Vault is Ansible's, not because the
two modules interact. Nothing in this module reads a vault, decrypts one, or
supplies a password to one.

One consequence, stated rather than discovered: `ansible-inventory` does not
decrypt vaulted variables even when a password is available — measured, §20.5 —
so vaulted values cannot reach this module through inspection either.

---

## 12. Check and diff

```text
Execution mode          Diff
> Run                   > Off
  Check (--check)         On — may print sensitive file contents
```

### 12.1 Check mode is Ansible's semantics, not Chroma's guarantee

The interface says `Check (--check)`. It does **not** say *safe dry run*: a task
may set `check_mode: false` and then run normally under `--check`. Describing it
as safe would be Chroma promising something only the playbook can deliver.

### 12.2 Diff is off by default and carries its warning

Ansible's own documentation warns that diff mode can display sensitive
information. The option is never defaulted on, and the warning is part of the
choice rather than a note somewhere else.

---

## 13. Async generation model

### 13.1 The measured problem

`vim.system` callbacks arrive in completion order, not start order. This
repository has already paid for that once: Managed Terraform claims a generation
per plan and discards callbacks whose generation is stale, because a slower
earlier plan could overwrite a newer one that had just been read.

The planner has the same shape and worse consequences, since the stale result
populates a picker: choose inventory A, cancel, choose B, and A's groups arrive
and are presented as B's.

### 13.2 The model

Every planner run holds a `planner_run_id`. Every inspection holds a
`generation`, taken when it starts.

The generation is invalidated by: changing the playbook selection, changing the
working directory, changing the inventory sources, cancelling any step, and
starting a new planner run.

```lua
if mine ~= state.generation then
  return
end
```

That check runs **before the callback touches any state or any UI** — not after
a partial update, and not in the renderer.

A discarded callback is not an error and is not reported. It is the expected
outcome of the operator having moved on.

### 13.3 This is not hardening for later

It is part of the concurrency model and lands in the first commit that spawns a
subprocess. Retrofitting it means auditing every callback that already exists.

### 13.4 Inspection is asynchronous and cancellable

Dynamic inventory can contact an external system and take as long as that
system takes. Nothing blocks the editor:

```text
Resolving inventory…   [Cancel]
```

Cancel invalidates the generation and, where the process supports it,
terminates it.

---

## 14. Repeat the last run

### 14.1 Why it exists

The full planner is up to twelve prompts. Somebody who runs the same invocation
twenty times a day needs one keystroke, and §1.3 forbids solving that with a
configuration file.

```text
<leader>ar   new planner run
<leader>aR   repeat the last invocation
```

### 14.2 Repeat does not run anything

It goes straight to the final preview (§15) and still requires an explicit
`Run? [y/N]`. Every path in this module ends at the same gate.

### 14.3 What is remembered, and where

Session memory only. Neovim restarts to a clean state; M1 writes nothing to
disk. A persistent form, if it is ever wanted, is an explicit state model with
its own design — not a side effect of having clicked something.

| Remembered | Never remembered |
|---|---|
| the frozen working directory | any password |
| playbooks | host variables |
| inventory sources, in order | vault contents |
| tags, limit | the resolved host snapshot (§14.5) |
| `-u`, `-b`, `-K`, vault options | the inspection consent (§6.4) |
| check and diff | |

### 14.4 Repeat re-resolves the executable

`ansible-playbook` is looked up again, in the same way and in the same
environment, and the run is refused if it is gone or if `PATH` now resolves it
elsewhere. Repeating an absolute path recorded an hour ago would run a program
nobody chose.

The working directory and the playbooks are re-checked the same way: still a
directory, still readable regular files.

### 14.5 The target snapshot does not survive

If the previous run's preview said `4 hosts`, the repeat preview does not repeat
that number. It shows `Target snapshot not refreshed`, and offers
`Refresh target inspection` — which is an active inspection and therefore passes
the gate in §6 again. Refreshing is never required to repeat.

---

## 15. Preview and confirmation

```text
ANSIBLE EXECUTION

Working directory      /work/operations
Playbook               plays/site_upgrade.yml
Inventory              ../inventories/dev/hosts.yml
Tags                   no CLI filter
Limit                  webservers
CLI remote-user        deploy
CLI become override    enabled
Ask become password    yes
Vault                  inherited
Mode                   run
Targets reported now   4 hosts

argv

  [0]  /usr/bin/ansible-playbook
  [1]  -u
  [2]  deploy
  [3]  -K
  [4]  -b
  [5]  -i
  [6]  ../inventories/dev/hosts.yml
  [7]  -l
  [8]  webservers
  [9]  plays/site_upgrade.yml

Run? [y/N]
```

### 15.1 Order

```text
executable → options → positional playbooks last
```

A playbook name in the middle of the flags is valid and reads as a mistake.
Making `--` mandatory before the positionals is **not** frozen here: it would
have to be measured against the whole supported range of ansible-core first,
and it is not needed to solve the presentation problem.

### 15.2 `argv[0]` is shown resolved

The preview shows the absolute path that will start, because the preview and the
executor read **one prepared array**. Measured on Neovim 0.12.4: `jobstart`
validates `argv[0]` before it looks at the `env` and `cwd` it was given, and
raises `E475` after the terminal window already exists. Resolving first, and
showing what was resolved, is the only way the preview and the run describe the
same command.

### 15.3 There is no shell rendering

No line joins the arguments into something that looks like a command line. The
array never passes through a shell, and a rendering joined with spaces
misrepresents any argument containing a space, a quote or a semicolon — and that
is the line people copy.

### 15.4 The default is no

> **Only an explicit affirmative starts the process.** No, cancel, escape, a
> closed selection, a dismissed prompt and an answer that never arrives all mean
> that nothing runs.

### 15.5 The terminal

One Run is one new process with an identity of its own, in a terminal that
survives every exit status including zero, with `auto_close = false` and the
interactive defaults kept so that `BECOME password:` can be answered.

Because switching off the closing also switches off the library's failure
notice — the `TermClose` handler that reports a non-zero status lives inside the
`auto_close` branch — this module installs its own `TermClose` that reports and
closes nothing.

**This is deliberately a second implementation, not a call into
`chroma.tasks.run`.** The own modules are self-contained so that any of them can
be lifted into its own repository without edits, which is why
`chroma-vault/runtime.lua` and `chroma-terraform/runtime.lua` are already the
same policy written twice. The cost is that two copies can drift, and the answer
is the same as there: a test runs the invariants against both (§19.6).

#### 15.5.1 The run counter is one counter for all of Chroma

Two implementations may not mean two counters. A terminal's identity in the
library is its command, working directory, environment and **count**, and it has
no room for the module that opened it — so a planner counting `1, 2, 3` beside
Project Tasks counting `1, 2, 3` can produce two runs with the same identity.
That is not hypothetical: a Project Task declaring
`argv: ["ansible-playbook", …]` in the same directory is exactly the case the
boundary in §2 says a repository is allowed to write, and the first run of each
would collide.

The counter is therefore **global to Chroma, not per module**, and it is reached
without requiring another module:

```lua
local id = (vim.g.chroma_terminal_run_id or 0) + 1
vim.g.chroma_terminal_run_id = id
```

A well-known variable rather than a shared Lua module, because a shared module
would end the self-containment this section just paid thirty lines to keep. A
module lifted into its own repository still works: it becomes the only writer of
a counter nobody else increments.

`chroma.tasks.run` moves onto the same variable in the same commit. Its private
counter was correct while it was the only opener of terminals, and stops being
correct the moment a second one exists.

---

## 16. Failure and degradation

> **Failure to inspect must not become failure to execute when the operator can
> still describe the execution explicitly.**

| What happens | What the planner does |
|---|---|
| `ansible-playbook` not on `PATH` | Refuse at the start, naming the tool. Nothing else runs |
| `ansible-inventory` not on `PATH` | No group or host discovery. Limit offers `No limit` and `Custom pattern…`. The run proceeds |
| The gate (§6.3) is declined | The planner ends. No subprocess was started |
| `--graph` exits non-zero | `Inventory inspection failed` + Ansible's own output. `Retry` / `Continue without discovered groups and hosts` / `Cancel` |
| `--graph` output does not parse | Identical to the line above. Never partial (§7.3) |
| `--list-tags` fails | `Tag inspection failed` + output. `Retry` / `No tag filter` / `Custom tag…` / `Cancel` |
| `--list-hosts` fails | The preview omits `Targets reported now` and says so. The run proceeds |
| The frozen directory is gone at run time | Refuse, naming the path |
| A playbook is unreadable at run time | Refuse, naming the path |
| Repeat: executable gone or moved | Refuse (§14.4). Nothing runs |
| A callback's generation is stale | Discarded silently (§13.2). Not an error |

There is deliberately **no** classification of *why* an inspection failed. Two
of the earlier drafts of this design offered `Vault credentials required →
Retry using configured credentials`; Ansible does not report a machine-readable
reason, and a menu that names one is a guess wearing a diagnosis's clothes.
Measured, §20.5: the vaulted-inventory case that motivated it does not even
fail.

Every failure shows Ansible's own output. Chroma does not summarise, rewrite or
truncate it.

---

## 17. Component contract

`components/ansible.json` gains a module and two required tools:

```json
{
  "tools": {
    "required": [
      { "id": "ansible-playbook", "reason": "running a playbook the operator has composed" },
      { "id": "ansible-inventory", "reason": "listing the groups and hosts an inventory declares" }
    ],
    "optional": [
      { "id": "ansible-doc", "reason": "documentation lookup through keywordprg" }
    ]
  },
  "nvim": { "modules": ["chroma-ansible"] }
}
```

Both are required rather than one required and one recommended: the module
promises domain-aware inventory discovery, and a machine with only
`ansible-playbook` would satisfy the manifest while being unable to do half of
what the component says it does. Both ship in ansible-core, so requiring both
costs nobody an extra installation and stops a partial install from looking
healthy.

This reverses the other half of `568c28e`, which removed the required `ansible`
executable when the buffer-driven runner went. It needs its own row in the
contract-changes table of `doc/CONTRACT.md`.

Nothing else in the component changes: `nvim-ansible` stays for filetype
detection, `ansible-doc` through `keywordprg`, and `gf` into a role.

### 17.1 Module layout

```text
lua/chroma-ansible/
  init.lua      setup, keymaps, the planner's step order
  planner.lua   the run's state, generations, invalidation
  inspect.lua   the subprocesses, and the gate that guards them
  graph.lua     the --graph parser, and nothing else
  argv.lua      decisions → the prepared array
  preview.lua   rendering and the confirmation
  run.lua       the terminal
```

Set up by `chroma.modules` from the component contract, with `keymaps = true`,
exactly as the other three own modules are.

---

## 18. Keymaps

| Key | Does |
|---|---|
| `<leader>ar` | New Ansible run |
| `<leader>aR` | Repeat the last Ansible invocation |

Neither is mapped when the `ansible` component is disabled, because the module
is not set up at all — the same rule the Terraform and AWS keys follow.

### 18.1 `<leader>ar` is being reclaimed

That key was removed in `568c28e` and its removal is recorded in the
contract-changes table and in `doc/KEYMAPS.md`. Reclaiming it needs its own row
saying so, or the contract history reads as a circle. The row must say what
changed: the key returns, the model does not (§2.4).

### 18.2 The `<leader>a` group heading

The heading is registered when **`ansible` or `vault`** is enabled.

Half of that is already done, and not by this module. The defect this section was
written against — the heading following `ansible` while all seven keys under it
belonged to `vault` — was fixed on its own, because it was a defect with or
without a planner: the gate is `vault`, covered by two cases in
`tests/test_gating.lua` and recorded in `doc/DECISIONS.md`, "A heading follows
its keys".

Plain **`ansible` or `vault`** would have been the wrong fix at that moment. With
no planner, `ansible` alone still contributes no key under `<leader>a`, so an
`or` would have kept the second half of the defect — a heading over an empty
list — while claiming to have closed it.

So what this module owes the gate is one component name. When `<leader>ar` and
`<leader>aR` exist, `ansible` earns its place there and the gate becomes a list
of the two rather than one name.

The name stays `Ansible`, because Ansible Vault is Ansible's.

### 18.3 No collision

`ar` and `aR` are free: `chroma-vault` holds `av`, `aV`, `ae`, `ad`, `aw`, `ak`.

---

## 19. Tests and mutations

Every case below must be killed by a mutation, and the mutations are run rather
than declared.

| # | What is covered | Mutation | Expected |
|---|---|---|---|
| 19.1 | The `--graph` parser, against captured fixtures | take a name as the next word rather than the rest of the line | the host-with-a-space case fails |
| 19.2 | A truncated or unrecognised graph yields no result | drop the trailing-newline check; let an orphan line fall back to `all`; stop clearing the depth stack | three separate all-or-nothing cases fail |
| 19.2a | A group's variables are never read as a host | remove the `{…}` guard | the group-vars case fails, and a secret reaches a picker |
| 19.3 | No hostvars are requested | change `--graph` to `--list` in the inspector | the argv case for the inspector fails |
| 19.4 | The gate precedes every first subprocess | move the gate after the first `--graph` | the ordering case fails |
| 19.5 | The frozen cwd is not re-read | replace the stored path with `getcwd()` at run time | the freeze case fails after a `:cd` |
| 19.6 | The terminal invariants match `chroma.tasks.run` | set `auto_close = true` in this module | the agreement case fails |
| 19.7 | Stale callbacks change nothing | remove the generation check | the out-of-order case fails |
| 19.8 | `No limit` emits nothing | emit `-l all` | the argv case fails |
| 19.9 | Multi-select tags emit repeated `--tags` | join them with a comma | the argv case fails |
| 19.10 | Inherit emits nothing for `-u`, `-b`, `-K`, vault | emit a default | four argv cases fail |
| 19.11 | Positional playbooks come last | emit them before the options | the argv order case fails |
| 19.12 | `argv[0]` is absolute in preview and run | pass the bare name | the prepared-array case fails |
| 19.13 | Repeat re-resolves the executable | reuse the stored absolute path | the repeat-refusal case fails |
| 19.14 | Repeat carries no host snapshot and no secret | copy the snapshot into the repeat slot | the repeat-state case fails |
| 19.15 | Inspection failure does not block the run | make a failed `--list-tags` end the planner | the degradation case fails |
| 19.16 | No Ansible output reaches a log | log the inspector's stdout | the logging case fails |
| 19.17 | The architecture boundary with Project Tasks | `require("chroma.tasks.run")` in this module | the architecture case fails (§2.2) |

Fixtures for 19.1 are captured from a real `ansible-core 2.21.2` and committed
under `tests/fixtures/ansible/graph/`. The note saying which command produced
each one is in a `README.md` beside them rather than inside them: a fixture
here is compared byte for byte, down to the final newline, so a comment header
would make it stop being the thing it exists to be.

---

## 20. Measured assumptions

Run on **ansible-core 2.21.2** against a prepared inventory holding a plain
host variable and one `group_vars` file encrypted with Ansible Vault. Each line
is a command that was run, not a documentation claim.

**20.1 `ansible.cfg` is not searched for upward.** With an `ansible.cfg` in
`parent/` and none in `parent/child/`, `ansible --version` reported
`config file = None` from `parent/child` and
`config file = …/parent/ansible.cfg` from `parent`. The documented order —
`ANSIBLE_CONFIG`, the current directory, `~/.ansible.cfg`,
`/etc/ansible/ansible.cfg` — was read rather than exercised in full; the
upward part is what §3.3 rests on, and that part was run. It is why the
interface may offer ancestors as candidates but may not claim Ansible would
find them.

**20.2 `--tags` accumulates.** `--tags common --tags security --list-tasks`
listed the tasks tagged `common` and `security` and omitted the third. Repeating
the flag is therefore correct and no string needs joining (§8.2).

**20.3 `--list` prints host variables in plaintext; `--graph` does not.** A
planted `secret_token` appeared verbatim in `--list` output and did not appear
in `--graph` output. `ansible-inventory --help` offers no way to suppress
variables from `--list`; `--vars` only adds them to `--graph`. Decided §7.1.

**20.4 `--list-tags` does not need an inventory.** With no `-i`, exit status was
0 with `[WARNING] Could not match supplied host pattern, ignoring: …`, and the
tags were listed. This decided §8.4.

**20.5 Vaulted variables neither block inspection nor decrypt.** With a
Vault-encrypted `group_vars` file and no password, both `--list` and `--graph`
exited 0. With the password supplied, `--list` still returned the value as
`{"__ansible_vault": "$ANSIBLE_VAULT;1.1;AES256…"}`. This removed the
credential-classification menu from §16 and informs §11.

**20.6 `--graph` ignores `--limit`.** `ansible-inventory --graph -l PATTERN`
returned the whole tree for a pattern matching nothing. `--graph` cannot
validate a host pattern; §9.4 uses `--list-hosts` instead.

**20.7 Neovim 0.12.4: `jobstart` validates `argv[0]` before `env` and `cwd`.**
Measured with an executable present only in the task's `PATH`, and again with
one present only in the task's working directory: both raise
`E475: … is not executable`, and inside the terminal library that happens after
the window already exists. This decided §15.2.

**20.8 snacks.nvim at the pinned `882c996`.** `terminal.open()` starts a new
terminal; a table command runs without a shell; `env` extends the inherited
environment rather than replacing it; a terminal's identity is its command,
directory, environment and count. `auto_close` defaults on through
`interactive`, and the `TermClose` handler that reports a non-zero status lives
inside that branch. This decided §15.5.

**20.9 Neovim 0.12.4: `vim.ui.input` accepts a `completion` field**, taking a
`:command-completion` type. This is what §4.3 uses, so path selection needs no
plugin.

---

## What is deliberately absent

Named so that they are not mistaken for oversights, and so that a later reader
can tell a decision from a gap.

```text
multi-select of hosts                  §9.1  — the operator writes the pattern
--vault-id and multiple vault ids      §10.3 — the model carries the list
roles as a scope selector              §8.3  — wrong Ansible semantics
--list-tasks as a mandatory screen           — more steps, little gained
persistent defaults on disk            §14.3 — session memory first
a configuration file                   §1.3  — must never unlock a feature
support for company wrappers           §2.3  — Project Tasks already cover it
a mandatory `--` before positionals    §15.1 — unmeasured, and not needed yet
```

---

## Sign-off — given 2026-08-12

Five decisions in this document were taken while writing it rather than handed
down. All five were confirmed by the owner, and two corrections came back with
them.

1. **§15.5** — the planner launches its own terminal instead of calling
   `chroma.tasks.run`. **Confirmed**, in the owner's words: "moduły mają być
   self-contained".
2. **§7.3** — a partially parsed graph is a failure, never a partial list.
   **Confirmed**: "all or nothing … nigdy nie pokazujemy częściowej listy".
3. **§6.3** — the gate is shown even when inventory is
   `Use Ansible configuration`. **Confirmed**, and corrected — see below.
4. **§4.1** — M1 selects exactly one playbook while the model carries a list.
   **Confirmed**, and the same shape for inventory sources.
5. **§4.2** — the buffer suggestion tests only "readable regular file ending in
   `.yml`/`.yaml`". **Confirmed**: "Nie czyta YAML-a … To ma rozstrzygnąć
   Ansible".

**Correction 1 — the consent is pinned to what the prompt named.** §6.4 said one
yes covers the planner run. It now says the yes is bound to the working
directory, the playbooks and the inventory sources, and that changing any of
them asks again. The gate names those three values, so a consent cannot outlive
them.

**Correction 2 — one terminal run counter for all of Chroma.** §15.5.1 is new.
Two self-contained implementations may not mean two counters starting at one:
the library builds a terminal's identity from command, directory, environment
and count, so a planner run and a Project Task running the same `ansible-playbook`
in the same directory would collide on their first run each. The counter moves to
a well-known variable that needs no shared module, and `chroma.tasks.run` moves
onto it in the same commit.

Two rows are owed to `doc/CONTRACT.md`'s contract-changes table before any code
lands: the reclaimed `<leader>ar` (§18.1) and the required Ansible tools
(§17). Both describe an editor that does not exist yet, so they land with the
commit that makes them true rather than ahead of it.

The entry in `doc/DECISIONS.md` is settled and did not wait: *"The Ansible
runner went, and the plugin stayed"* now records the reversal, keeps every
reason the old `<leader>ar` was removed, and states what is not reversed — the
generic layer stays domain-blind in both directions. That one was not a
description of unwritten code; it was a decision the owner had already taken,
and leaving it standing would have made this document argue with the one that
governs it.

This document has no "otherwise" left in it, so implementation splits into
stages. Each stage is one commit closing one invariant, with its tests and its
mutations in the same commit.
