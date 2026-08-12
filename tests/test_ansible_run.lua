-- Starting the playbook, and the agreement between two copies of one policy.
--
-- The first half is this module's own decisions: what the terminal library is
-- asked for, and the two refusals that stand between a confirmation somebody
-- read minutes ago and a process starting now.
--
-- The second half exists because §15.5 chose duplication over a shared call, so
-- that either module could be lifted into its own repository. That choice is
-- only affordable while the copies agree, and the way to keep them agreeing is
-- to check both against the same expectations from one place (§19.6).
--
-- `doc/chroma-ansible-design.md`, sections 15.5, 15.5.1 and 16.

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local planner = require("chroma-ansible.planner")
local run = require("chroma-ansible.run")
local tasks_run = require("chroma.tasks.run")

--- A directory and a playbook that exist, because both are checked before
--- anything starts.
local WORKING, PLAYBOOK = (function()
  local path = vim.fn.tempname()
  vim.fn.mkdir(vim.fs.joinpath(path, "plays"), "p")
  local playbook = vim.fs.joinpath(path, "plays", "site_upgrade.yml")
  vim.fn.writefile({ "- hosts: all" }, playbook)
  return vim.uv.fs_realpath(path), "plays/site_upgrade.yml"
end)()

--- An executable this user can run, for `argv[0]`.
local ANSIBLE = vim.fn.exepath("sh")

local saved, opened, reported

---A fake terminal that records the handlers it is given.
---@return table
local function terminal()
  return {
    handlers = {},
    on = function(self, event, handler)
      self.handlers[event] = handler
      return self
    end,
  }
end

---@param module table either implementation
---@return function restore
local function intercept(module)
  local before = { open = module.open, report = module.report, status = module.status }
  module.open = function(cmd, opts)
    local made = terminal()
    table.insert(opened, { cmd = cmd, opts = opts, terminal = made })
    return made
  end
  module.report = function(message)
    table.insert(reported, message)
  end
  return function()
    module.open, module.report, module.status = before.open, before.report, before.status
  end
end

local T = new_set({
  hooks = {
    pre_case = function()
      opened, reported = {}, {}
      saved = { ansible = intercept(run), tasks = intercept(tasks_run) }
    end,
    post_case = function()
      saved.ansible()
      saved.tasks()
    end,
  },
})

---A run whose directory and playbook are on disk.
---@return chroma_ansible.Run
local function prepared()
  local prepared_run = planner.start()
  planner.set_executable(prepared_run, ANSIBLE)
  planner.set_directory(prepared_run, WORKING)
  planner.set_playbooks(prepared_run, { PLAYBOOK })
  return prepared_run
end

---@return string[]
local function command()
  return { ANSIBLE, "-i", "inventories/dev/hosts.yml", PLAYBOOK }
end

-- ---------------------------------------------------------------------------
-- What it asks the library for

T["starting"] = new_set()

T["starting"]["opens a terminal on the prepared array, in the frozen directory"] = function()
  local terminal_opened, problem = run.start(prepared(), command())

  eq(problem, nil)
  eq(terminal_opened ~= nil, true)
  eq(opened[1].cmd, command())
  eq(opened[1].opts.cwd, WORKING)
end

T["starting"]["passes no environment of its own"] = function()
  -- §3.5: the same effective environment for every subprocess of the run, and
  -- the way to have one is to edit none. The library extends the inherited
  -- environment rather than replacing it, so passing nothing inherits it whole.
  run.start(prepared(), command())

  eq(opened[1].opts.env, nil)
end

T["starting"]["keeps the terminal after the process ends"] = function()
  run.start(prepared(), command())

  eq(opened[1].opts.auto_close, false)
end

T["starting"]["reports a non-zero exit itself"] = function()
  -- Switching off the closing also switches off the library's failure notice,
  -- because that handler lives inside the `auto_close` branch.
  run.status = function()
    return 2
  end

  run.start(prepared(), command())
  opened[1].terminal.handlers.TermClose()

  eq(reported, { "ansible-playbook exited with 2" })
end

T["starting"]["says nothing about a run that succeeded"] = function()
  run.status = function()
    return 0
  end

  run.start(prepared(), command())
  opened[1].terminal.handlers.TermClose()

  eq(reported, {})
end

-- ---------------------------------------------------------------------------
-- The refusals

T["refusing"] = new_set()

