-- Run Task: the order the pieces are put in, and every way it stops.
--
-- The modules each decide one thing and are tested where they live. What is
-- measured here is the sequence — which is where an integration goes wrong
-- without any single module being wrong: a picker opened before a trust modal,
-- a file read twice, an executable resolved for a task nobody chose, a command
-- prepared again after the question about it was answered.

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local tasks = require("chroma.tasks")

local availability = require("chroma.tasks.availability")
local command = require("chroma.tasks.command")
local cwd = require("chroma.tasks.cwd")
local preview = require("chroma.tasks.preview")
local run = require("chroma.tasks.run")
local schema = require("chroma.tasks.schema")
local source = require("chroma.tasks.source")
local trust = require("chroma.tasks.trust")

local DOCUMENT = [[{
  "schema": 1,
  "tasks": [
    { "id": "plan", "name": "Plan", "group": "terraform",
      "cwd": { "mode": "project" }, "argv": ["true"] }
  ]
}]]

local saved, calls, said = {}, {}, {}

---Everything the flow touched, in the order it touched it.
---@param what string
local function record(what)
  table.insert(calls, what)
end

---A project whose tasks load and run, unless a case says otherwise.
---@return table
local function project()
  return { root = "/repo", path = "/repo/.chroma/tasks.json", resolved = "/repo/.chroma/tasks.json" }
end

local T = new_set({
  hooks = {
    pre_case = function()
      calls, said = {}, {}

      saved = {
        version = availability.version,
        find = source.find,
        consult = trust.consult,
        read = schema.read,
        resolve = cwd.resolve,
        prepare = command.prepare,
        render = preview.render,
        confirm = preview.confirm,
        start = run.start,
        notify = tasks.notify,
        select = tasks.select,
      }

      -- Every step answers as it would on a machine where everything is in
      -- order. A case replaces the one it is about.
      availability.version = function()
        return vim.version.parse("0.12.4")
      end
      source.find = function()
        record("find")
        return project(), nil
      end
      trust.consult = function()
        -- The explanation is the adapter's to give, and only when a modal is
        -- coming. Recording it here for merely being handed a callback would
        -- measure the wrong thing.
        record("consult")
        return { state = "trusted", path = "/repo/.chroma/tasks.json", bytes = DOCUMENT }
      end
      schema.read = function(bytes)
        record("read")
        return saved.read(bytes)
      end
      cwd.resolve = function()
        record("resolve")
        return "/repo", nil
      end
      command.prepare = function()
        record("prepare")
        return { argv = { "/usr/bin/true" }, env = {} }, nil
      end
      preview.render = function()
        record("render")
        return { "Task" }
      end
      preview.confirm = function()
        record("confirm")
        return true
      end
      run.start = function()
        record("start")
        return {}, 1
      end
      tasks.notify = function(message)
        table.insert(said, message)
      end
      tasks.select = function(items, opts, on_choice)
        record("select")
        on_choice(items[1], 1)
      end
    end,
    post_case = function()
      availability.version = saved.version
      source.find, trust.consult, schema.read = saved.find, saved.consult, saved.read
      cwd.resolve, command.prepare = saved.resolve, saved.prepare
      preview.render, preview.confirm, run.start = saved.render, saved.confirm, saved.start
      tasks.notify, tasks.select = saved.notify, saved.select
    end,
  },
})

---Whether `said` mentions `needle`.
---@param needle string
---@return boolean
local function mentioned(needle)
  for _, message in ipairs(said) do
    if message:find(needle, 1, true) then
      return true
    end
  end
  return false
end

-- ---------------------------------------------------------------------------
-- The order

T["order"] = new_set()

T["order"]["is availability, discovery, trust, schema, then the picker"] = function()
  tasks.run()

  eq(calls, { "find", "consult", "read", "select", "resolve", "prepare", "render", "confirm", "start" })
end

T["order"]["asks about trust before it opens the picker"] = function()
  -- Neovim's trust question is a modal. On top of a picker it is a question
  -- about a list nobody can see any more, and the explanation Chroma prints
  -- would arrive after the thing it explains.
  tasks.run()

  local consulted, selected
  for index, step in ipairs(calls) do
    if step == "consult" then
      consulted = index
    elseif step == "select" then
      selected = index
    end
  end

  eq(consulted ~= nil and selected ~= nil, true)
  eq(consulted < selected, true)
end

