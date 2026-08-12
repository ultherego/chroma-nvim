-- What one planner run knows, and what makes what it knows stale.
--
-- This module holds no UI, starts no process and reads no file. It is the run:
-- an id, a generation, the frozen working directory, the decisions taken so
-- far, and the consent those decisions were shown under. The rules are
-- `doc/chroma-ansible-design.md`, section 13.
--
-- **Callbacks arrive in completion order, not start order.** The repository has
-- already paid for that once — Managed Terraform claims a generation per plan
-- and discards callbacks whose generation is stale — and here the consequence
-- is worse than a wasted result: the stale answer populates a picker. Choose
-- inventory A, change your mind, choose B, and A's groups arrive and are shown
-- as B's.
--
-- So every inspection takes the generation it started under and answers only
-- while that is still the current one. Nothing else defends against it: an
-- in-flight `ansible-inventory` against a dynamic source can outlive several
-- more decisions, and there is no point in the call chain where the process
-- can be asked which question it was answering.
--
-- **This lands with the first commit that spawns a subprocess** (§13.3).
-- Retrofitting it would mean auditing every callback that already exists.

local gate = require("chroma-ansible.gate")

local M = {}

--- Planner runs started in this session. Ids are never reused, so two runs are
--- never confusable in a message even after the first has been abandoned.
local started = 0

---@class chroma_ansible.Run
---@field id integer this session's nth planner run
---@field generation integer bumped by every decision; inspections carry it
---@field directory string|nil the frozen working directory, once chosen (§3.4)
---@field plan chroma_ansible.Plan the decisions so far, as `argv` wants them
---@field gate table the consent, one per run and never shared (§6.4)
---@field process vim.SystemObj|nil the inspection in flight, if there is one

---A copy of a list of strings.
---
---Copied on the way in and on the way out. The caller owns the list it passed
---and may keep editing it; a run that held the same table would change its mind
---without anybody deciding anything, and a generation would never be bumped for
---the change because no setter was called.
---@param list string[]
---@return string[]
local function copy(list)
  return vim.list_slice(list, 1, #list)
end

---A run that has decided nothing.
---
---The plan starts complete and empty rather than growing fields as steps are
---taken: `argv` refuses a plan whose lists are missing, and a half-built table
---would make that refusal say "the tags are not a list" when the real answer is
---"no tags step has run yet".
---@return chroma_ansible.Run
function M.start()
  started = started + 1

  return {
    id = started,
    generation = 0,
    directory = nil,
    plan = {
      executable = nil,
      playbooks = {},
      inventory = {},
      limit = nil,
      tags = {},
      remote_user = nil,
      become = false,
      ask_become_pass = false,
      vault = {},
      check = false,
      diff = false,
    },
    gate = gate.new(),
    process = nil,
  }
end

---Ends the current generation and begins another.
---
---Unconditional, and deliberately so: it is never asked whether the value
---really changed. Bumping once too often costs a discarded callback, which
---§13.2 calls an expected outcome rather than an error; bumping once too rarely
---costs an answer to an old question presented as an answer to the new one.
---Those two mistakes are not the same size.
---@param run chroma_ansible.Run
---@return integer generation the one that is now current
function M.invalidate(run)
  run.generation = run.generation + 1
  return run.generation
end

---Whether an inspection that started under `mine` may still speak.
---
---Asked by the callback before it touches any state or any UI (§13.2).
---@param run chroma_ansible.Run
---@param mine integer
---@return boolean
function M.current(run, mine)
  return run.generation == mine
end

---Records the program every subprocess of this run will start.
---
---Resolved once, by the caller, before the run begins (§15.2). It bumps the
---generation like every other setter even though it runs before anything can be
---in flight: a setter that is an exception is a setter somebody will call later
---from somewhere it is not one.
---@param run chroma_ansible.Run
---@param executable string absolute path to `ansible-playbook`
function M.set_executable(run, executable)
  run.plan.executable = executable
  M.invalidate(run)
end

---Freezes the working directory for this run.
---@param run chroma_ansible.Run
---@param frozen string canonical, from `context.freeze`
function M.set_directory(run, frozen)
  run.directory = frozen
  M.invalidate(run)
end

---@param run chroma_ansible.Run
---@param playbooks string[]
function M.set_playbooks(run, playbooks)
  run.plan.playbooks = copy(playbooks)
  M.invalidate(run)
end

---@param run chroma_ansible.Run
---@param sources string[] `-i` sources in the operator's order; never sorted
function M.set_inventory(run, sources)
  run.plan.inventory = copy(sources)
  M.invalidate(run)
end

---@param run chroma_ansible.Run
---@param tags string[]
function M.set_tags(run, tags)
  run.plan.tags = copy(tags)
  M.invalidate(run)
end

---@param run chroma_ansible.Run
---@param limit string|nil nil is `No limit`, which emits nothing at all (§9.2)
function M.set_limit(run, limit)
  run.plan.limit = limit
  M.invalidate(run)
end

---Ends the run's current generation and stops what it started.
---
---§13.4: cancel invalidates the generation and, where the process supports it,
---terminates it. Invalidated first, so that a process exiting *because* it was
---killed still finds itself stale rather than racing the bump.
---@param run chroma_ansible.Run
function M.cancel(run)
  M.invalidate(run)

  local process = run.process
  run.process = nil
  if not process then
    return
  end

  -- A process that has already exited is the ordinary case here — cancel often
  -- arrives just after the last callback — and killing one raises rather than
  -- answering false. There is nothing to report: the outcome wanted was "it is
  -- not running", and it is not running.
  pcall(function()
    process:kill("sigterm")
  end)
end

---What the gate is asked about, taken from the run.
---
---Built here rather than assembled at each call site so that the three values
---the operator is shown are the three values the subprocess will use. A gate
---asked about a directory the run does not hold would be a prompt that names
---one execution context and covers another, which is the whole failure §6.4
---exists to prevent.
---@param run chroma_ansible.Run
---@return chroma_ansible.Subject
function M.subject(run)
  return {
    directory = run.directory or "",
    playbooks = copy(run.plan.playbooks),
    inventory = copy(run.plan.inventory),
  }
end

return M
