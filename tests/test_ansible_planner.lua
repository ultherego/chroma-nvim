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