T["order"]["resolves the directory and the executable only after a task is chosen"] = function()
  -- One task naming a command this machine does not have must not hide every
  -- other task in the document.
  tasks.run()

  local selected, resolved, prepared
  for index, step in ipairs(calls) do
    if step == "select" then
      selected = index
    elseif step == "resolve" then
      resolved = index
    elseif step == "prepare" then
      prepared = index
    end
  end

  eq(selected < resolved, true)
  eq(selected < prepared, true)
end

-- ---------------------------------------------------------------------------
-- Where the bytes come from

T["bytes"] = new_set()

T["bytes"]["parses what the trust adapter authorised, not the file"] = function()
  -- Hashed, trusted and parsed are one byte string. A second reading is a
  -- window in which the file changes, and then what runs was never trusted.
  trust.consult = function()
    return { state = "trusted", path = "/repo/.chroma/tasks.json", bytes = DOCUMENT }
  end

  local parsed
  schema.read = function(bytes)
    parsed = bytes
    return saved.read(bytes)
  end

  tasks.run()

  eq(parsed, DOCUMENT)
end

-- ---------------------------------------------------------------------------
-- One prepared execution

T["one execution"] = new_set()

T["one execution"]["is shown and then run, without being prepared again"] = function()
  local prepared = 0
  command.prepare = function()
    prepared = prepared + 1
    return { argv = { "/usr/bin/true", tostring(prepared) }, env = {} }, nil
  end

  local shown, started
  preview.render = function(_, _, execution)
    shown = execution
    return { "Task" }
  end
  run.start = function(_, _, execution)
    started = execution
  end

  tasks.run()

  eq(prepared, 1)
  eq(shown, started)
end

T["one execution"]["runs what the preview showed even if the machine changes"] = function()
  -- Between the question and the answer a PATH can change. What runs is what
  -- was agreed to.
  local shown
  preview.render = function(_, _, execution)
    shown = execution
    return { "Task" }
  end
  preview.confirm = function()
    command.prepare = function()
      return { argv = { "/somewhere/else/true" }, env = {} }, nil
    end
    return true
  end

  local started
  run.start = function(_, _, execution)
    started = execution
  end

  tasks.run()

  eq(started, shown)
  eq(started.argv, { "/usr/bin/true" })
end

-- ---------------------------------------------------------------------------
-- Choosing

T["the picker"] = new_set()

T["the picker"]["hands the task itself to the callback, not its label"] = function()
  -- Two tasks may share a name: the schema requires unique ids and says
  -- nothing about names. Looking one up by what the picker displayed finds the
  -- first of them, which is a different task from the one somebody chose.
  trust.consult = function()
    return {
      state = "trusted",
      path = "/repo/.chroma/tasks.json",
      bytes = [[{
        "schema": 1,
        "tasks": [
          { "id": "beta", "name": "Deploy", "group": "ansible",
            "cwd": { "mode": "project" }, "argv": ["beta"] },
          { "id": "prod", "name": "Deploy", "group": "ansible",
            "cwd": { "mode": "project" }, "argv": ["prod"] }
        ]
      }]],
    }
  end

  local labels = {}
  tasks.select = function(items, opts, on_choice)
    for _, item in ipairs(items) do
      table.insert(labels, opts.format_item(item))
    end
    on_choice(items[2], 2)
  end

  local chosen
  cwd.resolve = function(_, task)
    chosen = task
    return "/repo", nil
  end

  tasks.run()

  eq(labels, { "ansible / Deploy", "ansible / Deploy" })
  eq(chosen.id, "prod")
end

T["the picker"]["opens even when the document declares one task"] = function()
  -- No shortcut. `<leader>xr` pressed by accident must not land on the
  -- confirmation of something that runs.
  tasks.run()

  eq(vim.tbl_contains(calls, "select"), true)
end

-- ---------------------------------------------------------------------------
-- Every way it stops
--
-- These are the states nothing owned before this file existed. The rule is the
-- same for all of them: nothing runs, and the reason is said out loud.

T["stopping"] = new_set()

T["stopping"]["below 0.12.3 nothing is even looked for"] = function()
  availability.version = function()
    return vim.version.parse("0.12.2")
  end

  tasks.run()

  eq(calls, {})
  eq(mentioned("0.12.3"), true)
  eq(mentioned("799cbfff8"), true)
end

T["stopping"]["there is no project"] = function()
  source.find = function()
    record("find")
    return nil, nil
  end

  tasks.run()

  eq(calls, { "find" })
  eq(mentioned("No project tasks"), true)
end

T["stopping"]["the source was refused"] = function()
  source.find = function()
    record("find")
    return nil, "/repo/sub/.chroma/tasks.json is a directory, not a file"
  end

  tasks.run()

  eq(calls, { "find" })
  eq(mentioned("is a directory, not a file"), true)
