-- One planner run, one environment, proved across a real process boundary.
--
-- Asserting what this module hands a spawn is not enough, and that is the whole
-- reason this file exists. Measured on 0.12.4: `env` alone is **merged** over
-- the editor's current environment, so options that look exactly right still
-- produce a child holding a variable that did not exist when the run began.
-- Only what the child says settles it.
--
-- What made this a bug rather than a nicety: Chroma edits `vim.env` itself while
-- a run is being planned. `chroma-aws` switches `AWS_PROFILE` and the region,
-- so `--list-hosts` could resolve against one account and `ansible-playbook`
-- run against another, with the same argv, the same directory and a preview
-- that named neither.
--
-- `doc/chroma-ansible-design.md` §3.5.

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local gate = require("chroma-ansible.gate")
local inspect = require("chroma-ansible.inspect")
local planner = require("chroma-ansible.planner")
local progress = require("chroma-ansible.progress")
local runner = require("chroma-ansible.run")

--- Something that exists on any machine this suite runs on, and is already what
--- the other Ansible suites stand a tool in for.
local SH = vim.fn.exepath("sh")

--- Prints what the child can see of the two variables under test, and nothing
--- else. `${VAR-absent}` distinguishes "unset" from "set to empty".
---
--- It exits non-zero on purpose. §16 is the only route that hands a
--- subprocess's own output back verbatim; a parse failure reports the parser's
--- words instead, and would tell this suite nothing (§7.4).
local PROBE = {
  SH,
  "-c",
  'printf "%s|%s" "${CHROMA_EXISTING-absent}" "${CHROMA_LATER-absent}"; exit 1',
}

--- A directory that exists, because the frozen one is checked before spawning.
local WORKING, PLAYBOOK = (function()
  local path = vim.fn.tempname()
  vim.fn.mkdir(vim.fs.joinpath(path, "plays"), "p")
  local playbook = vim.fs.joinpath(path, "plays", "site_upgrade.yml")
  vim.fn.writefile({ "- hosts: all" }, playbook)
  return vim.uv.fs_realpath(path), "plays/site_upgrade.yml"
end)()

local saved

local T = new_set({
  hooks = {
    pre_case = function()
      planner.forget()
      saved = {
        system = inspect.system,
        confirm = gate.confirm,
        open = progress.open,
        existing = vim.env.CHROMA_EXISTING,
        later = vim.env.CHROMA_LATER,
      }
      progress.open = function()
        return { close = function() end }
      end
      -- Answered yes: what is being measured is what the process gets, and
      -- whether it may start at all is the gate suite's question.
      gate.confirm = function()
        return true
      end
    end,
    post_case = function()
      inspect.system = saved.system
      gate.confirm = saved.confirm
      progress.open = saved.open
      vim.env.CHROMA_EXISTING = saved.existing
      vim.env.CHROMA_LATER = saved.later
      planner.forget()
    end,
  },
})

---A run ready to inspect, started while `CHROMA_EXISTING` holds `value`.
---@param value string
---@return chroma_ansible.Run
local function started_with(value)
  vim.env.CHROMA_EXISTING = value
  vim.env.CHROMA_LATER = nil

  local run = planner.start()
  planner.set_executable(run, SH)
  planner.set_directory(run, WORKING)
  planner.set_playbooks(run, { PLAYBOOK })
  return run
end

---Runs one real inspection and answers with what the child printed.
---
---The argv is replaced and the options are not: what is under test is the
---environment those options produce in a child, not which Ansible subcommand
---was asked for. Nothing here needs an Ansible installed, and nothing here
---would pass on a machine that has the wrong one.
---@param run chroma_ansible.Run
---@return string
local function child_sees(run)
  local seen
  inspect.system = function(_, options, on_exit)
    return vim.system(PROBE, options, on_exit)
  end

  inspect.tags(run, function(answer)
    -- A non-zero exit, so §16 hands back what the child said, word for word.
    seen = answer.problem
  end)

  vim.wait(5000, function()
    return seen ~= nil
  end, 5)
  return seen or "the inspection never answered"
end

-- ---------------------------------------------------------------------------
-- The child's own account of it

T["the inspection"] = new_set()

T["the inspection"]["keeps the value a variable had when the run began"] = function()
  local run = started_with("A")

  -- The operator switched something — an AWS profile, an ANSIBLE_CONFIG — after
  -- choosing the playbook and before the inspection ran.
  vim.env.CHROMA_EXISTING = "B"

  eq(child_sees(run):find("A|", 1, true), 1)
end

T["the inspection"]["does not carry a variable invented after the run began"] = function()
  -- The half that `env` alone cannot do. Merge semantics override what the
  -- snapshot names and pass through everything it does not.
  local run = started_with("A")

  vim.env.CHROMA_LATER = "LEAKED"

  eq(child_sees(run), "A|absent")
