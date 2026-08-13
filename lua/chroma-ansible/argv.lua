-- Decisions in, an exact argument vector out. This decides nothing, starts
-- nothing and reads nothing. The rules are `doc/chroma-ansible-design.md`
-- §3.5, §9.2, §9.3, §10, §12 and §15.1.
--
-- **There is no shell**: nothing is joined, quoted, split or expanded, and a
-- custom host pattern reaches `argv` byte for byte.
--
-- **Order** is executable, then options, then positional playbooks last.
-- Ansible does not care; this fixes one so two previews of a plan read
-- identically, and it is the order of the worked example in §15.
--
-- **Inherit emits nothing** (§10). `No limit` is the same rule: no `-l` at all
-- rather than `-l all`, because the playbook's own `hosts:` is the authority.

local M = {}

--- Flags that make Ansible prompt on a terminal an inspection does not have.
--- Measured on 2.21.2, §3.5: `--list-tags` with `--ask-vault-pass` stops at
--- `Vault password:` and ends in `EOFError`, while `-K` does not prompt at all.
--- `-K` is excluded regardless, since it cannot change what a listing reports.
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

---What is wrong with a plan, if anything. Refusals rather than defaults: a plan
---missing its playbook is a bug in the planner, and emitting `ansible-playbook`
---with no positional argument would turn it into a confusing message from
---Ansible instead of a clear one from here.
---@param plan any
---@return string|nil problem
local function plan_problem(plan)
  if type(plan) ~= "table" then
    return "the plan is not a table"
  end

  if not text(plan.executable) then
    return "the plan has no executable"
  end
  -- §15.2: `argv[0]` is the absolute path that was resolved and the preview
  -- shows it, so a bare name would let the two disagree.
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

  -- `No limit` is `nil`; an empty string would emit `-l ` with an empty
  -- argument, which asks Ansible a different question.
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
    -- By name, so `--vault-id dev@prompt-less` would survive when it arrives.
    emit(option)
  end

  -- The operator's order, never sorted: Ansible merges `-i` sources in the
  -- order given, and sorting would change which definition of a host wins.
  for _, source in ipairs(plan.inventory) do
    emit("-i", source)
  end

  if plan.limit then
    emit("-l", plan.limit)
  end

  -- One flag per tag. Measured, §20.2: `--tags` accumulates across
  -- repetitions, so joining with a comma would be inventing a syntax.
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
  -- Positional, and last: a playbook name among the flags is accepted by
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

---The argument vector for one `ansible-playbook` listing mode: the same context
---as the run (§3.5), minus the flags that would prompt where no terminal is.
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

---The argument vector that asks for the inventory graph. A different program,
---so it takes the sources and nothing else. `-l` is accepted and **ignored** by
---`--graph` (measured, §20.6), which is why it is not passed: an argument that
---looks like it filters and does not is worse than none.
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
  -- Never `--vars`: it puts host and group variables into this output in
  -- plaintext (§7.1), and the parser refuses output carrying them.
  table.insert(argv, "--graph")

  return argv, nil
end

return M
