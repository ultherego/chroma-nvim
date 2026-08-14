-- The one place a planner run may start a process.
--
-- Three invariants are being held here at once, and each of them is only worth
-- anything if it holds on every path: no process before the consent that named
-- it, no answer from a question the operator has already moved past, and no
-- Ansible output written anywhere by this module. The cases below therefore
-- check what did *not* happen at least as often as what did.
--
-- `doc/chroma-ansible-design.md`, sections 6, 7, 13 and 16.

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local gate = require("chroma-ansible.gate")
local inspect = require("chroma-ansible.inspect")
local planner = require("chroma-ansible.planner")

--- A graph the parser accepts, as `ansible-inventory --graph` writes one.
local GRAPH = table.concat({
  "@all:",
  "  |--@ungrouped:",
  "  |  |--standalone",
  "  |--@webservers:",
  "  |  |--web01",
  "",
}, "\n")

local asked, answer, spawned, notified, restore

local T = new_set({
  hooks = {
    pre_case = function()
      asked, answer, spawned, notified = 0, true, {}, {}
      restore = { confirm = gate.confirm, system = inspect.system, notify = vim.notify }

      gate.confirm = function()
        asked = asked + 1
        return answer
      end

      -- Records rather than starts. Nothing in this suite runs an Ansible, so a
      -- case that spawned for real would be a case that passed on a machine
      -- with the wrong one installed.
      inspect.system = function(cmd, opts, on_exit)
        local process = { killed = nil }
        function process:kill(signal)
          self.killed = signal
        end
        table.insert(spawned, { cmd = cmd, opts = opts, on_exit = on_exit, process = process })
        return process
      end

      vim.notify = function(message, level)
        table.insert(notified, { message = message, level = level })
      end
    end,
    post_case = function()
      gate.confirm = restore.confirm
      inspect.system = restore.system
      vim.notify = restore.notify
    end,
  },
})

--- A directory that exists, because the frozen one is checked before spawning.
local WORKING = (function()
  local path = vim.fn.tempname()
  vim.fn.mkdir(path, "p")
  return vim.uv.fs_realpath(path)
end)()

---A run ready to inspect.
---@return chroma_ansible.Run
local function prepared()
  local run = planner.start()
  planner.set_executable(run, "/usr/bin/ansible-playbook")
  planner.set_directory(run, WORKING)
  planner.set_playbooks(run, { "plays/site_upgrade.yml" })
  planner.set_inventory(run, { "inventories/dev/hosts.yml" })
  return run
end

---Runs the event loop until an answer arrives, or long enough to be sure none
---will. Answers are always scheduled, so nothing here can be read synchronously.
---@param arrived fun(): boolean
local function settle(arrived)
  vim.wait(200, arrived, 5)
end

---Records what an inspection answered.
---@return { answer: chroma_ansible.Answer|nil, calls: integer }, fun(answer: chroma_ansible.Answer)
local function recorder()
  local seen = { answer = nil, calls = 0 }
  return seen, function(given)
    seen.calls = seen.calls + 1
    seen.answer = given
  end
end

---Inspects the inventory, and answers with whatever the callback was handed.
---@param run chroma_ansible.Run
---@return { answer: chroma_ansible.Answer|nil, calls: integer }
local function inspecting(run)
  local seen, record = recorder()
  inspect.inventory(run, "/usr/bin/ansible-inventory", record)
  return seen
end

---Asks for the tags, and answers the same way.
---@param run chroma_ansible.Run
---@return { answer: chroma_ansible.Answer|nil, calls: integer }
local function tagging(run)
  local seen, record = recorder()
  inspect.tags(run, record)
  return seen
end