end

T["stopping"]["the file is untrusted, and the flow is not resumed"] = function()
  -- The adapter has already explained itself and put Neovim's question up.
  -- There is nothing to wait for: the next step is `:trust` and another
  -- explicit Run Task.
  trust.consult = function(_, explain)
    record("consult")
    explain("/repo/.chroma/tasks.json")
    return { state = "untrusted", path = "/repo/.chroma/tasks.json" }
  end

  tasks.run()

  eq(calls, { "find", "consult" })
  eq(mentioned("exrc"), true)
  eq(mentioned("run this again"), true)
end

T["stopping"]["the file is denied"] = function()
  trust.consult = function()
    record("consult")
    return { state = "denied", path = "/repo/.chroma/tasks.json" }
  end

  tasks.run()

  eq(calls, { "find", "consult" })
  eq(mentioned("denied"), true)
  eq(mentioned(":trust ++remove"), true)
end

T["stopping"]["the trust database could not be understood"] = function()
  trust.consult = function()
    record("consult")
    return { state = "unknown", path = "/repo/.chroma/tasks.json", problem = "the trust database could not be read" }
  end

  tasks.run()

  eq(calls, { "find", "consult" })
  eq(mentioned("trust database"), true)
end

T["stopping"]["the source changed after discovery"] = function()
  trust.consult = function()
    record("consult")
    return { state = "refused", path = "/repo/.chroma/tasks.json", problem = "it is no longer there" }
  end

  tasks.run()

  eq(calls, { "find", "consult" })
  eq(mentioned("no longer there"), true)
end

T["stopping"]["the document is malformed, and the refusal names the file"] = function()
  trust.consult = function()
    record("consult")
    return { state = "trusted", path = "/repo/.chroma/tasks.json", bytes = "{oops" }
  end

  tasks.run()

  eq(calls, { "find", "consult", "read" })
  eq(mentioned("/repo/.chroma/tasks.json"), true)
  eq(mentioned("not valid JSON"), true)
end

T["stopping"]["the document declares no tasks"] = function()
  trust.consult = function()
    record("consult")
    return { state = "trusted", path = "/repo/.chroma/tasks.json", bytes = [[{"schema": 1, "tasks": []}]] }
  end

  tasks.run()

  eq(calls, { "find", "consult", "read" })
  eq(mentioned("declares no tasks"), true)
end

T["stopping"]["the picker was closed"] = function()
  tasks.select = function(_, _, on_choice)
    record("select")
    on_choice(nil)
  end

  tasks.run()

  eq(calls, { "find", "consult", "read", "select" })
  eq(said, {})
end

T["stopping"]["the working directory was refused"] = function()
  cwd.resolve = function()
    record("resolve")
    return nil, "the working directory /etc escapes the project root /repo"
  end

  tasks.run()

  eq(calls, { "find", "consult", "read", "select", "resolve" })
  eq(mentioned("escapes the project root"), true)
end

T["stopping"]["the executable was not found"] = function()
  command.prepare = function()
    record("prepare")
    return nil, "company-cli was not found on the PATH this task runs with"
  end

  tasks.run()

  eq(calls, { "find", "consult", "read", "select", "resolve", "prepare" })
  eq(mentioned("was not found on the PATH"), true)
end

T["stopping"]["the confirmation was anything but yes"] = function()
  preview.confirm = function()
    record("confirm")
    return false
  end

  tasks.run()

  eq(vim.tbl_contains(calls, "start"), false)
end

T["stopping"]["a yes runs the task exactly once"] = function()
  local started = 0
  run.start = function()
    started = started + 1
  end

  tasks.run()

  eq(started, 1)
end

-- ---------------------------------------------------------------------------
-- The boundary with Managed Terraform

T["isolation"] = new_set()

T["isolation"]["nothing under tasks/ reaches Managed Terraform"] = function()
  -- Declared in concept.md §10 and enforced here, now that tasks/ is a whole
  -- subsystem. A custom task running `terraform plan` produces nothing Managed
  -- Apply may accept, and the way to keep that true is for these two never to
  -- know about each other.
  local here = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h:h")
  local directory = vim.fs.joinpath(here, "lua", "chroma", "tasks")

  for name, kind in vim.fs.dir(directory) do
    if kind == "file" and name:match("%.lua$") then
      local text = table.concat(vim.fn.readfile(vim.fs.joinpath(directory, name)), "\n")
      if text:find('require("chroma%-terraform') then
        error(("lua/chroma/tasks/%s depends on Managed Terraform"):format(name))
      end
    end
  end
end

return T
