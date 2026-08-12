-- Decisions in, an exact argument vector out.
--
-- Everything the operator chose has already been chosen; this turns it into the
-- array a process is started from, and decides nothing. It starts nothing,
-- reads nothing and asks nothing. The rules are `doc/chroma-ansible-design.md`,
-- sections 3.5, 9.2, 9.3, 10, 12 and 15.1.
--
-- **There is no shell.** No string is joined, quoted, split or expanded
-- anywhere in this module. A custom host pattern reaches `argv` byte for byte,
-- because `webservers:&production` is Ansible's to interpret and nobody else's.
--
-- **Order.**
--
--     executable → options → positional playbooks last
--
-- Ansible does not care in which order the options arrive; this module fixes
-- one anyway, so that two previews of one plan read identically and a diff
-- between them means something. The order is the one in the worked example in
-- §15, so the document and the code cannot drift into two answers.
--
-- **Inherit emits nothing.** Every option here is inherit-or-override, never
-- on/off — §10. `No limit` is the same rule wearing a different name: it emits
-- no `-l` at all rather than `-l all`, because the playbook's own `hosts:` is
-- the authority and `-l all` would override it.

local M = {}

--- Flags that make Ansible prompt on a terminal an inspection subprocess does
--- not have. Measured on ansible-core 2.21.2, §3.5: `--list-tags` with
--- `--ask-vault-pass` stops at `Vault password:` and ends in
--- `EOFError (ctrl-d)`, while the same listing with `-K` does not prompt at
--- all. `-K` is excluded regardless: it cannot change what a listing reports,
--- so carrying it buys nothing and costs a hang on the day it starts asking.
local NEVER_WHEN_LISTING = { ["-K"] = true, ["--ask-vault-pass"] = true }

---@class chroma_ansible.Plan
---@field executable string absolute path to the program that will run
---@field playbooks string[] at least one, emitted last and in order
---@field inventory string[] `-i` sources in the operator's order; empty means inherit
---@field limit string|nil a host pattern, passed through untouched
---@field tags string[] one `--tags` per entry; never joined
---@field remote_user string|nil `-u`
---@field become boolean `-b`
---@field ask_become_pass boolean `-K`
---@field vault string[] vault options as written; a list so that ids are a picker change (§10.3)
---@field check boolean `--check`
---@field diff boolean `--diff`

---Whether a value is a non-empty string.
---@param value any
---@return boolean
local function text(value)
  return type(value) == "string" and value ~= ""
end

---Whether every element of a list is a non-empty string.
---@param list any
---@return boolean
local function texts(list)
  if type(list) ~= "table" or not vim.islist(list) then
    return false
  end
  for _, value in ipairs(list) do
    if not text(value) then
      return false
    end
  end
  return true
end

---What is wrong with a plan, if anything.
---
---Refusals rather than defaults. A plan missing its playbook is a bug in the
---planner, and emitting `ansible-playbook` with no positional argument would
---turn it into a confusing message from Ansible instead of a clear one from
---here.
---@param plan any
---@return string|nil problem
local function plan_problem(plan)
  if type(plan) ~= "table" then
    return "the plan is not a table"
  end

  if not text(plan.executable) then
    return "the plan has no executable"
  end
  -- §15.2: `argv[0]` is the absolute path that was resolved, and the preview
  -- shows it. A bare name here would mean the preview and the process disagree
  -- about which program runs.
  if not vim.startswith(plan.executable, "/") then
    return "the executable is not an absolute path"
  end

  if not texts(plan.playbooks) or #plan.playbooks == 0 then
    return "the plan has no playbook"
  end
  if not texts(plan.inventory) then
    return "the inventory sources are not a list of paths"
  end
  if not texts(plan.tags) then
    return "the tags are not a list of names"
  end
  if not texts(plan.vault) then
    return "the vault options are not a list"
  end

  -- `No limit` is `nil`. An empty string would emit `-l ` with an empty
  -- argument, which is a different question asked of Ansible.
  if plan.limit ~= nil and not text(plan.limit) then
    return "the limit is present and empty"
  end
  if plan.remote_user ~= nil and not text(plan.remote_user) then
    return "the remote user is present and empty"
  end

  return nil