---Finishes the process a case started.
---@param result table what `vim.system` would report
local function exits(result)
  spawned[#spawned].on_exit(vim.tbl_extend("force", { code = 0, stdout = "", stderr = "" }, result))
end

-- ---------------------------------------------------------------------------
-- Resolving the tools

T["tools"] = new_set()

T["tools"]["resolve to an absolute path"] = function()
  local path = inspect.tool("sh")

  eq(type(path), "string")
  eq(vim.startswith(path, "/"), true)
end

T["tools"]["that are not installed resolve to nothing"] = function()
  eq(inspect.tool("ansible-playbook-that-is-not-installed"), nil)
  eq(inspect.tool(""), nil)
end

-- ---------------------------------------------------------------------------
-- The gate comes first

T["the gate"] = new_set()

T["the gate"]["is asked before the first subprocess"] = function()
  local run = prepared()
  local order = {}
  local confirm = gate.confirm
  gate.confirm = function(...)
    table.insert(order, "gate")
    return confirm(...)
  end
  local system = inspect.system
  inspect.system = function(...)
    table.insert(order, "spawn")
    return system(...)
  end

  inspecting(run)

  eq(order, { "gate", "spawn" })
end

T["the gate"]["answered No starts nothing"] = function()
  answer = false
  local seen = inspecting(prepared())
  settle(function()
    return seen.answer ~= nil
  end)

  eq(#spawned, 0)
  eq(seen.answer, { declined = true })
end

T["the gate"]["is not asked when there is nothing to consent to"] = function()
  -- The directory is gone. Asking would name an execution context that cannot
  -- be used, and a yes to it would be a yes obtained for nothing.
  local run = prepared()
  run.directory = vim.fs.joinpath(WORKING, "removed")

  local seen = inspecting(run)
  settle(function()
    return seen.answer ~= nil
  end)

  eq(asked, 0)
  eq(#spawned, 0)
  eq(seen.answer.problem ~= nil, true)
  eq(seen.answer.problem:find("removed", 1, true) ~= nil, true)
end

T["the gate"]["is not asked for a plan that cannot be built"] = function()
  local run = prepared()
  planner.set_playbooks(run, {})

  local seen = inspecting(run)
  settle(function()
    return seen.answer ~= nil
  end)

  eq(asked, 0)
  eq(#spawned, 0)
  eq(seen.answer.problem, "the plan has no playbook")
end

-- ---------------------------------------------------------------------------
-- What is asked of Ansible

T["the command"] = new_set()

T["the command"]["asks for the graph and never for the list"] = function()
  inspecting(prepared())
  local cmd = spawned[1].cmd

  eq(cmd[1], "/usr/bin/ansible-inventory")
  eq(vim.tbl_contains(cmd, "--graph"), true)
  -- §7.1: `--list` prints every host variable in plaintext, and `--vars` is
  -- what adds them to a graph. Neither may ever appear.
  eq(vim.tbl_contains(cmd, "--list"), false)
  eq(vim.tbl_contains(cmd, "--vars"), false)
end

T["the command"]["carries the inventory sources in the operator's order"] = function()
  local run = prepared()
  planner.set_inventory(run, { "common", "prod" })

  inspecting(run)

  eq(spawned[1].cmd, { "/usr/bin/ansible-inventory", "-i", "common", "-i", "prod", "--graph" })
end

T["the command"]["runs in the frozen directory, not the editor's"] = function()
  -- §3.4: `:cd` after the choice may move Neovim and may not move the run.
  local elsewhere = vim.fn.getcwd()
  local run = prepared()

  inspecting(run)

  eq(spawned[1].opts.cwd, WORKING)
  eq(spawned[1].opts.cwd == elsewhere, false)
end

-- ---------------------------------------------------------------------------
-- Tags

T["tags"] = new_set()

T["tags"]["are asked of ansible-playbook in the same context"] = function()
  local run = prepared()
  planner.set_inventory(run, { "common", "prod" })

  tagging(run)

  -- §3.5 and §8.4: an inventory is passed even though tags do not need one,
  -- because a listing that resolved a different inventory than the run would be
  -- a listing of a different question.
  eq(spawned[1].cmd, {
    "/usr/bin/ansible-playbook",
    "-i",
    "common",
    "-i",
    "prod",
    "--list-tags",
    "plays/site_upgrade.yml",
  })
  eq(spawned[1].opts.cwd, WORKING)
end

T["tags"]["never carry a flag that would ask for a password"] = function()
  -- Measured, §3.5: `--list-tags --ask-vault-pass` stops at `Vault password:`
  -- and ends in `EOFError`, because a `vim.system` child has no terminal.
  local run = prepared()
  run.plan.ask_become_pass = true
  run.plan.vault = { "--ask-vault-pass" }

  tagging(run)

  eq(vim.tbl_contains(spawned[1].cmd, "-K"), false)
  eq(vim.tbl_contains(spawned[1].cmd, "--ask-vault-pass"), false)
end

T["tags"]["answer what Ansible reported"] = function()
  local seen = tagging(prepared())
  exits({ stdout = "\nplaybook: p.yml\n\n  play #1 (all): all\tTAGS: []\n      TASK TAGS: [common, security]\n" })
  settle(function()
    return seen.answer ~= nil
  end)

  eq(seen.answer.tags, { "common", "security" })
end

T["tags"]["report Ansible's own words when the listing fails"] = function()
  local seen = tagging(prepared())
  exits({ code = 4, stderr = "[ERROR]: couldn't resolve module/action 'bogus'\n" })
  settle(function()
    return seen.answer ~= nil
  end)

  -- §16: a failed listing does not end the planner, and it does not invent a
  -- reason either. `Custom tag…` is how the operator carries on.
  eq(seen.answer.tags, nil)
  eq(seen.answer.problem, "[ERROR]: couldn't resolve module/action 'bogus'")
end

T["tags"]["are not half-read from a listing that named no plays"] = function()
  local seen = tagging(prepared())
  exits({ stdout = "\nplaybook: p.yml\n\n" })
  settle(function()
    return seen.answer ~= nil
  end)

  eq(seen.answer.tags, nil)
  eq(seen.answer.problem ~= nil, true)
end

T["tags"]["are covered by the consent the inventory was inspected under"] = function()
  -- §6.4: one yes opens every introspection call of that run. Asking again for
  -- the same three values would be a prompt that has stopped meaning anything.
  local run = prepared()
  inspecting(run)
  tagging(run)

  eq(asked, 1)
  eq(#spawned, 2)
end

T["tags"]["ask again once the consent no longer covers the run"] = function()
  local run = prepared()
  inspecting(run)
  planner.set_inventory(run, { "inventories/prod/hosts.yml" })
  tagging(run)

  eq(asked, 2)
end

T["tags"]["are discarded when the operator has moved on"] = function()
  local run = prepared()
  local seen = tagging(run)

  planner.set_playbooks(run, { "plays/other.yml" })
  exits({ stdout = "      TASK TAGS: [common]\n" })
  settle(function()
    return seen.calls > 0
  end)

  eq(seen.calls, 0)
end

-- ---------------------------------------------------------------------------
-- Targets

T["targets"] = new_set()

T["targets"]["are asked with the limit the operator chose"] = function()
  local run = prepared()
  planner.set_limit(run, "webservers:&production")
  planner.set_tags(run, { "common", "security" })

  local seen, record = recorder()
  inspect.targets(run, record)

  -- The pattern reaches Ansible byte for byte: no shell, no quoting, no
  -- interpretation of `:&` by anything but Ansible (§9.3).
  eq(spawned[1].cmd, {
    "/usr/bin/ansible-playbook",
    "-i",
    "inventories/dev/hosts.yml",
    "-l",
    "webservers:&production",
    "--tags",
    "common",
    "--tags",
    "security",
    "--list-hosts",
    "plays/site_upgrade.yml",
  })
  eq(seen.calls, 0)
end

T["targets"]["ask for nothing when the operator chose No limit"] = function()
  -- §9.2: `No limit` emits no `-l` at all rather than `-l all`, because the
  -- playbook's own `hosts:` is the authority and `-l all` would override it.
  local seen, record = recorder()
  inspect.targets(prepared(), record)

  eq(vim.tbl_contains(spawned[1].cmd, "-l"), false)
  eq(vim.tbl_contains(spawned[1].cmd, "all"), false)
  eq(seen.calls, 0)
end

T["targets"]["answer the hosts Ansible resolved just now"] = function()
  local seen, record = recorder()
  inspect.targets(prepared(), record)
  exits({
    stdout = "  play #1 (all): all\tTAGS: []\n    pattern: ['all']\n    hosts (2):\n      web01\n      web02\n",
  })
  settle(function()
    return seen.answer ~= nil
  end)

  eq(seen.answer.targets, { "web01", "web02" })
end

T["targets"]["report the failure a pattern matching nothing produces"] = function()
  local seen, record = recorder()
  inspect.targets(prepared(), record)
  exits({
    code = 1,
    stderr = "[WARNING]: Could not match supplied host pattern, ignoring: nope\n"
      .. "[ERROR]: Specified inventory, host pattern and/or --limit leaves us with no hosts to target.\n",
  })
  settle(function()
    return seen.answer ~= nil
  end)

  -- Measured: that is what a typo in a limit looks like. §16 keeps it out of the
  -- run's way — the preview omits the snapshot and says so, and the run stands.
  eq(seen.answer.targets, nil)
  eq(seen.answer.problem:find("no hosts to target", 1, true) ~= nil, true)
end

T["targets"]["are not read from output a failing listing left behind"] = function()
  local seen, record = recorder()
  inspect.targets(prepared(), record)
  exits({
    code = 4,
    stdout = "  play #1 (all): all\tTAGS: []\n    hosts (1):\n      web01\n",
    stderr = "[ERROR]: couldn't resolve module/action 'bogus'\n",
  })
  settle(function()
    return seen.answer ~= nil
  end)

  -- Measured on 2.21.2: a broken playbook among several prints nothing at all
  -- before exiting 4, so this shape is a wrapper's or a later version's. The
  -- rule is the same either way — a listing that failed reported nothing, and
  -- half of what it printed is not a target list.
  eq(seen.answer.targets, nil)
  eq(seen.answer.problem:find("bogus", 1, true) ~= nil, true)
end

-- ---------------------------------------------------------------------------
-- Answers

T["answers"] = new_set()

T["answers"]["never arrive before the call returns"] = function()
  -- Uniform arrival, on every path. A caller that had to know which of its
  -- answers might land synchronously would be a caller that gets it wrong once.
  local run = prepared()
  local before
  inspect.inventory(run, "/usr/bin/ansible-inventory", function()
    before = true
  end)
  exits({ stdout = GRAPH })

  eq(before, nil)
  settle(function()
    return before ~= nil
  end)
  eq(before, true)
end

T["answers"]["carry the groups and hosts Ansible reported"] = function()
  local seen = inspecting(prepared())
  exits({ stdout = GRAPH })
  settle(function()
    return seen.answer ~= nil
  end)

  eq(seen.answer.problem, nil)
  eq(seen.answer.graph.groups, { "all", "ungrouped", "webservers" })
  eq(seen.answer.graph.hosts, { "standalone", "web01" })
end

T["answers"]["repeat Ansible's own words when it fails"] = function()
  local seen = inspecting(prepared())
  exits({ code = 1, stderr = "[WARNING]: something\n[ERROR]: Unable to parse inventory source\n" })
  settle(function()
    return seen.answer ~= nil
  end)

  -- Not summarised, not rewritten, not truncated (§16). Only the trailing
  -- newline goes.
  eq(seen.answer.graph, nil)
  eq(seen.answer.problem, "[WARNING]: something\n[ERROR]: Unable to parse inventory source")
end

T["answers"]["name the status when a failure said nothing at all"] = function()
  local seen = inspecting(prepared())
  exits({ code = 127 })
  settle(function()
    return seen.answer ~= nil
  end)

  eq(seen.answer.problem, "the inspection exited with status 127 and said nothing")
end

T["answers"]["treat an unreadable graph as a failed inspection"] = function()
  local seen = inspecting(prepared())
  exits({ stdout = "@all:\n  |--web01\nnot a line this parser knows\n" })
  settle(function()
    return seen.answer ~= nil
  end)

  -- All or nothing (§7.3). A tree parsed down to its first bad line looks
  -- exactly like a small inventory.
  eq(seen.answer.graph, nil)
  eq(seen.answer.problem ~= nil, true)
end

T["answers"]["do not quote the graph line they could not read"] = function()
  local seen = inspecting(prepared())
  exits({ stdout = "@all:\n  |--web01\nbastion-of-a-private-network\n" })
  settle(function()
    return seen.answer ~= nil
  end)

  -- §7.4: a graph line carries host names. The parser says which line, and the
  -- interface shows that; neither repeats what was on it.
  eq(seen.answer.problem:find("bastion", 1, true), nil)
end

T["answers"]["say so when the process could not be started"] = function()
  inspect.system = function()
    error("ENOENT: no such file or directory")
  end

  local seen = inspecting(prepared())
  settle(function()
    return seen.answer ~= nil
  end)

  -- `vim.system` raises rather than answering for a request it will not even
  -- attempt. Letting that reach the caller would leave the planner waiting for
  -- a callback no process will produce.
  eq(seen.answer.problem:find(WORKING, 1, true) ~= nil, true)
  eq(seen.answer.problem:find("ENOENT", 1, true) ~= nil, true)
end

-- ---------------------------------------------------------------------------
-- Generations

T["generations"] = new_set()

T["generations"]["a superseded inspection answers nothing"] = function()
  local run = prepared()
  local seen = inspecting(run)

  -- The operator chose a different inventory while the first was still
  -- resolving; the first then finished. Without the check its groups would be
  -- presented as the second source's.
  planner.set_inventory(run, { "inventories/prod/hosts.yml" })
  exits({ stdout = GRAPH })
  settle(function()
    return seen.calls > 0
  end)

  eq(seen.calls, 0)
end

T["generations"]["a superseded failure is not reported either"] = function()
  local run = prepared()
  local seen = inspecting(run)

  planner.cancel(run)
  exits({ code = 1, stderr = "[ERROR]: no\n" })
  settle(function()
    return seen.calls > 0
  end)

  -- Discarding is the expected outcome of having moved on, not an error to
  -- show (§13.2).
  eq(seen.calls, 0)
  eq(#notified, 0)
end

T["generations"]["an inspection belonging to a superseded run answers nothing"] = function()
  -- The operator pressed the key again. Nothing about this run changed, which
  -- is exactly why its generation could not catch this on its own.
  local run = prepared()
  local seen = inspecting(run)

  planner.start()
  exits({ stdout = GRAPH })
  settle(function()
    return seen.calls > 0
  end)

  eq(seen.calls, 0)
  eq(#notified, 0)
end

T["generations"]["an answer already on the queue is still discarded"] = function()
  -- Authority cannot be checked where the subprocess exits: by then the answer
  -- is scheduled, and the operator can start something else before it runs. It
  -- is checked after the schedule, on the way back to the main loop.
  local run = prepared()
  local seen = inspecting(run)

  exits({ stdout = GRAPH })
  planner.start()

  settle(function()
    return seen.calls > 0
  end)

  eq(seen.calls, 0)
end

T["generations"]["a live inspection still answers"] = function()
  -- The counterpart, so that "answers nothing" cannot pass by answering never.
  local run = prepared()
  local seen = inspecting(run)

  exits({ stdout = GRAPH })
  settle(function()
    return seen.calls > 0
  end)

  eq(seen.calls, 1)
end

T["generations"]["cancelling terminates what was started here"] = function()
  local run = prepared()
  inspecting(run)

  planner.cancel(run)

  eq(spawned[1].process.killed, "sigterm")
end

T["generations"]["a stale answer leaves a newer inspection's process alone"] = function()
  -- The old callback must not clear `run.process`: cancelling afterwards would
  -- then have nothing to kill and the newer subprocess would outlive the run.
  local run = prepared()
  inspecting(run)
  local first = spawned[1]

  planner.set_inventory(run, { "inventories/prod/hosts.yml" })
  inspecting(run)
  first.on_exit({ code = 0, stdout = GRAPH, stderr = "" })
  settle(function()
    return false
  end)

  eq(run.process, spawned[2].process)
end

-- ---------------------------------------------------------------------------
-- Nothing is logged

T["logging"] = new_set()

T["logging"]["a successful inspection writes nothing anywhere"] = function()
  local seen = inspecting(prepared())
  exits({ stdout = GRAPH })
  settle(function()
    return seen.answer ~= nil
  end)

  -- §7.4 and §19.16: host names reach the picker and nothing else. A
  -- notification is a message history entry, and `:messages` outlives the run.
  eq(#notified, 0)
end

T["logging"]["a failed inspection writes nothing either"] = function()
  local seen = inspecting(prepared())
  exits({ code = 1, stderr = "db01.internal could not be reached\n" })
  settle(function()
    return seen.answer ~= nil
  end)

  eq(#notified, 0)
  -- Handed back to the caller instead, which is what shows it.
  eq(seen.answer.problem, "db01.internal could not be reached")
end

return T
