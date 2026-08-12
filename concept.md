# Chroma Tasks — the execution layer

**Built. Milestone 1 is `lua/chroma/tasks/`, released in v2.5.0.** This
document was written before any of it and froze the contract it was written
against; it is kept because the contract held and the reasoning behind each
rule is not recoverable from the code.

Read it for **why**, not for **what**. The invariants now live in `CONTRACT.md`
under *The execution layer*, and the four decisions that shaped them are in
`DECISIONS.md`. What is only here is the argument that produced them, the
measurements each rests on (§12), and the work deliberately deferred (§14).

**The section numbers are load-bearing.** Seven source files and one test cite
this document by section — `source.lua` §3, `trust.lua` §4, `cwd.lua` §5,
`command.lua` §6, `preview.lua` §7, `run.lua` §8, the architecture test §10.
Sections may be rewritten; they may not be renumbered or removed without
following those citations.

Where a rule here rests on how another program behaves, it says what was
measured and on which version. Nothing rests on how an API ought to work. The
versions are the ones it was measured against — Neovim 0.12.4 and snacks.nvim
at the pinned `882c996` — and a later measurement supersedes the note, not the
rule.

---

## 1. The problem

Chroma covers Ansible, Terraform, OpenTofu, Terragrunt, Kubernetes, Helm, the
AWS CLI, Docker, and whatever else somebody's job requires. Running a process
is not the hard part.

The hard part is that **there is no correct way to lay out or run
infrastructure**. Two repositories using the same tool can be organised
completely differently:

```text
repo-a/                 repo-b/                 repo-c/
├── playbooks/          ├── plays/              ├── automation/
├── roles/              ├── inventory/          │   ├── beta/
└── inventories/        └── collections/        │   └── production/
                                                └── Makefile
```

and their owners run them completely differently:

```bash
ansible-playbook site.yml -i inventories/prod

ansible-playbook -K -b -u deploy -i ../inventories/dev/hosts.yml \
  --ask-vault-pass kubernetes.yml

make deploy ENV=prod SERVICE=kubernetes
```

All three are correct. Chroma cannot safely infer which directory a command
belongs in, whether `-K` is wanted, whether there is a vault password, which
remote user applies, or whether the real entry point is a wrapper somebody's
employer requires instead of `terraform`. The same is true of every other tool
on that list.

So Chroma does not learn the shape of somebody's infrastructure. It provides a
way for them to say:

> In this project, this operation is this command, from this directory, with
> these arguments.

---

## 2. The principle

The execution layer does not implement an Ansible workflow, or a Terraform
workflow, or a Helm workflow. It implements a **task**, which is:

```text
what to run  +  where to run it  +  what environment  +  what to show first
```

and then runs it in a terminal. `ansible-playbook`, `terragrunt`, `make`,
`just`, `./scripts/deploy` and an internal company CLI are all the same kind of
thing to it: an executable.

There are two gates between a repository's file and a running process, and
both are the user's:

```text
trust the task definitions        →  "Chroma may read these"
explicit Run Task + confirmation  →  "run this one, now"
```

Nothing is executed while configuration is read. Nothing is executed because a
repository was opened.

---

## 3. A task, and where tasks come from

In Milestone 1 there is exactly one source: `.chroma/tasks.json` in the project.
The **project root is the directory that contains it** — not a guess, not a git
root. That is what makes `cwd` mean one thing.

**Discovery.** Run Task starts from Neovim's effective working directory and
searches **upward only**; the first ancestor holding `.chroma/tasks.json`
defines the project root, and finding none means there are no project tasks.

Discovery stops at the **first filesystem entry** with that name. If the entry
is not an acceptable regular file, discovery fails there and does not carry on
to a parent — otherwise a directory named `tasks.json` in a subproject would
silently hand execution to the tasks of the repository above it, which is a
fallback wearing a search's clothes.
Nothing searches downward, and no plugin's idea of a project is consulted —
`project.nvim` is navigation, and an execution boundary may not rest on its
heuristics.

This is the one place the working directory is used, and the distinction is
deliberate rather than an inconsistency with §5: the search needs *a* starting
point, and the only alternative is the current buffer, which Milestone 1
excludes on purpose. A task's own working directory is never derived from it.
The consequence is stated rather than hidden: opening `/repo/foo.yml` while
Neovim's directory is outside `/repo` does not make `/repo` a task project.