end

---The options both the run and the listings share, in the fixed order.
---@param plan chroma_ansible.Plan
---@param listing boolean whether this is an inspection subprocess
---@return string[]
local function options(plan, listing)
  local out = {}

  ---@param ... string
  local function emit(...)
    for _, word in ipairs({ ... }) do
      if not (listing and NEVER_WHEN_LISTING[word]) then
        table.insert(out, word)
      end
    end
  end

  if plan.remote_user then
    emit("-u", plan.remote_user)
  end
  if plan.ask_become_pass then
    emit("-K")
  end
  if plan.become then
    emit("-b")
  end
  for _, option in ipairs(plan.vault) do
    -- Filtered by name, so an option that prompts is dropped from a listing
    -- while `--vault-id dev@prompt-less` would survive when it arrives.
    emit(option)
  end

  -- Order is the operator's, and it is never sorted: Ansible merges several
  -- `-i` sources in the order they are given, and sorting them would quietly
  -- change which definition of a host wins.
  for _, source in ipairs(plan.inventory) do
    emit("-i", source)
  end

  if plan.limit then
    emit("-l", plan.limit)
  end

  -- One flag per tag. Measured, §20.2: `--tags` accumulates across repetitions,
  -- so joining them with a comma would be this module inventing a syntax when
  -- Ansible already has one.
  for _, tag in ipairs(plan.tags) do
    emit("--tags", tag)
  end

  if plan.check then
    emit("--check")
  end
  if plan.diff then
    emit("--diff")
  end

  return out
end

---The argument vector that runs the playbooks.
---
---@param plan chroma_ansible.Plan
---@return string[]|nil argv, string|nil problem
function M.execution(plan)
  local problem = plan_problem(plan)
  if problem then
    return nil, problem
  end

  local argv = { plan.executable }
  vim.list_extend(argv, options(plan, false))
  -- Positional, and last. A playbook name among the flags is accepted by
  -- Ansible and reads as a mistake to everyone who checks the preview.
  vim.list_extend(argv, plan.playbooks)

  return argv, nil
end

--- The listing modes this planner uses, and the program each belongs to.
local LISTINGS = {
  tags = "--list-tags",
  hosts = "--list-hosts",
  tasks = "--list-tasks",
}

---The argument vector for one `ansible-playbook` listing mode.
---
---Same context as the run — §3.5 — minus the flags that would make it prompt
---where there is no terminal to prompt on.
---@param plan chroma_ansible.Plan
---@param kind "tags"|"hosts"|"tasks"
---@return string[]|nil argv, string|nil problem
function M.listing(plan, kind)
  local flag = LISTINGS[kind]
  if not flag then
    return nil, ("%s is not a listing this planner runs"):format(tostring(kind))
  end

  local problem = plan_problem(plan)
  if problem then
    return nil, problem
  end

  local argv = { plan.executable }
  vim.list_extend(argv, options(plan, true))
  table.insert(argv, flag)
  vim.list_extend(argv, plan.playbooks)

  return argv, nil
end

---The argument vector that asks for the inventory graph.
---
---A different program, so it takes the inventory sources and nothing else:
---`-u`, `-b`, tags, limit and check are `ansible-playbook` options, and
---`ansible-inventory` has no use for them. `-l` is accepted and **ignored** by
---`--graph` — measured, §20.6 — which is exactly why it is not passed: an
---argument that looks like it filters and does not is worse than no argument.
---@param plan chroma_ansible.Plan
---@param executable string absolute path to ansible-inventory
---@return string[]|nil argv, string|nil problem
function M.graph(plan, executable)
  local problem = plan_problem(plan)
  if problem then
    return nil, problem
  end
  if not text(executable) or not vim.startswith(executable, "/") then
    return nil, "the inventory executable is not an absolute path"
  end

  local argv = { executable }
  for _, source in ipairs(plan.inventory) do
    vim.list_extend(argv, { "-i", source })
  end
  -- Never `--vars`: it is the flag that puts host and group variables into this
  -- output in plaintext (§7.1), and the parser refuses output carrying them.
  table.insert(argv, "--graph")

  return argv, nil
end

return M
