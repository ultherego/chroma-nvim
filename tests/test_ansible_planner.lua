-- The run, its generations, and what makes an answer too late to matter.
--
-- Two properties carry the whole concurrency model: a decision ends the
-- generation it was taken under, and what the run holds is its own copy of what
-- it was given. Break the first and a slow answer to an old question is shown
-- as an answer to the new one. Break the second and the run changes its mind
-- without anybody deciding anything — with no setter called, no generation
-- bumped, and nothing to notice.
--
-- `doc/chroma-ansible-design.md`, section 13.

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local planner = require("chroma-ansible.planner")

local T = new_set()

---A run with a directory, a playbook and one inventory source.
---@return chroma_ansible.Run
local function prepared()
  local run = planner.start()
  planner.set_executable(run, "/usr/bin/ansible-playbook")
  planner.set_directory(run, "/work/operations")
  planner.set_playbooks(run, { "plays/site_upgrade.yml" })
  planner.set_inventory(run, { "../inventories/dev/hosts.yml" })
  return run
end

-- ---------------------------------------------------------------------------
-- Starting

T["starting"] = new_set()

T["starting"]["decides nothing"] = function()
  local run = planner.start()

  eq(run.generation, 0)
  eq(run.directory, nil)
  eq(run.process, nil)
  eq(run.plan.executable, nil)
  eq(run.plan.limit, nil)
  eq(run.plan.remote_user, nil)
end

T["starting"]["begins with a complete, empty plan"] = function()
  -- Complete rather than grown field by field: `argv` refuses a plan whose
  -- lists are missing, and that refusal would name the wrong problem.
  local plan = planner.start().plan

  eq(plan.playbooks, {})
  eq(plan.inventory, {})
  eq(plan.tags, {})
  eq(plan.vault, {})
  eq({ plan.become, plan.ask_become_pass, plan.check, plan.diff }, { false, false, false, false })
end

T["starting"]["gives every run its own id"] = function()
  eq(planner.start().id == planner.start().id, false)
end

T["starting"]["gives every run its own gate"] = function()
  -- §6.4: a consent is not cached between runs. Sharing one gate object would
  -- make "start over" the one path that skips the question.
  eq(planner.start().gate == planner.start().gate, false)
end

-- ---------------------------------------------------------------------------
-- Generations

T["generations"] = new_set()

---How many times a run's generation changed while `change` ran.
---@param change fun(run: chroma_ansible.Run)
---@return integer
local function bumps(change)
  local run = prepared()
  local before = run.generation
  change(run)
  return run.generation - before
end

T["generations"]["a new working directory ends the old one"] = function()
  eq(
    bumps(function(run)
      planner.set_directory(run, "/work/other")
    end),
    1
  )
end

T["generations"]["a new playbook selection ends the old one"] = function()
  eq(
    bumps(function(run)
      planner.set_playbooks(run, { "plays/other.yml" })
    end),
    1
  )
end

T["generations"]["new inventory sources end the old one"] = function()
  eq(
    bumps(function(run)
      planner.set_inventory(run, { "../inventories/prod/hosts.yml" })
    end),
    1
  )
end

T["generations"]["new tags end the old one"] = function()
  -- Not in §13.2's list, which names the playbook, the directory, the inventory
  -- and cancelling. Tags and limits decide what `--list-hosts` answers, so an
  -- in-flight target snapshot taken under the old ones is exactly the stale
  -- answer that section exists to discard.
  eq(
    bumps(function(run)
      planner.set_tags(run, { "common" })
    end),
    1
  )
end

T["generations"]["a new limit ends the old one"] = function()
  eq(
    bumps(function(run)
      planner.set_limit(run, "webservers")
    end),
    1
  )
end

T["generations"]["choosing the same value again still ends it"] = function()
  -- Deliberate. Bumping once too often discards a callback, which §13.2 calls
  -- an expected outcome; bumping once too rarely shows an old answer as a new
  -- one. The two mistakes are not the same size, so nothing here compares.
  eq(
    bumps(function(run)
      planner.set_inventory(run, { "../inventories/dev/hosts.yml" })
    end),
    1
  )
end

T["generations"]["an inspection is current until something changes"] = function()
  local run = prepared()
  local mine = run.generation

  eq(planner.current(run, mine), true)
  planner.set_limit(run, "webservers")
  eq(planner.current(run, mine), false)
end