**The source must be a regular file.** Before `vim.secure.read()` is called, the
resolved path must be a readable regular file — a symlink to one is acceptable,
and trust then follows the real target as Neovim does. Anything else, including
a directory named `tasks.json`, is a named refusal. This is not pedantry:
`vim.secure.read()` inspects the path itself, and for a directory it offers a
fourth choice, `allow`, which is directory trust — the thing this contract
forbids. A naive `read(path)` would hand that decision to whoever created the
directory.

```json
{
  "schema": 1,
  "tasks": [
    {
      "id": "ansible-beta",
      "name": "Run Kubernetes beta",
      "group": "ansible",
      "cwd": { "mode": "relative", "path": "plays" },
      "argv": [
        "ansible-playbook", "-K", "-b", "-u", "user",
        "-i", "../inventories/dev/kubernetes_infrastructure/hosts.yml",
        "--ask-vault-pass",
        "kubernetes.yml"
      ]
    }
  ]
}
```

`schema` is required from the first commit, and a file without it is invalid
rather than assumed to be version 1. A format that ships into other people's
repositories cannot acquire versioning later.

### Schema 1, exactly

The component loader already refuses a contract with an unknown field rather
than ignoring it, and this is the same kind of document read the same way. Every
rule below is a refusal, and every refusal names the task and the field.

**The document.** An object with exactly two keys, `schema` and `tasks`. Any
other key is an unknown field and invalid. `schema` is the integer `1`; any
other value is an unsupported schema, which is a different error from a
malformed one. `tasks` is an array, possibly empty — a file that declares no
tasks is valid and means there are none.

**A task.** An object with `id`, `name`, `cwd` and `argv` required, `group` and
`env` optional, and no other keys.

```text
id      non-empty string, unique within the document
name    non-empty string; what the picker shows
group   non-empty string when present; metadata only
cwd     object, see below
argv    array of at least one string
env     object whose keys and values are all non-empty strings
```

An empty string is never a valid `id`, `name`, `group`, `env` key or `argv[0]`.
A duplicate `id` is invalid — not last-wins, not first-wins, because both are a
silent choice between two things somebody wrote on purpose. `null` anywhere is
invalid; a field that is absent is absent, and one that is present has a value.

**`cwd`.** An object with a `mode` of `project` or `relative`, and nothing else
in Milestone 1.

```text
mode = project     `path` must be absent
mode = relative    `path` is required, a non-empty string,
                   and must not be absolute
```

`path` is always relative to the project root. An absolute `path` is invalid
rather than silently honoured, and whatever it resolves to is checked against
the containment invariant in §5 anyway.

**`argv`.** Every element is a string. Numbers and booleans are invalid rather
than coerced: a task that means `-p` `8080` writes `"8080"`, and a document that
cannot decide is a document that will produce a different command in a different
JSON library.

`group` is metadata. It organises the picker and nothing else: a task in group
`terraform` gets no Terraform behaviour, no default arguments and no special
handling. The engine has no reason to know that `make docs` is a different kind
of thing from `terraform plan`.

Loader errors name the place, not the fact:

```text
.chroma/tasks.json: task "ansible-run": cwd.mode "foo" is not supported
```

not `invalid config`.

### Why JSON, and what that does and does not buy

A repository must not hand Neovim executable code that runs because somebody
opened the directory. JSON cannot start a shell, delete files or change the
editor's configuration while it is being read.

That is the whole of what the format buys, and the original version of this
document overstated it. The honest statement is:

> `tasks.json` cannot execute anything while it is read, but it defines
> processes the user can later run, so a project's task file is treated as
> **untrusted executable configuration**.

Which is why the next section exists.

---

## 4. Trust

### Availability

| | |
|---|---|
| Chroma itself | Neovim >= 0.12, as the contract already states |
| Project tasks | **Neovim >= 0.12.3** |

Below 0.12.3 project tasks fail closed: they do not load, and the refusal names
the reason and the upstream fix rather than saying the feature is unavailable.
This is a floor for one feature, not a raise of Chroma's floor, and it is
stated by upstream rather than by us — see the measured note in §12.

`:checkhealth chroma` reports that gate as its own status. Health used to ask
only whether every editor API this configuration calls is present and, when
they all were, end the section green — which on 0.12.0 to 0.12.2 was a green
report about an editor where project tasks refuse to run. It now carries
`Project tasks` as a section of its own, and below the floor warns —
`Project tasks unavailable — Project tasks need Neovim 0.12.3 or newer, and
this is …` — with the upstream fix named as the advice. A warning rather than
an error, because Chroma itself supports that editor and one feature does not.
0.12.2 stays a correct Chroma; health stopped claiming that everything in it is
available.

