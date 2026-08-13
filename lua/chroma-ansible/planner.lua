-- What one planner run knows, and what makes what it knows stale. No UI, no
-- process, no file: an id, a generation, the frozen directory, the decisions so
-- far and the consent they were shown under. The rules are
-- `doc/chroma-ansible-design.md` §13.
--
-- **Callbacks arrive in completion order, not start order**, and here a stale
-- answer populates a picker: choose inventory A, change to B, and A's groups
-- are shown as B's. So every inspection carries the generation it started under
-- and answers only while that is current. Nothing else defends against it — an
-- in-flight `ansible-inventory` can outlive several more decisions, and no
-- point in the chain can ask the process which question it was answering.

local context = require("chroma-ansible.context")
local gate = require("chroma-ansible.gate")

local M = {}

--- Planner runs started in this session. Ids are never reused, so two runs are
--- never confusable in a message.
local started = 0

---@class chroma_ansible.Run
---@field id integer this session's nth planner run
---@field generation integer bumped by every decision; inspections carry it
---@field directory string|nil the frozen working directory, once chosen (§3.4)
---@field plan chroma_ansible.Plan the decisions so far, as `argv` wants them
---@field gate table the consent, one per run and never shared (§6.4)
---@field process vim.SystemObj|nil the inspection in flight, if there is one

---A copy of a list of strings, on the way in and on the way out. The caller
---owns the list it passed and may keep editing it; a shared table would change
---a run's mind without bumping a generation.
---@param list string[]
---@return string[]
local function copy(list)
  return vim.list_slice(list, 1, #list)
end

---A run that has decided nothing. The plan starts complete and empty rather
---than growing fields: `argv` refuses a plan whose lists are missing, and a
---half-built table would make that refusal say "the tags are not a list".
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

---Ends the current generation and begins another. Unconditional: bumping once
---too often costs a discarded callback, which §13.2 calls expected, while
---bumping once too rarely presents an old answer as a new one.
---@param run chroma_ansible.Run
---@return integer generation the one that is now current
function M.invalidate(run)
  run.generation = run.generation + 1
  return run.generation
end

---Whether an inspection that started under `mine` may still speak. Asked by the
---callback before it touches any state or any UI (§13.2).
---@param run chroma_ansible.Run
---@param mine integer
---@return boolean
function M.current(run, mine)
  return run.generation == mine
end

---Records the program every subprocess of this run will start, resolved once by
---the caller before the run begins (§15.2). It bumps the generation like every
---other setter: a setter that is an exception is one somebody will later call
---from somewhere it is not.
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

---Ends the run's current generation and stops what it started (§13.4).
---Invalidated first, so a process exiting *because* it was killed still finds
---itself stale rather than racing the bump.
---@param run chroma_ansible.Run
function M.cancel(run)
  M.invalidate(run)

  local process = run.process
  run.process = nil
  if not process then
    return
  end

  -- A process that has already exited is the ordinary case — cancel often
  -- arrives just after the last callback — and killing one raises rather than
  -- answering false. The outcome wanted was "it is not running".
  pcall(function()
    process:kill("sigterm")
  end)
end

--- What `<leader>aR` repeats. One slot, in memory, for the session (§14.3): a
--- persistent form would be an explicit state model of its own.
local last = nil

---Keeps this run's decisions for a repeat: the plan and the directory.
---Deliberately absent are the host snapshot, because an autoscaling group can
---make a count false between two runs (§14.5), and the consent, which belongs
---to the three values it named (§6.4). No password is kept because none is ever
---held (§11).
---@param run chroma_ansible.Run
function M.remember(run)
  last = {
    directory = run.directory,
    plan = vim.deepcopy(run.plan),
  }
end

---Whether there is anything to repeat.
---@return boolean
function M.repeatable()
  return last ~= nil
end

---Forgets the last invocation.
---@return nil
function M.forget()
  last = nil
end

---A fresh run seeded from the last invocation, or the reason there is none. The
---executable is resolved again rather than reused (§14.4): an absolute path
---recorded an hour ago may name a program that has been removed. The directory,
---the playbooks and the sources are re-checked the same way, and the gate is new
---because the run is new (§6.4).
---@param resolve fun(name: string): string|nil how `ansible-playbook` is found
---@return chroma_ansible.Run|nil run, string|nil problem
function M.recall(resolve)
  if not last then
    return nil, "there is no Ansible invocation to repeat yet"
  end

  local executable = resolve("ansible-playbook")
  if not executable then
    return nil, "ansible-playbook is no longer on PATH"
  end
  if executable ~= last.plan.executable then
    return nil,
      ("ansible-playbook now resolves to %s rather than %s, so the last invocation is not repeated"):format(
        executable,
        tostring(last.plan.executable)
      )
  end

  local problem = context.runnable(last.directory, last.plan.playbooks, last.plan.inventory)
  if problem then
    return nil, problem
  end

  local run = M.start()
  run.directory = last.directory
  run.plan = vim.deepcopy(last.plan)

  return run, nil
end

---What the gate is asked about, taken from the run. Built here rather than at
---each call site, so the three values the operator is shown are the three the
---subprocess will use (§6.4).
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
