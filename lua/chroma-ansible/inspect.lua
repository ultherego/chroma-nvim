-- The Ansible subprocesses, and the gate that guards them. The rules are
-- `doc/chroma-ansible-design.md` §3.5, §6, §7, §8, §13 and §16.
--
-- **Nothing runs before the gate**, asked here rather than by the caller so a
-- fifth introspection cannot forget it (§6.3, §19.4). **Nothing answers out of
-- turn**: every call takes the run's generation as it starts and delivers
-- nothing once that generation is gone (§13.2). **Nothing is logged** — no
-- stdout, stderr or host name reaches a message or a file from here; failures
-- hand Ansible's own output to the caller (§7.4, §19.16).
--
-- There is no timeout: dynamic inventory takes as long as the system it talks
-- to takes. Cancelling is the operator's (§13.4) — which is why every
-- subprocess here is opened with something on screen saying so, from the same
-- place that asks the gate.

local argv = require("chroma-ansible.argv")
local context = require("chroma-ansible.context")
local gate = require("chroma-ansible.gate")
local graph = require("chroma-ansible.graph")
local listing = require("chroma-ansible.listing")
local planner = require("chroma-ansible.planner")
local progress = require("chroma-ansible.progress")

local M = {}

---How a subprocess is started. A variable so a test can answer for one without
---an Ansible on the machine, and the single place a process can come from: a
---second call site would be a second place the gate could be skipped.
---@type fun(cmd: string[], opts: table, on_exit: fun(result: vim.SystemCompleted)): vim.SystemObj
M.system = vim.system

---@class chroma_ansible.Answer
---@field graph chroma_ansible.Graph|nil the inventory, when that inspection succeeded
---@field tags string[]|nil the tags Ansible reported, when that inspection succeeded
---@field targets string[]|nil the hosts Ansible resolved just now, never a promise (§9.4)
---@field problem string|nil what to show; Ansible's own output where there was any
---@field declined boolean|nil the gate was answered No, and nothing was started

---The absolute path of an Ansible tool, or nil. Resolved rather than passed
---through as a bare name, because `argv[0]` is what the preview shows (§15.2).
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

---What a finished subprocess said, for showing verbatim. stderr first, because
---Ansible reports errors there and results on stdout. Only trailing whitespace
---goes, which is the newline every process ends on, not the truncation §16
---forbids.
---@param result vim.SystemCompleted
---@return string
local function said(result)
  local out = ((result.stderr or "") .. (result.stdout or "")):gsub("%s+$", "")
  if out ~= "" then
    return out
  end

  -- A non-zero exit with nothing to say still has to be reportable. Ansible
  -- does not do this; a wrapper on `PATH` under the same name might.
  return ("the inspection exited with status %s and said nothing"):format(tostring(result.code))
end

---Hands one answer to the caller, unless the operator has moved on. Every path
---out of this module goes through here, including the ones that fail before a
---process exists, so a caller never has to know whether its `on_done` already
---ran before the call returned.
---@param run chroma_ansible.Run
---@param mine integer the generation the inspection started under
---@param on_done fun(answer: chroma_ansible.Answer)
---@param answer chroma_ansible.Answer
---@param showing { close: fun() }|nil this inspection's window, where it got one
local function deliver(run, mine, on_done, answer, showing)
  vim.schedule(function()
    -- Its own window and no other: a newer inspection of this run has its own,
    -- and an answer arriving this late must not take that one away. Closed
    -- whatever the answer turns out to be worth, including for a run that has
    -- been superseded — the window was that run's.
    if showing then
      if run.stop == showing.close then
        run.stop = nil
      end
      pcall(showing.close)
    end

    -- Before anything else is touched, and not in a renderer (§13.2).
    if not planner.current(run, mine) then
      return
    end

    run.process = nil
    on_done(answer)
  end)
end

---What one finished `--graph` means. A parse failure reports the parser's own
---words and **not** the output that produced them: a graph line carries host
---names (§7.4). A non-zero exit is different — what Ansible wrote is a
---diagnosis rather than an inventory, and §16 requires showing it.
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

---What one finished `--list-tags` means. A failed listing reports what Ansible
---said and no tags: the list is what Ansible reported, so a partial one would
---be a claim nobody made (§8.1).
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