Health asks the version and nothing else. It does not look for a
`.chroma/tasks.json`, read one, or ask the trust database about it: trust is
evaluated on an explicit Run Task and nowhere else, and a health check that
raised the modal — or recorded a decision — would be doing the one thing this
contract forbids it to do.

The floor is owned by `chroma.tasks.availability` rather than by health, and
that was not tidiness. It had lived privately in `health.lua`, so health
reported "unavailable" while the runtime checked nothing at all and would have
run tasks on 0.12.0. Both sides ask the same module now, and the test suite
substitutes the version there.

### When trust is evaluated

Only on an explicit **Run Task**. Never on `VimEnter`, never while a project is
being opened, never in the background.

`vim.secure.read()` asks its question with `vim.fn.confirm`, which is a modal.
Evaluating trust at startup would put a modal in front of everyone who clones a
repository, before they have asked Chroma for anything. Trust is also resolved
**before the picker opens** — a modal inside a picker is not an acceptable
sequence.

**Definitions are read per Run Task and are not cached for the session.** Not
the refusal, and not the successful load either: after `view → :trust` the next
Run Task has to see the new decision, and after an edit to `tasks.json` it has
to see the new tasks — the trust decision is bound to the old contents anyway.

This is the opposite of how `chroma.components` loads the component contract,
which is read once per session on purpose because it is part of an immutable
release tree. A project's task file is a file somebody is editing. Copying that
cache here would produce a Run Task that still says "untrusted" after the user
has trusted it, and no error anywhere.

### The flow, as it actually is

Neovim offers `ignore / view / deny` for a **file**. There is no `allow`: the
prompt itself says to choose *view* and then run `:trust`. So the first run of a
task in a new repository is two steps, and the design says so rather than
pretending otherwise:

```text
Run Task
  → Chroma explains that project task definitions need Neovim's trust,
    and that the modal about to appear will call this "exrc"
  → vim.secure.read()
  → view                    (the file opens read-only; read() returns nil)
  → the user reads it
  → :trust        with NO filename
  → Run Task again          (now the definitions load)
```

Chroma does not try to resume the picker after `:trust`. There is no hook that
makes that reliable, and a second explicit Run Task is simpler and more
predictable than a flow that continues by itself.

**Chroma must never tell anybody to run `:trust .chroma/tasks.json`.** Neovim's
own documentation warns that `:trust [file]` has a TOCTOU risk and directs the
user to view the file and run `:trust` with no argument. Our instructions follow
Neovim's, or we are steering people into a hazard its authors documented.

The explanation Chroma prints before the modal is not decoration. The modal
begins `exrc: Found untrusted code.` — a string in Neovim's runtime that we
cannot change, naming a feature the user never asked for.

### Five states, and none of them is silence

```text
missing          there is no .chroma/tasks.json
untrusted        it exists and has not been decided on
trusted          decided, and the contents still hash to the decision
denied           decided against
unknown/refused  the trust state could not be established
```

`vim.secure.read()` returns `nil` for four of these, which is why Chroma needs a
small adapter of its own. The distinction that matters most is **denied**:
Neovim writes it as a sticky decision and never prompts again, so a user who
once chose *deny* has no project tasks, forever, with no explanation. Reporting
that as `No project tasks configured` would hide a real state — the failure this
project has an audit habit of hunting. Denied says what it is, and may mention
`:trust ++remove` as the way back.

The adapter answers with the same three things Neovim itself compares: the real
path, the current contents' `sha256`, and the entry in the trust database. The
`!` marker alone is not enough to know whether the modal is coming — a file that
was trusted and has since been edited has an entry whose hash no longer matches,
and Neovim will ask again. Since the explanation Chroma prints has to be printed
*before* the modal, the adapter must be able to tell "trusted" from "trusted
once, changed since" without calling `read()`.

**One snapshot is authoritative, and it is the adapter's.** Reading the file to
hash it and then calling `read()` reads it twice, and a file can change in
between: the precheck says trusted, the contents change, and the modal appears
after Chroma has promised there would not be one. So the snapshot the adapter
took is the one that is used, and each state says for itself what happens next:

```text
missing          there are no project tasks; nothing else is said

trusted          parse that exact snapshot
                 vim.secure.read() is not called at all

untrusted        explain the "exrc" modal that is about to appear
                 call vim.secure.read() only to put Neovim's own question
                 in front of the user, and load nothing this invocation

denied           refuse, saying it was denied, and offer :trust ++remove
                 vim.secure.read() is not called: Neovim sees the `!`,
                 returns nil and asks nothing

unknown/refused  refuse with the generic trust-database wording
                 vim.secure.read() is not called
```

Three of the five never reach `read()`, which is what keeps the other promise:
Chroma never announces a modal that is not going to appear.

**The snapshot is bytes, not lines.** Since a trusted snapshot is parsed without
`read()` ever seeing it, how the file is read is part of the security boundary
and not an implementation detail. Neovim opens the file in binary mode, reads it
whole and takes `sha256` of exactly those bytes. Chroma does the same, and:

```text
bytes hashed  ==  bytes authorised  ==  bytes parsed
```

Reading lines and joining them would produce a second representation of the
file — one that can differ in line endings and in a final newline — and then
Chroma would be answering a different question from the one Neovim answered.

Security is unchanged by any of this: the hash that authorises the snapshot is
the hash Neovim recorded, compared the way Neovim compares it. After `:trust`,
the next Run Task starts again from a fresh snapshot, which is the same rule as
the no-caching above.

One limit of the promise, stated rather than left to be discovered. Neovim's
`read()` consults the trust database itself, so between Chroma's look and that
call another process can change it — a `!` written in that window means the
explanation is printed and no modal appears. Nothing unsafe follows: the state
only ever moves towards refusing. What can be wrong is the announcement, and
only while somebody else is editing the trust database at that moment.

The adapter reads Neovim's trust database, and that is a deliberate coupling to
another project's implementation detail. It carries two obligations:

- a test pins the format Chroma expects, so an upstream change surfaces as a
  failing test rather than as a wrong sentence about security;
- if parsing fails, the state degrades to *unknown/refused* and the message
  becomes the generic "Neovim's trust database refuses this file". Chroma never
  guesses a more specific security state than it can establish.

---

## 5. Working directory

Milestone 1 has two modes:

```text
project     the project root
relative    a path below the project root, given by the task
```

and one invariant that belongs to all of them, present and future:

> **`realpath(resolved_cwd)` MUST equal `realpath(project_root)` or be a
> descendant of it, compared by path components.**

Both sides are resolved before comparison, so a symlink cannot leave the project
either:

```json
{ "cwd": { "mode": "relative", "path": "../../../etc" } }
{ "cwd": { "mode": "relative", "path": "foo" } }     // repo/foo -> /etc
```

Both refuse:

```text
Task cannot run: working directory escapes project root.
```

A textual prefix comparison does not implement this. `/project` is a prefix of
`/project-evil`, and the containment check has to be on path components.

**After project discovery, Neovim's current directory is never consulted again
when a task's working directory is resolved.** `:cd`, `:lcd`, `:tcd` and any
plugin can move it, which makes it far too easy to change by accident for
something that decides where `terraform apply` runs. Discovery uses it once, to
know where to start looking; nothing after that does.

---

## 6. Execution

`argv` only. An array of strings, run without a shell:

```text
["ansible-playbook", "-K", "-b", "-u", "user",
 "-i", "../inventories/dev/hosts.yml", "--ask-vault-pass", "kubernetes.yml"]
```

There is no command string, no shell mode and no quoting to implement. Nothing
passes through a shell and **`argv[1..]` reach the process byte for byte**.
`argv[0]` is the one element that changes: it is resolved by the rules below,
and what runs is the absolute path that resolution produced.

**A relative argument stays exactly what the task wrote.** Chroma does not
normalise, resolve or rewrite `../inventories/dev/hosts.yml`; the program
interprets it against the declared `cwd`, which is what makes this faithful
execution rather than one more layer that reinterprets commands.

### How `argv[0]` is resolved

`./scripts/deploy` is as legitimate an executable as `terraform`, and a task may
override `PATH`, so "is it on `PATH`" is not a question that can be asked before
the environment and the directory are known. Both are resolved first, and then:

```text
argv[0] contains no path separator   looked up in the task's effective PATH
                                     (inherited environment + overrides)
argv[0] is absolute                  used as written
argv[0] is relative and path-like    resolved against the task's working
                                     directory, not against Neovim's
```

If nothing executable is found that way, the task refuses by name before a
terminal is opened.