T["generations"]["a later generation does not revive an earlier one"] = function()
  -- Monotonic, never a toggle: going back to the previous inventory is a new
  -- decision, not the old one restored, and an answer in flight since before it
  -- was taken is stale for both.
  local run = prepared()
  local mine = run.generation

  planner.set_inventory(run, { "prod" })
  planner.set_inventory(run, { "../inventories/dev/hosts.yml" })

  eq(planner.current(run, mine), false)
end

-- ---------------------------------------------------------------------------
-- Copies

T["copies"] = new_set()

T["copies"]["the caller may keep editing the list it passed"] = function()
  local live = { "common" }
  local run = prepared()

  planner.set_inventory(run, live)
  table.insert(live, "prod")

  eq(run.plan.inventory, { "common" })
end

T["copies"]["the subject the gate sees is not the run's own lists"] = function()
  local run = prepared()
  local subject = planner.subject(run)

  table.insert(subject.playbooks, "plays/second.yml")
  table.insert(subject.inventory, "prod")

  eq(run.plan.playbooks, { "plays/site_upgrade.yml" })
  eq(run.plan.inventory, { "../inventories/dev/hosts.yml" })
end

T["copies"]["the subject names what the run will actually use"] = function()
  local run = prepared()

  eq(planner.subject(run), {
    directory = "/work/operations",
    playbooks = { "plays/site_upgrade.yml" },
    inventory = { "../inventories/dev/hosts.yml" },
  })
end

T["copies"]["a run with no directory yet offers no nil to the gate"] = function()
  -- The gate formats what it is given. A nil here would reach `string.format`
  -- and raise from inside a security prompt.
  eq(planner.subject(planner.start()).directory, "")
end

-- ---------------------------------------------------------------------------
-- Cancelling

T["cancelling"] = new_set()

T["cancelling"]["ends the generation"] = function()
  local run = prepared()
  local mine = run.generation

  planner.cancel(run)

  eq(planner.current(run, mine), false)
end

T["cancelling"]["terminates the inspection in flight"] = function()
  local killed
  local run = prepared()
  run.process = {
    kill = function(_, signal)
      killed = signal
    end,
  }

  planner.cancel(run)

  eq(killed, "sigterm")
  eq(run.process, nil)
end

T["cancelling"]["invalidates before it kills"] = function()
  -- A process exiting because it was killed must find itself stale. The other
  -- order leaves its callback racing the bump that was meant to silence it.
  local seen
  local run = prepared()
  local mine = run.generation
  run.process = {
    kill = function()
      seen = planner.current(run, mine)
    end,
  }

  planner.cancel(run)

  eq(seen, false)
end

T["cancelling"]["with nothing running is not an event"] = function()
  local run = prepared()

  planner.cancel(run)

  eq(run.process, nil)
end

-- ---------------------------------------------------------------------------
-- Repeating

T["repeating"] = new_set({
  hooks = {
    pre_case = function()
      planner.forget()
    end,
    post_case = function()
      planner.forget()
    end,
  },
})

--- A directory and a playbook on disk, because a repeat re-checks both.
local WORKING, PLAYBOOK = (function()
  local path = vim.fn.tempname()
  vim.fn.mkdir(vim.fs.joinpath(path, "plays"), "p")
  vim.fn.writefile({ "- hosts: all" }, vim.fs.joinpath(path, "plays", "site_upgrade.yml"))
  return vim.uv.fs_realpath(path), "plays/site_upgrade.yml"
end)()

--- An executable that exists, standing in for `ansible-playbook`.
local ANSIBLE = vim.fn.exepath("sh")

---A run whose paths are real.
---@return chroma_ansible.Run
local function ran()
  local run = planner.start()
  planner.set_executable(run, ANSIBLE)
  planner.set_directory(run, WORKING)
  planner.set_playbooks(run, { PLAYBOOK })
  planner.set_inventory(run, { "inventories/dev/hosts.yml" })
  planner.set_tags(run, { "common" })
  planner.set_limit(run, "webservers")
  run.plan.become = true
  return run
end

---Finds `ansible-playbook` where the test says it is.
---@param where string|nil
---@return fun(name: string): string|nil
local function resolver(where)
  return function()
    return where
  end
end

T["repeating"]["has nothing to repeat before anything ran"] = function()
  local run, problem = planner.recall(resolver(ANSIBLE))

  eq(planner.repeatable(), false)
  eq(run, nil)
  eq(problem ~= nil, true)
end

T["repeating"]["carries the decisions of the last invocation"] = function()
  planner.remember(ran())

  local run = assert(planner.recall(resolver(ANSIBLE)))

  eq(run.directory, WORKING)
  eq(run.plan.playbooks, { PLAYBOOK })
  eq(run.plan.inventory, { "inventories/dev/hosts.yml" })
  eq(run.plan.tags, { "common" })
  eq(run.plan.limit, "webservers")
  eq(run.plan.become, true)
