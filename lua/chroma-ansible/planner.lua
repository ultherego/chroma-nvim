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

--- The run that owns the interaction, of which there is at most one. Generations
--- settle which answer inside a run is current; they cannot settle anything
--- between two runs, because starting a second one leaves the first's generation
--- exactly where it was. A slow inventory from a run the operator has walked
--- away from would still pass `current` and open a picker beside the run they
--- are actually in.
local active = nil

---@class chroma_ansible.Run
---@field id integer this session's nth planner run
---@field generation integer bumped by every decision; inspections carry it
---@field directory string|nil the frozen working directory, once chosen (§3.4)
---@field environment table<string, string> the frozen environment, from the moment the run began (§3.5)
---@field plan chroma_ansible.Plan the decisions so far, as `argv` wants them
---@field gate table the consent, one per run and never shared (§6.4)
---@field process vim.SystemObj|nil the inspection in flight, if there is one
---@field stop fun()|nil takes down whatever this run has on screen, set by whatever put it there

---A copy of a list of strings, on the way in and on the way out. The caller
---owns the list it passed and may keep editing it; a shared table would change
---a run's mind without bumping a generation.
---@param list string[]
---@return string[]
local function copy(list)
  return vim.list_slice(list, 1, #list)
end

---Ends whatever owns the interaction now, if anything does.
---
---Called when the operator starts something else, which they do by pressing a
---key — not by getting as far as a run object. A repeat that refuses because
---the executable moved still means "not that one any more", and leaving the
---previous run its authority would let it open a picker minutes later.
---@return boolean ended whether anything was there to end
function M.supersede()
  if not active then
    return false
  end
  M.cancel(active)
  return true
end

---A run that has decided nothing. The plan starts complete and empty rather
---than growing fields: `argv` refuses a plan whose lists are missing, and a
---half-built table would make that refusal say "the tags are not a list".
---@return chroma_ansible.Run
function M.start()
  -- Before the new run exists, so there is never a moment with two of them.
  M.supersede()

  started = started + 1

  local run = {
    id = started,
    generation = 0,
    directory = nil,

    -- §3.5, and taken here rather than before each subprocess. Chroma itself
    -- edits `vim.env` while a run is being planned — `chroma-aws` switches
    -- `AWS_PROFILE` and the region — so an environment read per subprocess is a
    -- different environment per subprocess, and the hosts the preview reports
    -- would have been resolved somewhere other than where the playbook runs.
    -- `environ()` answers with a fresh table, so this is a copy and not a view.
    environment = vim.fn.environ(),

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
    stop = nil,
  }

  active = run
  return run
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

---Whether this run still owns the interaction.
---
---Asked by anything holding a callback that was armed earlier — a picker that
---is still on screen, an input waiting to be typed into. A setter bumps the
---generation, so an answer arriving into a superseded run would otherwise make
---it current again and walk it on towards a preview nobody is looking at.
---@param run chroma_ansible.Run
---@return boolean
function M.owns(run)
  return active == run
end

---Whether an inspection that started under `mine` may still speak. Asked by the
---callback after it is back on the main loop and before it touches any state or
---any UI (§13.2).
---
---Two questions, because there are two ways to stop being current: the run has
---moved on, and the operator has moved on to another run.
---@param run chroma_ansible.Run
---@param mine integer
---@return boolean
function M.current(run, mine)
  return active == run and run.generation == mine
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
  -- Authority goes first and unconditionally. Killing is a request to another
  -- process: it can fail, and it can arrive after the process has already
  -- exited. Neither may decide whether a callback still counts.
  M.invalidate(run)

  if active == run then
    active = nil
  end

  -- Whatever this run has on screen goes with it, without this module having to
  -- know what that is. A run that has been ended but is still showing something
  -- is an inspection nobody can stop, which is the thing being fixed.
  local stop = run.stop
  run.stop = nil
  if stop then
    pcall(stop)
  end

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

---Forgets the last invocation, and that anything owns the interaction. For
---tests, which would otherwise leave one case's run superseding the next one's.
---@return nil
function M.forget()
  last = nil
  active = nil
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