**And what is handed to the terminal is the resolved path, not the name the
task wrote.** This is not Chroma reinterpreting a command; it is the only way
the rules above can hold. Measured on Neovim 0.12.4: `jobstart` validates
`argv[0]` before it looks at the `env` and `cwd` it was given, so a bare name
is searched in the editor's `PATH` and a `./script` against the editor's
directory. Both refuse with `E475: … is not executable` — measured with an
executable that exists only in the task's `PATH`, and with one that exists only
in the task's working directory — and inside the terminal library that happens
after the window already exists. Resolving first, and passing the absolute path
the task's own environment and directory produced, is what makes the process
start where and as the task said. `argv[1..]` are untouched.

**`env` is an override, not a replacement.** The process inherits Neovim's
environment — `PATH`, `HOME`, `SSH_AUTH_SOCK`, an `AWS_REGION` somebody exported
before starting the editor — and the task's `env` overrides individual keys.
This is a v1 contract rather than a property inherited from a library.

**No shell injection is a guarantee. No CLI semantic injection is not.** A value
that reaches `argv` unchanged can still be a flag: whether `--check` is read as
an option, a value or a file name depends on the executable and the position,
and Chroma does not adjudicate that. Milestone 1 has no user-supplied input
values at all, but the rule is stated here because it is a property of the
execution model, not of the input types.

Credentials are the tool's business, not Chroma's. `ansible -K`,
`--ask-vault-pass`, `sudo`, `aws sso login` and `vault login` prompt in the
terminal and the user answers them there. Chroma does not collect, store,
forward, cache or write a password anywhere, and `tasks.json` is not a place to
put one.

---

## 7. The picker and the preview

**Choosing a task must work with nothing installed.** Tasks are core, and a core
feature may not require an external executable to be usable: `fzf` is
*recommended* in the core contract, not required, so a picker built on fzf-lua
would make `<leader>xr` unavailable on a machine that has a complete, valid
Chroma. Milestone 1 selects with `vim.ui.select()`. A better-looking picker may
replace it later without touching task semantics — which is the point of saying
this now rather than discovering it when somebody's laptop has no fzf.

Before anything runs, the user sees exactly what will run:

```text
Task
Ansible / Run beta

Working directory
/home/user/infra/plays

Environment overrides
AWS_PROFILE=beta

argv[0]  /usr/bin/ansible-playbook
argv[1]  -K
argv[2]  -b
argv[3]  -u
argv[4]  user
argv[5]  -i
argv[6]  ../inventories/dev/hosts.yml
argv[7]  --ask-vault-pass
argv[8]  kubernetes.yml
```

### Confirmation

> **Only an explicit affirmative starts the process.** No, cancel, escape, a
> closed selection, a dismissed prompt and an answer that never arrives all mean
> the same thing: nothing runs. The default is non-execution.

How that question is drawn is an implementation detail. What it may never be is
a prompt whose default is yes, or one where dismissing the UI counts as an
answer — this is the last gate before something applies infrastructure.

`argv[0]` is shown resolved, because that is what will run: the preview and the
executor read the same prepared array, and a preview showing the name while the
resolver had found something else would be describing a different command.

There is **no second, prettier line** showing the command as a shell would take
it. Since the array never passes through a shell, a rendering joined with spaces
misrepresents any argument containing a space, a quote or a semicolon — and it
is the line people copy. Presentation may not distort what it presents. If a
copyable shell command is ever wanted, it comes after a real, tested quoter
exists, not before.

---

## 8. The terminal

Tasks run through `Snacks.terminal.open()`. The plain shell on `<leader>xs`
keeps `Snacks.terminal.toggle()`, because a shell is a persistent surface and a
task is not: toggling finds the terminal whose command, directory, environment
and count match, and would hide it instead of running anything.

> **One Run = one new process.**

Task terminals set `auto_close = false` and keep the interactive defaults
(`start_insert`, `auto_insert`), so `BECOME password:` and `Vault password:` can
be answered the moment they appear.

> **A task terminal remains inspectable after the process ends, whatever the
> exit status.**

Including zero — a successful `terraform plan` is precisely the output somebody
wanted to read, and a window that disappears on success is the worst case of
this.