end

T["repeating"]["carries no host snapshot"] = function()
  -- §14.5: the previous preview's `4 hosts` may have been made false by an
  -- autoscaling group before the repeat. The slot has nowhere to put one, and
  -- this is the case that keeps it that way.
  planner.remember(ran())
  local run = assert(planner.recall(resolver(ANSIBLE)))

  eq(run.plan.targets, nil)
  eq(run.targets, nil)
  eq(run.snapshot, nil)
end

T["repeating"]["asks the gate again"] = function()
  -- §6.4: a consent is bound to the three values it named, and a repeat is a
  -- new run. Inheriting the grant would be spending a yes obtained an hour ago
  -- for a context nobody has been shown since.
  local first = ran()
  first.gate.granted = { directory = WORKING, playbooks = { PLAYBOOK }, inventory = {} }
  planner.remember(first)

  local run = assert(planner.recall(resolver(ANSIBLE)))

  eq(run.gate.granted, nil)
  eq(run.gate == first.gate, false)
end

T["repeating"]["is a new run with a generation of its own"] = function()
  planner.remember(ran())

  local run = assert(planner.recall(resolver(ANSIBLE)))

  eq(run.id ~= ran().id, true)
  eq(run.process, nil)
end

T["repeating"]["does not follow later edits to the run it remembered"] = function()
  local run = ran()
  planner.remember(run)
  planner.set_limit(run, "something_else")
  table.insert(run.plan.tags, "security")

  local recalled = assert(planner.recall(resolver(ANSIBLE)))

  eq(recalled.plan.limit, "webservers")
  eq(recalled.plan.tags, { "common" })
end

T["repeating"]["is not edited by the repeat before it"] = function()
  -- A recalled run is a working copy. Somebody who repeats, changes the limit,
  -- and repeats again must get what they last ran both times — not the edit
  -- they made to a run that never started.
  planner.remember(ran())
  local first = assert(planner.recall(resolver(ANSIBLE)))
  planner.set_limit(first, "dbservers")
  table.insert(first.plan.tags, "security")

  local second = assert(planner.recall(resolver(ANSIBLE)))

  eq(second.plan.limit, "webservers")
  eq(second.plan.tags, { "common" })
end

T["repeating"]["refuses when the executable is gone"] = function()
  planner.remember(ran())

  local run, problem = planner.recall(resolver(nil))

  eq(run, nil)
  eq(problem:find("PATH", 1, true) ~= nil, true)
end

T["repeating"]["refuses when PATH now resolves it elsewhere"] = function()
  -- §14.4: repeating an absolute path recorded an hour ago would run a program
  -- nobody chose. The lookup is redone, and a different answer ends the repeat.
  planner.remember(ran())

  local run, problem = planner.recall(resolver("/opt/other/ansible-playbook"))

  eq(run, nil)
  eq(problem:find("/opt/other/ansible-playbook", 1, true) ~= nil, true)
end

T["repeating"]["refuses when the working directory is gone"] = function()
  local run = ran()
  run.directory = vim.fs.joinpath(WORKING, "removed")
  planner.set_playbooks(run, { vim.fs.joinpath(WORKING, PLAYBOOK) })
  planner.remember(run)

  local recalled, problem = planner.recall(resolver(ANSIBLE))

  eq(recalled, nil)
  eq(problem:find("working directory", 1, true) ~= nil, true)
end

T["repeating"]["refuses when a playbook can no longer be read"] = function()
  local run = ran()
  planner.set_playbooks(run, { "plays/deleted.yml" })
  planner.remember(run)

  local recalled, problem = planner.recall(resolver(ANSIBLE))

  eq(recalled, nil)
  eq(problem:find("deleted.yml", 1, true) ~= nil, true)
end

T["repeating"]["remembers the most recent invocation, not the first"] = function()
  planner.remember(ran())
  local second = ran()
  planner.set_limit(second, "dbservers")
  planner.remember(second)

  eq(assert(planner.recall(resolver(ANSIBLE))).plan.limit, "dbservers")
end

T["cancelling"]["survives a process that has already exited"] = function()
  -- The ordinary case: cancel arriving just after the last callback. libuv
  -- raises for a closed handle rather than answering false.
  local run = prepared()
  run.process = {
    kill = function()
      error("handle is closed")
    end,
  }

  planner.cancel(run)

  eq(run.process, nil)
end

return T
