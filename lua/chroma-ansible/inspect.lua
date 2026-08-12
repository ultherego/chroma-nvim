-- The Ansible subprocesses, and the gate that guards them.
--
-- Everything that starts a process for the planner starts it here, under three
-- rules that hold for every call in this module. The rules are
-- `doc/chroma-ansible-design.md`, sections 3.5, 6, 7, 8, 13 and 16.
--
-- **Nothing runs before the gate.** `ansible-inventory --graph` is not a file
-- read: an inventory may be an executable script, a plugin may contact EC2 or a
-- CMDB, and an `ansible.cfg` in the working directory decides which code
-- Ansible loads. The consent is asked here rather than by the caller, so that
-- adding a fifth introspection later cannot forget it (§6.3, §19.4).
--
-- **Nothing answers out of turn.** Every call takes the run's generation as it
-- starts and delivers nothing once that generation is gone. The check runs
-- before the callback touches any state, and a discarded answer is not an error
-- — it is the operator having moved on (§13.2).
--
-- **Nothing is logged.** No stdout, no stderr and no host name from any
-- subprocess is written to a message, a notification or a file by this module.
-- Failures hand Ansible's own output back to the caller to show; where it goes
-- from there is the interface's business, and nowhere is it Chroma's to keep
-- (§7.4, §19.16).
--
-- There is no timeout. Dynamic inventory takes as long as the system it talks
-- to takes, and a deadline invented here would abort a slow answer that was
-- about to arrive. Cancelling is the operator's (§13.4) and belongs to
-- `planner.cancel`.

local argv = require("chroma-ansible.argv")
local context = require("chroma-ansible.context")
local gate = require("chroma-ansible.gate")
local graph = require("chroma-ansible.graph")
local listing = require("chroma-ansible.listing")
local planner = require("chroma-ansible.planner")

local M = {}

---How a subprocess is started.
---
---A variable so a test can answer for one without an Ansible on the machine,
---and the single place a process can come from: a second call site would be a
---second place the gate could be skipped.
---@type fun(cmd: string[], opts: table, on_exit: fun(result: vim.SystemCompleted)): vim.SystemObj
M.system = vim.system

---@class chroma_ansible.Answer
---@field graph chroma_ansible.Graph|nil the inventory, when that inspection succeeded
---@field tags string[]|nil the tags Ansible reported, when that inspection succeeded
---@field problem string|nil what to show; Ansible's own output where there was any
---@field declined boolean|nil the gate was answered No, and nothing was started

---The absolute path of an Ansible tool, or nil.
---
---Resolved rather than passed through as a bare name, because the preview and
---the executor read one prepared array and `argv[0]` is what the preview shows
---(§15.2). Idempotent for a path that is already absolute.
---@param name string
---@return string|nil
function M.tool(name)
  if type(name) ~= "string" or name == "" or vim.fn.executable(name) ~= 1 then
    return nil
  end

  local path = vim.fn.exepath(name)
  if path == "" then
    return nil
  end

  return path
end

---What a finished subprocess said, for showing verbatim.
---
---stderr first: Ansible reports errors and warnings there and prints results to
---stdout, so a failure reads top-down. Only trailing whitespace goes, and that
---is not the truncation §16 forbids — it is the newline every process ends on.
---@param result vim.SystemCompleted
---@return string
local function said(result)
  local out = ((result.stderr or "") .. (result.stdout or "")):gsub("%s+$", "")
  if out ~= "" then
    return out
  end

  -- A non-zero exit with nothing to say still has to be reportable, and the
  -- status is the only thing there is. Ansible does not do this; a wrapper on
  -- `PATH` under the same name might.
  return ("the inspection exited with status %s and said nothing"):format(tostring(result.code))
end

---Hands one answer to the caller, unless the operator has moved on.
---
---Every path out of this module goes through here, including the ones that
---fail before a process exists. That is what makes the callback's arrival
---uniform: a caller never has to know whether its `on_done` might have already
---run before the call it passed it to returned.
---@param run chroma_ansible.Run
---@param mine integer the generation the inspection started under
---@param on_done fun(answer: chroma_ansible.Answer)
---@param answer chroma_ansible.Answer
local function deliver(run, mine, on_done, answer)
  vim.schedule(function()
    -- Before anything else is touched, and not in a renderer (§13.2).
    if not planner.current(run, mine) then
      return
    end

    run.process = nil
    on_done(answer)
  end)
end