**Chroma owns the report of a failure, because switching off the closing
switches off the reporting too.** In the pinned terminal library the handler
that announces a non-zero exit is installed *inside* the `auto_close` branch, so
a task that sets `auto_close = false` gets neither the closing nor the notice.
The contract is therefore: task execution installs its own `TermClose` handler
whose only job is to report a non-zero status, and which closes nothing. A
non-zero status stays visible and is never turned into a successful Chroma
state.

### Every run is its own thing

From the first day, each explicit Run gets a `run_id` from **one monotonically
increasing counter per Neovim session** — not per task and not per group. The
terminal library builds a terminal's identity from the command, directory,
environment and count, and Chroma's task id is not among them: two different
tasks that happen to run `terraform plan` in one directory would collide on
their first run each if the counter were per task. The `run_id` is passed as
that count:

```text
terraform-plan / run 41
terraform-plan / run 42
```

Two parallel runs of one task must not share a terminal identity. There is no
run history and no UI for returning to earlier runs in Milestone 1 — only the
identity model, because it cannot be retrofitted without changing execution.

---

## 9. Fail closed

No task runs on a guess. The refusal names what was missing; there is never a
second attempt with a different directory or a different executable.

```text
the task file is not trusted              → do not run
the task source is not a regular file     → do not run
schema is missing or unsupported          → do not run
the task is malformed by §3               → do not run
relative cwd does not exist               → do not run
resolved cwd escapes the project root     → do not run
argv[0] resolves to nothing executable    → do not run
the confirmation was anything but yes     → do not run
```

---

## 10. Custom tasks and Managed Terraform

`chroma-terraform` is not a task runner and must not become one. It has a
lifecycle: a plan written to a private artifact, its `sha256` taken and checked
again before apply, per-directory claims that order overlapping plans, the
binary that produced a plan recorded and required at apply, and — when it is
switched on — the AWS identity the plan was made under. Terragrunt is inside
that model: a directory holding `terragrunt.hcl` or `terragrunt.stack.hcl` is a
terragrunt unit, and applying a plan while bypassing terragrunt is refused.

Two models, deliberately:

```text
Terraform / Terragrunt Run            Terraform / Terragrunt Managed
  argv                                   managed plan
  cwd                                    artifact + sha256
  env                                    identity binding
  terminal                               plan/apply binding
  no guarantees beyond faithful           Chroma's guarantees
  execution
```

**There is no bridge.** A custom task running `terraform plan` produces nothing
that Managed Apply may accept, and `terragrunt run --all` can only ever be a
custom task: the managed model is keyed by one directory holding one plan, and a
stack run is N units with nothing single to hash or to bind. That is a property
of the model, not a missing feature.

This boundary is **enforced, not merely declared**.
`tests/test_tasks_orchestration.lua` carries the architecture test, and its
mutation is named:

```text
rule      lua/chroma/tasks/** must not depend on Managed Terraform
          lifecycle or state, and Managed must not consume task artifacts
mutation  add require("chroma-terraform") to the task executor
expected  the architecture test fails
```

One consequence for the interface: the words this project uses for managed work
— *reviewed plan*, *plan artifact* — may not appear in a task preview. Managed
lives under `<leader>t`; tasks are reached from the task picker; nobody should
be able to mistake one for the other.

### What Chroma guarantees, and what it does not

Guaranteed, for custom tasks: the selected task is the one that runs, the
working directory is resolved by the rules above, `argv` and `env` are prepared
as declared, the preview shows what will run, and the process is started that
way.

Not guaranteed: that the command is safe, that a `Makefile` does what its target
name suggests, that a wrapper produces a correct plan, that the chosen inventory
is the environment somebody meant, or that a playbook is harmless. That is the
user's configuration, and this layer is honest about where its guarantees end.

---

## 11. The Ansible runner Chroma had

**Done in `568c28e`.** There was one place where shipping this would create two
answers to one question, and Milestone 1 had to settle it rather than leave it
standing.

Chroma used to run Ansible from the buffer. `<leader>ar` called
`require("ansible").run()` (`lua/plugins/devops.lua`), and that was not a stray
keymap: `components/ansible.json` described the component as *"Playbooks and
roles: running them, and the language server"* and required the `ansible`
executable *"for running a playbook or a role from the buffer"*, `health.lua`
reported `ansible` as needed for *"running playbooks (`<leader>ar`)"*, and
`CONTRACT.md` listed `nvim-ansible` as *"running playbooks and roles"*.

Shipping tasks beside it would have given one editor two execution models:

```text
<leader>xr   the project declares exactly what to run
<leader>ar   a plugin infers what to run from the buffer
```

