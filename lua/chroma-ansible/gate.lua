-- The boundary between looking and running: everything before this module
-- stats and resolves, everything after it starts an Ansible process. The rules
-- are `doc/chroma-ansible-design.md` §6.
--
-- > **Selecting a path in a picker must never start an Ansible process.**
--
-- `ansible-inventory --graph` is not a file read. An inventory may be an
-- executable script, a plugin may contact EC2 or LDAP, and an `ansible.cfg` can
-- point `callback_plugins`, `library` and `roles_path` at code Ansible loads.
--
-- **The consent is bound to what the prompt named** (§6.4): the working
-- directory, the playbooks and the sources in order. Change any of them and the
-- question is asked again — it never asks "may Chroma run Ansible".
--
-- `vim.secure` is deliberately not used (§6.5): it binds a decision to the
-- bytes of one file, while the risk here is the whole execution context.

local M = {}

--- What the interface says when no `-i` will be passed. The gate is still
--- shown (§5.3): with no explicit source, what gets contacted is decided by
--- configuration nobody has been shown.
local FROM_CONFIG = "from Ansible configuration (not shown)"

---@class chroma_ansible.Subject
---@field directory string the frozen working directory
---@field playbooks string[] in order
---@field inventory string[] `-i` sources in order; empty means inherit

---A copy of the values a consent is about. Copied rather than referenced: the
---planner edits these lists as the operator changes their mind, and a reference
---would follow the very changes it is supposed to be invalidated by.
---@param subject chroma_ansible.Subject
---@return chroma_ansible.Subject
local function snapshot(subject)
  return {
    directory = subject.directory,
    playbooks = vim.list_slice(subject.playbooks, 1, #subject.playbooks),
    inventory = vim.list_slice(subject.inventory, 1, #subject.inventory),
  }
end

---Whether two lists hold the same strings in the same order. Order matters
---because it matters to Ansible: `-i common -i prod` and `-i prod -i common`
---can resolve a host differently.
---@param one string[]
---@param two string[]
---@return boolean
local function same(one, two)
  if #one ~= #two then
    return false
  end
  for index, value in ipairs(one) do
    if two[index] ~= value then
      return false
    end
  end
  return true
end

---@param granted chroma_ansible.Subject|nil
---@param subject chroma_ansible.Subject
---@return boolean
local function covers(granted, subject)
  return granted ~= nil
    and granted.directory == subject.directory
    and same(granted.playbooks, subject.playbooks)
    and same(granted.inventory, subject.inventory)
end

---How the question is asked. A variable so a test can answer it.
---`vim.fn.confirm` with No first, as Project Tasks does, and a dismissed dialog
---answers 0 — neither choice, and therefore also no.
---@type fun(question: string): boolean
M.confirm = function(question)
  return vim.fn.confirm(question, "&No\n&Yes", 1) == 2
end

---What the operator is shown before the first subprocess.
---@param subject chroma_ansible.Subject
---@return string
function M.question(subject)
  local lines = {
    "Ansible inspection",
    "",
    "Chroma is about to run Ansible using:",
    "",
    ("  Working directory   %s"):format(subject.directory),
  }

  for index, playbook in ipairs(subject.playbooks) do
    table.insert(lines, ("  %-19s %s"):format(index == 1 and "Playbook" or "", playbook))
  end

  if #subject.inventory == 0 then
    table.insert(lines, ("  %-19s %s"):format("Inventory", FROM_CONFIG))
  else
    for index, source in ipairs(subject.inventory) do
      table.insert(lines, ("  %-19s %s"):format(index == 1 and "Inventory" or "", source))
    end
  end

  vim.list_extend(lines, {
    "",
    "Inspection may execute inventory scripts and plugins configured for",
    "this workspace, and may contact external systems.",
    "",
    "Inspect?",
  })

  return table.concat(lines, "\n")
end

---A gate that has agreed to nothing. One per planner run: nothing is cached
---globally, per directory or between runs, because a new run is a new question
---even when it names the same three values.
---@return table
function M.new()
  return { granted = nil }
end

---Whether Ansible may be run for this subject, asking if it has to.
---
---@param gate table from `M.new()`
---@param subject chroma_ansible.Subject
---@return boolean allowed
function M.allow(gate, subject)
  if covers(gate.granted, subject) then
    return true
  end

  -- Cleared before asking, not after answering: what must not survive a
  -- declined question is an older consent for a context that has changed.
  gate.granted = nil

  if not M.confirm(M.question(subject)) then
    return false
  end

  gate.granted = snapshot(subject)
  return true
end

return M