---What one finished `--graph` means.
---
---A parse failure reports the parser's own words and **not** the output that
---produced them. The two failures are equally fatal (§7.3) and are shown
---identically by the interface, but a graph line carries host names, and this
---module does not repeat one to explain that it could not read it (§7.4). A
---non-zero exit is different: what Ansible wrote is a diagnosis rather than an
---inventory, and §16 requires showing it.
---@param result vim.SystemCompleted
---@return chroma_ansible.Answer
local function graph_answer(result)
  if result.code ~= 0 then
    return { problem = said(result) }
  end

  local tree, problem = graph.read(result.stdout)
  if not tree then
    return { problem = problem }
  end

  return { graph = tree }
end

---What one finished `--list-tags` means.
---
---A listing that failed reports what Ansible said and no tags at all. §8.1 is
---why there is no partial answer to give: the list is what Ansible reported,
---so a list assembled from a failed report would be a claim nobody made.
---@param result vim.SystemCompleted
---@return chroma_ansible.Answer
local function tags_answer(result)
  if result.code ~= 0 then
    return { problem = said(result) }
  end

  local tags, problem = listing.tags(result.stdout)
  if not tags then
    return { problem = problem }
  end

  return { tags = tags }
end

---Runs one inspection under the rules that hold for all of them.
---
---Every subprocess this module starts goes through here. That is what makes
---the gate impossible to skip by adding an inspection: there is one place that
---spawns, and it asks first.
---@param run chroma_ansible.Run
---@param tool string the name reported when the process cannot be started
---@param command string[]|nil the prepared array, or nil when it could not be built
---@param problem string|nil why it could not be built
---@param interpret fun(result: vim.SystemCompleted): chroma_ansible.Answer
---@param on_done fun(answer: chroma_ansible.Answer)
local function inspection(run, tool, command, problem, interpret, on_done)
  -- Claimed before anything can await, so that every way out of this call —
  -- including the ones that never spawn — belongs to one generation.
  local mine = run.generation

  if not command then
    return deliver(run, mine, on_done, { problem = problem })
  end

  -- Asked again rather than trusted. Freezing happened when the operator chose
  -- the directory, and a directory can be removed or replaced between then and
  -- now; `vim.system` would raise for that below, but with libuv's words rather
  -- than the path that was frozen (§16).
  local gone = context.still_usable(run.directory)
  if gone then
    return deliver(run, mine, on_done, { problem = gone })
  end

  -- The last thing before the process, and the only thing between the picker
  -- and it. Declining is not a failure and carries no output to show: nothing
  -- ran, so Ansible said nothing.
  if not gate.allow(run.gate, planner.subject(run)) then
    return deliver(run, mine, on_done, { declined = true })
  end

  -- The frozen directory, and the environment inherited unchanged. Every
  -- subprocess of one run is started exactly like this, which is how §3.5 is
  -- kept: not by copying an environment around, but by never editing one.
  local started, process = pcall(M.system, command, { cwd = run.directory, text = true }, function(result)
    deliver(run, mine, on_done, interpret(result))
  end)

  if not started then
    -- `vim.system` raises before it spawns anything when the request itself is
    -- bad. Raising past the caller here would leave the planner waiting for a
    -- callback that no process will ever produce.
    return deliver(run, mine, on_done, {
      problem = ("%s could not be started in %s: %s"):format(tool, run.directory, tostring(process)),
    })
  end

  run.process = process
end

---Asks Ansible what the chosen inventory sources contain.
---
---`ansible-inventory --graph`, never `--list`: `--list` prints every host
---variable in plaintext and no flag suppresses it (§7.1, measured §20.3).
---
---@param run chroma_ansible.Run
---@param executable string absolute path to `ansible-inventory`
---@param on_done fun(answer: chroma_ansible.Answer)
function M.inventory(run, executable, on_done)
  local command, problem = argv.graph(run.plan, executable)
  inspection(run, "ansible-inventory", command, problem, graph_answer, on_done)
end

---Asks Ansible which tags the chosen playbooks report.
---
---The same context as every other subprocess of this run (§3.5), minus the
---flags that would make it prompt where there is no terminal to prompt on —
---`argv.listing` drops those. An inventory is passed when one was chosen even
---though tags do not need one: a listing that resolved a different inventory
---than the run would be a listing of a different question (§8.4).
---@param run chroma_ansible.Run
---@param on_done fun(answer: chroma_ansible.Answer)
function M.tags(run, on_done)
  local command, problem = argv.listing(run.plan, "tags")
  inspection(run, "ansible-playbook", command, problem, tags_answer, on_done)
end

return M