which is the thesis of this document and its exact negation, side by side. The
resolution: **Milestone 1 retired the execution path, not the plugin.**
`nvim-ansible` stays for what only it does — filetype detection, `ansible-doc`,
path helpers — and `<leader>ar` together with `require("ansible").run()` went.
Somebody who wants to run a playbook from Chroma writes the task that says how
their repository does it, which is the entire point.

That was four files, not one: the keymap in `lua/plugins/devops.lua`, the
component's description and its required tool in `components/ansible.json`, the
health line in `lua/chroma/health.lua`, and the sentence in `CONTRACT.md`.

**The required `ansible` went with it, and `ansible-doc` arrived as optional.**
The component required that executable for exactly one stated reason —
*"running a playbook or a role from the buffer"* — and that is the thing that
was retired. What remains of the plugin was read at the pinned version: its
`ftplugin/ansible.lua` sets `keywordprg` to `ansible-doc`, and only when
`executable('ansible-doc')` says so, and extends `path` for `gf`. Neither needs
the `ansible` CLI, and the language server is declared separately already.

So the component's tools became exactly this:

```text
remove   required  ansible      "running a playbook or a role from the buffer"
add      optional  ansible-doc  "documentation lookup through keywordprg"
```

Optional rather than recommended, and declared rather than omitted, because it
is what the code actually does: a guarded lookup that improves the component
when the tool is there and changes nothing when it is not — which is precisely
what the optional level already means in `core.json`.

---

## 12. Measured implementation notes

Short, and here because they are the reason the contract reads as it does.

**Neovim 0.12.4, `runtime/lua/vim/secure.lua`.** `vim.secure.read()` offers
`ignore / view / deny` for a file; `allow` exists only for a directory. `view`
opens the file and returns `nil`, so trusting a file means viewing it and then
running `:trust`. `deny` is recorded as `!` and silences every later prompt. The
database is `$XDG_STATE_HOME/nvim/trust`, one `hash path` per line, keyed by the
real path, with file decisions bound to a `sha256` of the contents — so editing
`tasks.json` invalidates the decision. `:trust` documents a TOCTOU risk for
`:trust [file]` and directs users to view and then run it with no argument.

**The 0.12.3 floor.** Upstream `799cbfff8` (2026-05-20), *"fix(vim.secure):
read() command injection vulnerability"*, escapes the path before the `view`
command. Checking `runtime/lua/vim/secure.lua` at each release: absent in
v0.12.0, v0.12.1 and v0.12.2; present in v0.12.3 and v0.12.4. Milestone 1 hands
`read()` a path whose variable part is the user's own clone location, so the
exposure is small — but it is small by accident of this design, and the first
change that discovers task files in repository-controlled subdirectories would
make it real. A security boundary is not built on an unpatched implementation.

**snacks.nvim at the pinned `882c996`.** `terminal.open()` starts a new terminal
and passes the command to `jobstart` with `cwd`, `env` and `term = true`; a
table command therefore runs without a shell, and `env` extends the inherited
environment rather than replacing it. A terminal's identity is its command,
directory, environment and count — which is why each run needs its own count.
`auto_close` defaults on through `interactive`: it closes a terminal whose
process exited 0 and keeps one that failed, reporting the status. Task execution
therefore sets `auto_close = false` — and that same switch is what installs the
failure notice, since the `TermClose` handler that reports a non-zero status
lives inside the `auto_close` branch. Turning the closing off turns the
reporting off with it, which is why §8 gives the reporting to Chroma.

---

## 13. Milestone 1, frozen — and shipped

This is the list the implementation was held to, unchanged from the day it was
frozen. Every line of it is in `lua/chroma/tasks/`; the same invariants, in the
form somebody governing the project needs rather than the form somebody
implementing it needed, are in `CONTRACT.md`.