end

T["the inspection"]["is not reading the environment when it spawns"] = function()
  -- Both at once, which is what "frozen" means: neither a changed value nor a
  -- new name reaches the child, however much the editor's environment moved
  -- between the run starting and the subprocess starting.
  local run = started_with("A")

  vim.env.CHROMA_EXISTING = "B"
  vim.env.CHROMA_LATER = "LEAKED"

  eq(child_sees(run), "A|absent")
end

T["the inspection"]["passes the environment it froze and not an empty one"] = function()
  -- `clear_env` with nothing to clear to would be a child with no PATH, no
  -- HOME and no way to say why Ansible failed.
  local run = started_with("A")

  eq(run.environment.PATH, vim.env.PATH)
  eq(child_sees(run), "A|absent")
end

-- ---------------------------------------------------------------------------
-- The execution half, across the same boundary
--
-- The final process does not go through `vim.system`. It is a terminal job, and
-- the library that opens the terminal hands `jobstart` only `cwd`, `env` and
-- `term` — so this half had to be taken over rather than configured, and is
-- worth proving separately from the half above.

T["the execution"] = new_set()

---Starts the probe with the options the run module builds — the real ones,
---`term = true` included, in a real terminal buffer — and answers with what the
---child saw.
---
---The child writes to a file rather than to its terminal, and the file is what
---is read. What is under test is the environment a process is given, and
---scraping a terminal buffer would add the rendering of a pty to that: a
---measurement of two things reports on neither. The first version of this did
---scrape, passed on two machines and a loaded container, and failed on CI.
---@param run chroma_ansible.Run
---@return string
local function terminal_sees(run)
  local buffer = vim.api.nvim_create_buf(false, true)
  local answer = vim.fn.tempname()
  local options = runner.job({ cwd = run.directory, env = run.environment })

  local job = vim.api.nvim_buf_call(buffer, function()
    return vim.fn.jobstart({
      SH,
      "-c",
      ('printf "%%s|%%s" "${CHROMA_EXISTING-absent}" "${CHROMA_LATER-absent}" > %s'):format(answer),
    }, options)
  end)
  -- A job id is positive; 0 and -1 are "invalid arguments" and "not executable",
  -- and either would otherwise read as a child that saw nothing.
  eq({ "the probe started", job > 0 }, { "the probe started", true })

  local waited = vim.fn.jobwait({ job }, 5000)
  eq({ "the probe exited", waited[1] }, { "the probe exited", 0 })

  return table.concat(vim.fn.readfile(answer), "")
end

T["the execution"]["starts in the environment the inspections ran in"] = function()
  local run = started_with("A")

  vim.env.CHROMA_EXISTING = "B"
  vim.env.CHROMA_LATER = "LEAKED"

  eq(terminal_sees(run), "A|absent")
end

T["the execution"]["is handed the same environment the inspection was"] = function()
  -- Not a second snapshot taken at preparation time. One run, one environment,
  -- and the hosts the preview reported were resolved in it.
  local run = started_with("A")

  vim.env.CHROMA_EXISTING = "B"

  eq(child_sees(run), "A|absent")
  eq(terminal_sees(run), "A|absent")
end

T["the execution"]["clears rather than overlays"] = function()
  -- The assertion that `env` alone cannot pass: merge semantics would set
  -- CHROMA_EXISTING correctly and let CHROMA_LATER through, which is a child
  -- that looks right until somebody invents a variable.
  local run = started_with("A")
  vim.env.CHROMA_LATER = "LEAKED"

  eq(runner.job({ cwd = run.directory, env = run.environment }).clear_env, true)
  eq(terminal_sees(run), "A|absent")
end

-- ---------------------------------------------------------------------------
-- Which moment is frozen

T["the snapshot"] = new_set()

T["the snapshot"]["belongs to the run, not to the preparation of a command"] = function()
  local run = started_with("A")

  eq(run.environment.CHROMA_EXISTING, "A")
  eq(run.environment.CHROMA_LATER, nil)
end

T["the snapshot"]["is a copy, so the editor's environment can move under it"] = function()
  local run = started_with("A")

  vim.env.CHROMA_EXISTING = "B"

  eq(run.environment.CHROMA_EXISTING, "A")
end

T["the snapshot"]["is taken again by the run a repeat starts"] = function()
  -- §14: a repeat recalls an invocation, not a world. The decisions are the
  -- same ones; the environment is the one the operator is in now, and the
  -- preview it stops at is where they see that.
  local first = started_with("A")
  planner.set_inventory(first, {})
  planner.remember(first)

  vim.env.CHROMA_EXISTING = "B"

  local again = assert(planner.recall(function()
    return SH
  end))

  eq(again.environment.CHROMA_EXISTING, "B")
end

return T