T["refusing"]["a working directory that is gone"] = function()
  -- The playbook is given absolutely, so it is still readable and this case can
  -- only be refused by the directory check. Relative paths would fail the
  -- playbook check too, and the case would pass with the directory unexamined.
  local gone = prepared()
  planner.set_playbooks(gone, { vim.fs.joinpath(WORKING, PLAYBOOK) })
  gone.directory = vim.fs.joinpath(WORKING, "removed")

  local terminal_opened, problem = run.start(gone, command())

  eq(terminal_opened, nil)
  eq(problem:find("removed", 1, true) ~= nil, true)
  eq(problem:find("working directory", 1, true) ~= nil, true)
  eq(#opened, 0)
end

T["refusing"]["a playbook that can no longer be read"] = function()
  local missing = prepared()
  planner.set_playbooks(missing, { "plays/deleted.yml" })

  local terminal_opened, problem = run.start(missing, command())

  eq(terminal_opened, nil)
  eq(problem:find("deleted.yml", 1, true) ~= nil, true)
  eq(#opened, 0)
end

T["refusing"]["an argv[0] that is no longer executable"] = function()
  -- Measured on Neovim 0.12.4, §15.2: `jobstart` validates `argv[0]` after the
  -- terminal window already exists, so an unchecked path produces `E475` inside
  -- an empty window instead of a refusal that names the path.
  local terminal_opened, problem = run.start(prepared(), { vim.fs.joinpath(WORKING, "not-here"), PLAYBOOK })

  eq(terminal_opened, nil)
  eq(problem:find("not-here", 1, true) ~= nil, true)
  eq(#opened, 0)
end

T["refusing"]["resolves a relative playbook against the frozen directory"] = function()
  -- Not against Neovim's directory, which is where the editor happens to be and
  -- not where the process will start. Checking there would check a file nobody
  -- is about to run — and would pass or fail for the wrong reason.
  local terminal_opened, problem = run.start(prepared(), command())

  eq(problem, nil)
  eq(terminal_opened ~= nil, true)
end

-- ---------------------------------------------------------------------------
-- One counter for all of Chroma

T["the counter"] = new_set()

T["the counter"]["gives every run of this module its own identity"] = function()
  local _, _, first = run.start(prepared(), command())
  local _, _, second = run.start(prepared(), command())

  eq(first ~= second, true)
  eq(opened[1].opts.count, first)
  eq(opened[2].opts.count, second)
end

T["the counter"]["is not restarted by the other implementation"] = function()
  -- §15.5.1: a terminal's identity is command, directory, environment and
  -- count, with no room for the module that opened it. Two private counters
  -- would hand the same identity to a planner run and to a Project Task
  -- declaring `argv: ["ansible-playbook", …]` in the same directory — which is
  -- a task §2 says a repository is allowed to write.
  local task = { id = "x", name = "Run the playbook", cwd = { mode = "project" } }
  local prepared_task = { argv = command(), env = {} }

  vim.g.chroma_terminal_run_id = 100

  local _, _, planner_id = run.start(prepared(), command())
  local _, task_id = tasks_run.start(task, WORKING, prepared_task)
  local _, _, second_planner_id = run.start(prepared(), command())

  -- Consecutive, not merely different: two private counters would also produce
  -- three different numbers here, right up to the run where they both say one.
  eq({ planner_id, task_id, second_planner_id }, { 101, 102, 103 })
end

T["the counter"]["is the well-known variable both modules name"] = function()
  vim.g.chroma_terminal_run_id = 40

  local _, _, id = run.start(prepared(), command())

  eq(id, 41)
  eq(vim.g.chroma_terminal_run_id, 41)
end

-- ---------------------------------------------------------------------------
-- The two copies agree

T["agreement"] = new_set()

---Starts one run through each implementation and answers what each asked for.
---@return table planner_opts, table task_opts
local function both()
  run.start(prepared(), command())
  tasks_run.start(
    { id = "x", name = "Plan production", cwd = { mode = "project" } },
    WORKING,
    { argv = command(), env = {} }
  )
  return opened[1].opts, opened[2].opts
end

T["agreement"]["both keep the terminal after the process exits"] = function()
  local planner_opts, task_opts = both()

  -- §19.6's mutation: `auto_close = true` in either module fails here.
  eq({ planner_opts.auto_close, task_opts.auto_close }, { false, false })
end

T["agreement"]["both give the run its own count"] = function()
  local planner_opts, task_opts = both()

  eq(type(planner_opts.count), "number")
  eq(planner_opts.count ~= task_opts.count, true)
end

T["agreement"]["both start in the directory they were given"] = function()
  local planner_opts, task_opts = both()

  eq({ planner_opts.cwd, task_opts.cwd }, { WORKING, WORKING })
end

T["agreement"]["both report a failure themselves and close nothing"] = function()
  run.status = function()
    return 3
  end
  tasks_run.status = function()
    return 3
  end

  both()
  opened[1].terminal.handlers.TermClose()
  opened[2].terminal.handlers.TermClose()

  eq(#reported, 2)
  for _, message in ipairs(reported) do
    eq(message:find("3", 1, true) ~= nil, true)
  end
end

T["agreement"]["both ask the library to open, never to toggle"] = function()
  -- The one case that reaches past the seam, because `toggle` would find the
  -- terminal whose command, directory, environment and count match and hide it:
  -- a second Run would flicker a window instead of running anything.
  local called = {}
  local library = package.loaded["snacks"]
  package.loaded["snacks"] = {
    terminal = {
      open = function()
        table.insert(called, "open")
        return terminal()
      end,
      toggle = function()
        table.insert(called, "toggle")
        return terminal()
      end,
    },
  }

  local restore_ansible = run.open
  local restore_tasks = tasks_run.open
  package.loaded["chroma-ansible.run"] = nil
  package.loaded["chroma.tasks.run"] = nil
  local fresh_ansible = require("chroma-ansible.run")
  local fresh_tasks = require("chroma.tasks.run")
  fresh_ansible.open(command(), {})
  fresh_tasks.open(command(), {})

  package.loaded["snacks"] = library
  run.open, tasks_run.open = restore_ansible, restore_tasks

  eq(called, { "open", "open" })
end

return T