---What one finished `--list-hosts` means. §9.4: a snapshot taken now, never a
---promise about the run. The interface shows it and the repeat path is
---forbidden from carrying it (§14.5).
---@param result vim.SystemCompleted
---@return chroma_ansible.Answer
local function targets_answer(result)
  if result.code ~= 0 then
    return { problem = said(result) }
  end

  local targets, problem = listing.targets(result.stdout)
  if not targets then
    return { problem = problem }
  end

  return { targets = targets }
end

---Runs one inspection under the rules that hold for all of them. One place
---spawns, and it asks the gate first, which is what makes the gate impossible
---to skip by adding an inspection.
---@param run chroma_ansible.Run
---@param tool string the name reported when the process cannot be started
---@param label string what the operator is told is happening
---@param command string[]|nil the prepared array, or nil when it could not be built
---@param problem string|nil why it could not be built
---@param interpret fun(result: vim.SystemCompleted): chroma_ansible.Answer
---@param on_done fun(answer: chroma_ansible.Answer)
local function inspection(run, tool, label, command, problem, interpret, on_done)
  -- Claimed before anything can await, so every way out of this call belongs
  -- to one generation.
  local mine = run.generation

  if not command then
    return deliver(run, mine, on_done, { problem = problem })
  end

  -- Asked again rather than trusted: a directory can be removed between the
  -- choice and now, and `vim.system` would raise for that with libuv's words
  -- rather than the path that was frozen (§16).
  local gone = context.still_usable(run.directory)
  if gone then
    return deliver(run, mine, on_done, { problem = gone })
  end

  -- The last thing before the process. Declining is not a failure and carries
  -- no output to show: nothing ran, so Ansible said nothing.
  if not gate.allow(run.gate, planner.subject(run)) then
    return deliver(run, mine, on_done, { declined = true })
  end

  -- Whatever the last inspection of this run left on screen goes first: one
  -- run has one window, and two would be two claims about what is happening.
  if run.stop then
    pcall(run.stop)
    run.stop = nil
  end

  -- Opened before the process, not after: the gap this closes is the one where
  -- Ansible had already started and the editor was still showing nothing.
  local showing = progress.open(label, function()
    planner.cancel(run)
  end)
  run.stop = showing.close

  -- The frozen directory, and the environment inherited unchanged: §3.5 is
  -- kept by never editing one rather than by copying one around.
  local started, process = pcall(M.system, command, { cwd = run.directory, text = true }, function(result)
    deliver(run, mine, on_done, interpret(result), showing)
  end)

  if not started then
    -- `vim.system` raises before spawning when the request itself is bad, and
    -- raising past the caller would leave the planner waiting for a callback.
    return deliver(run, mine, on_done, {
      problem = ("%s could not be started in %s: %s"):format(tool, run.directory, tostring(process)),
    }, showing)
  end

  run.process = process
end

---Asks Ansible what the chosen inventory sources contain. `--graph`, never
---`--list`: `--list` prints every host variable in plaintext and no flag
---suppresses it (§7.1, measured §20.3).
---
---@param run chroma_ansible.Run
---@param executable string absolute path to `ansible-inventory`
---@param on_done fun(answer: chroma_ansible.Answer)
function M.inventory(run, executable, on_done)
  local command, problem = argv.graph(run.plan, executable)
  inspection(run, "ansible-inventory", "Resolving inventory", command, problem, graph_answer, on_done)
end

---Asks Ansible which tags the chosen playbooks report. The same context as
---every other subprocess of this run (§3.5), minus the flags that would prompt
---where there is no terminal. An inventory is passed when one was chosen, even
---though tags do not need one: a listing that resolved a different inventory
---would be a listing of a different question (§8.4).
---@param run chroma_ansible.Run
---@param on_done fun(answer: chroma_ansible.Answer)
function M.tags(run, on_done)
  local command, problem = argv.listing(run.plan, "tags")
  inspection(run, "ansible-playbook", "Inspecting tags", command, problem, tags_answer, on_done)
end

---Asks Ansible which hosts the run would address as things stand. The only
---honest validation of a limit: `ansible-inventory --graph` ignores `-l`
---entirely (§9.4, measured §20.6). A pattern matching nothing makes Ansible
---exit non-zero, and §16 lets the run continue anyway.
---@param run chroma_ansible.Run
---@param on_done fun(answer: chroma_ansible.Answer)
function M.targets(run, on_done)
  local command, problem = argv.listing(run.plan, "hosts")
  inspection(run, "ansible-playbook", "Resolving targets", command, problem, targets_answer, on_done)
end

return M