```text
Source        .chroma/tasks.json only
              discovered upward from Neovim's working directory, first wins
              discovery stops at the first entry of that name, valid or not
              must resolve to a readable regular file before it is read
Schema        schema = 1, required
              document: {schema, tasks} exactly, unknown fields refused
              task: id, name, cwd, argv required; group, env optional
              ids unique, no empty strings, no nulls, argv all strings
              cwd: project (no path) | relative (relative path required)

Availability  Chroma: Neovim >= 0.12
              project tasks: Neovim >= 0.12.3, else fail closed with the reason
              :checkhealth reports that gate as its own status

Trust         evaluated only on explicit Run Task, never at startup
              file trust only, no directory trust
              Chroma explains itself before the modal, which says "exrc"
              flow: Run Task → view → :trust (no filename) → Run Task
              states: missing / untrusted / trusted / denied / unknown
              denied is never reported as "no tasks"
              adapter resolves realpath + current hash + entry, not just `!`
              the adapter's snapshot is authoritative and is exact file bytes:
              hashed, authorised and parsed without a second representation
              trusted parses that snapshot; only untrusted calls read(),
              and denied, missing and unknown never call it at all
              trust-database adapter: format pinned by a test,
              parse failure degrades to the generic refusal
              definitions are read per Run Task and never cached for a session

cwd           project, relative
              realpath(cwd) inside realpath(project root), by path components

Execution     argv only, no shell
              argv[0]: bare name via the effective PATH, absolute as written,
              path-like against the task's cwd; nothing found = named refusal
              relative arguments passed through unchanged
              inherited environment + task overrides

Preview       task, working directory, environment overrides, indexed argv
              no shell rendering
              only an explicit affirmative runs anything; the default is no

Process       one Run = one new process = one run_id, one counter per session
              Snacks.terminal.open(), auto_close = false
              interactive input kept; terminal survives every exit status
              Chroma's own TermClose reports a non-zero status, closes nothing

UI            <leader>xr → picker → preview → confirmation
              selection works with no external executable (vim.ui.select)
              picker grouped by `group`

Integration   the nvim-ansible execution path retires in this milestone:
              <leader>ar and require("ansible").run() go, the plugin stays
              required `ansible` goes; optional `ansible-doc` takes its place
              components/ansible.json, health.lua and CONTRACT.md follow

Architecture  tasks are core, not a component
              `group` is metadata and changes no behaviour
              no dependency on Managed Terraform lifecycle or state,
              enforced by an architecture test
```

The implementation order followed from it, and each step is one commit with its
tests in the same commit:

```text
 1  schema        schema.lua        the document, refused field by field
 2  discovery     source.lua        upward only, first entry wins
 3  trust         trust.lua         five states, one authoritative snapshot
 4  cwd           cwd.lua           two modes, containment by path components
 5  argv and env  command.lua       resolution before the terminal exists
 6  preview       preview.lua       what will run, and the default is no
 7  executor      run.lua           one Run, one process, one run_id
 8  retirement    devops.lua &c.    §11
 9  health gate   health.lua        0.12.3 reported as its own status
10  orchestration init.lua          trust → picker → cwd/argv → preview → run
                  availability.lua  the floor, now asked by both sides
                  keymaps.lua       <leader>xr
```

Point 10 is where the order became a contract of its own, and the comment at
the top of `init.lua` carries the three reasons: **trust before the picker**,
because a modal over a picker is a question about a list nobody can see;
**cwd and argv after the choice**, because one task without a command must not
hide the rest of the document; and **one prepared array for both the preview
and the executor**, because `PATH` can change between the question and the
answer.

---

## 14. Future work — not part of the schema-1 execution MVP

These are good ideas and none of them is in the first implementation. They are
kept here so that in three months nobody mistakes the concept for the contract.

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

Two notes on why the first four moved out. `nearest` and `file` both depend on
what the current buffer is, and Milestone 1 deliberately has no current-file
semantics at all: the first vertical slice can be tested end to end without oil
buffers, dashboards, terminals and unnamed buffers. When they arrive they bring
their own definition — a buffer whose name is a local path that exists and is a
regular file, and `nearest` searching upward from the file's directory and
stopping at the project root, inclusive, refusing when no marker is found.

`inputs` moved out because the example that motivated them — one Ansible task
with a choice of inventory — is expressible today as two tasks, and the whole of
the execution model can be proven without it.

---

## 15. How this was read before implementing, and how to read it now

The test the document had to pass before a line was written:

```text
a contradiction between two sections
a fallback that is not defined
a decision left to whoever writes the code
```

It passed, and the contract held: nothing in §13 was renegotiated during the
implementation, which is the only evidence that the freeze was worth doing.

**Reading it now is a different job.** The code is the authority on behaviour
and the tests are the authority on what is covered; this document is the
authority on *why*, and on what was measured to get there. Where it and the
code disagree, the code is right and the section is a bug — say which section,
because eight files point back at these numbers.

Anything from §14 arrives the same way this did: frozen first, then built.
