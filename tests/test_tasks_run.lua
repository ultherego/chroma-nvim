-- Starting a task, and the three things the terminal library would otherwise
-- decide for us: whether a second Run is a new process, what identity it has,
-- and whether the output survives the process that produced it.
--
-- The library is not driven here — what is checked is what it is asked for,
-- because that is the whole of this module's decision-making.

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local run = require("chroma.tasks.run")

local saved = {}
local opened = {}
local reported = {}

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

---@param name string|nil
---@return table task, string directory, table prepared
local function plan(name)
  return { id = "x", name = name or "Plan production", cwd = { mode = "project" }, argv = { "terraform", "plan" } },
    "/repo/terraform",
    { argv = { "/usr/bin/terraform", "plan" }, env = { AWS_PROFILE = "beta" } }
end

local T = new_set({
  hooks = {
    pre_case = function()
      opened, reported = {}, {}

      saved.open, saved.report, saved.status = run.open, run.report, run.status
      run.open = function(cmd, opts)
        local made = terminal()
        table.insert(opened, { cmd = cmd, opts = opts, terminal = made })
        return made
      end
      run.report = function(message)
        table.insert(reported, message)
      end
    end,
    post_case = function()
      run.open, run.report, run.status = saved.open, saved.report, saved.status
    end,
  },
})

-- ---------------------------------------------------------------------------
-- What it asks for

T["starting"] = new_set()

T["starting"]["opens a terminal on the prepared argv, in the resolved directory"] = function()
  local task, directory, prepared = plan()

  run.start(task, directory, prepared)

  eq(#opened, 1)
  eq(opened[1].cmd, { "/usr/bin/terraform", "plan" })
  eq(opened[1].opts.cwd, "/repo/terraform")
  eq(opened[1].opts.env, { AWS_PROFILE = "beta" })
end

T["starting"]["keeps the terminal after the process ends"] = function()
  -- The library closes a terminal whose process exited 0, which is exactly the
  -- plan somebody opened this to read.
  local task, directory, prepared = plan()

  run.start(task, directory, prepared)

  eq(opened[1].opts.auto_close, false)
end

T["starting"]["gives every run its own identity"] = function()
  -- One counter for the session, not one per task: the terminal library builds
  -- identity from command, directory, environment and count, with no room for
  -- a task id, so two tasks that run the same thing in the same place would
  -- otherwise share a terminal on their first run each.
  local task, directory, prepared = plan()
  local other = { id = "y", name = "Plan again", cwd = { mode = "project" }, argv = { "terraform", "plan" } }

  local _, first = run.start(task, directory, prepared)
  local _, second = run.start(other, directory, prepared)
  local _, third = run.start(task, directory, prepared)

  eq(first ~= second, true)
  eq(second ~= third, true)
  eq(opened[1].opts.count, first)
  eq(opened[2].opts.count, second)
  eq(opened[3].opts.count, third)
end

T["starting"]["asks the library to open a terminal, never to toggle one"] = function()
  -- Everything else here checks what the boundary is asked for; this checks the
  -- boundary itself, because `toggle` would find the terminal whose command,
  -- directory, environment and count match and hide it — a second Run would
  -- flicker a window instead of running anything.
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

  run.open = saved.open
  local ok = pcall(run.start, plan())
  package.loaded["snacks"] = library

  eq(ok, true)
  eq(called, { "open" })
end

T["starting"]["starts a process every time it is asked"] = function()
  -- Never "find the terminal that matches and hide it". One Run, one process.
  local task, directory, prepared = plan()

  run.start(task, directory, prepared)
  run.start(task, directory, prepared)

  eq(#opened, 2)
end

-- ---------------------------------------------------------------------------
-- When the process fails

T["failure"] = new_set()

T["failure"]["reports a non-zero exit"] = function()
  -- The library's own notice lives inside the switch this module turns off, so
  -- saying so is now this module's job.
  local task, directory, prepared = plan("Deploy beta")
  run.start(task, directory, prepared)

  run.status = function()
    return 2
  end
  opened[1].terminal.handlers.TermClose()

  eq(#reported, 1)
  eq(reported[1]:find("Deploy beta", 1, true) ~= nil, true)
  eq(reported[1]:find("2", 1, true) ~= nil, true)
end

T["failure"]["says nothing when the process succeeded"] = function()
  local task, directory, prepared = plan()
  run.start(task, directory, prepared)

  run.status = function()
    return 0
  end
  opened[1].terminal.handlers.TermClose()

  eq(reported, {})
end

T["failure"]["closes nothing, whatever the status"] = function()
  -- Reporting is all it does. A window that disappears on failure takes the
  -- output that explains the failure with it.
  local task, directory, prepared = plan()
  run.start(task, directory, prepared)

  local closed = false
  opened[1].terminal.close = function()
    closed = true
  end

  for _, status in ipairs({ 0, 1, 130 }) do
    run.status = function()
      return status
    end
    opened[1].terminal.handlers.TermClose()
  end

  eq(closed, false)
end

return T
