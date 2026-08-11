-- Tests for schema 1 of `.chroma/tasks.json`.
--
-- One case per rule in the contract, because the value of this layer is
-- entirely in what it refuses: a validator that accepts a document it should
-- not is a task runner that executes something nobody wrote down.

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local schema = require("chroma.tasks.schema")

---A valid document with one task, as a table, so a case can break one field.
---@param task table|nil replaces the task entirely
---@return string
local function document(task)
  return vim.json.encode({
    schema = 1,
    tasks = {
      task or {
        id = "plan",
        name = "Plan production",
        group = "terraform",
        cwd = { mode = "relative", path = "terraform/prod" },
        argv = { "terraform", "plan" },
      },
    },
  })
end

---The problem a document produces, or "" when it was accepted.
---@param bytes string
---@return string
local function refusal(bytes)
  local tasks, problem = schema.read(bytes)
  if problem then
    return problem
  end
  eq(type(tasks), "table")
  return ""
end

---Asserts that a document is refused, and that the refusal says `expected`.
---@param bytes string
---@param expected string
local function refuses(bytes, expected)
  local problem = refusal(bytes)
  if not problem:find(expected, 1, true) then
    error(("refusal %q does not mention %q"):format(problem, expected))
  end
end

local T = new_set()

-- ---------------------------------------------------------------------------
-- What a good document produces

T["a valid document"] = new_set()

T["a valid document"]["returns its tasks"] = function()
  local tasks, problem = schema.read(document())

  eq(problem, nil)
  eq(#tasks, 1)
  eq(tasks[1].id, "plan")
  eq(tasks[1].argv, { "terraform", "plan" })
  eq(tasks[1].cwd, { mode = "relative", path = "terraform/prod" })
end

T["a valid document"]["accepts a document that declares no tasks"] = function()
  local tasks, problem = schema.read([[{"schema": 1, "tasks": []}]])

  eq(problem, nil)
  eq(#tasks, 0)
end

T["a valid document"]["accepts project mode with no path, and env"] = function()
  local tasks, problem = schema.read(document({
    id = "deploy",
    name = "Deploy",
    cwd = { mode = "project" },
    argv = { "make", "deploy" },
    env = { AWS_PROFILE = "production" },
  }))

  eq(problem, nil)
  eq(tasks[1].env, { AWS_PROFILE = "production" })
end

-- ---------------------------------------------------------------------------
-- The document

T["the document"] = new_set()

T["the document"]["refuses what is not JSON"] = function()
  refuses("{oops", "not valid JSON")
end

T["the document"]["refuses a document with no schema"] = function()
  refuses([[{"tasks": []}]], "no schema")
end

T["the document"]["refuses a schema it does not understand"] = function()
  refuses([[{"schema": 2, "tasks": []}]], "declares schema 2")
end

T["the document"]["says an unsupported schema is not a malformed one"] = function()
  -- The two are different answers: one is a file from a newer Chroma, the
  -- other is a mistake, and telling somebody to fix their JSON when their
  -- Chroma is simply older sends them looking for a typo that is not there.
  local problem = refusal([[{"schema": 2, "tasks": []}]])
  if problem:find("valid JSON", 1, true) then
    error(("an unsupported schema was reported as malformed: %q"):format(problem))
  end
end

T["the document"]["refuses an unknown top-level field"] = function()
  refuses([[{"schema": 1, "tasks": [], "extra": 1}]], [[unknown field "extra"]])
end

T["the document"]["refuses a missing tasks array"] = function()
  refuses([[{"schema": 1}]], "no tasks array")
end

-- ---------------------------------------------------------------------------
-- A task

T["a task"] = new_set()

T["a task"]["refuses an unknown field"] = function()
  refuses(
    document({ id = "x", name = "X", cwd = { mode = "project" }, argv = { "ls" }, cmd = "ls" }),
    [[unknown field "cmd"]]
  )
end

T["a task"]["refuses no id, and names its position"] = function()
  refuses(document({ name = "X", cwd = { mode = "project" }, argv = { "ls" } }), "task #1: has no id")
end

T["a task"]["refuses an empty id"] = function()
  refuses(document({ id = "", name = "X", cwd = { mode = "project" }, argv = { "ls" } }), "has no id")
end

T["a task"]["refuses no name"] = function()
  refuses(document({ id = "x", cwd = { mode = "project" }, argv = { "ls" } }), [[task "x": has no name]])
end

T["a task"]["refuses an empty group"] = function()
  refuses(document({ id = "x", name = "X", group = "", cwd = { mode = "project" }, argv = { "ls" } }), "empty group")
end

T["a task"]["refuses the same id twice"] = function()
  local one = { id = "x", name = "One", cwd = { mode = "project" }, argv = { "ls" } }
  local two = { id = "x", name = "Two", cwd = { mode = "project" }, argv = { "pwd" } }

  refuses(vim.json.encode({ schema = 1, tasks = { one, two } }), [[task "x" is declared twice]])
end

T["a task"]["refuses a null field rather than reading it as absent"] = function()
  -- A JSON null decodes to vim.NIL, so the field is present and is not a
  -- string. Reading it as "absent" would turn `"name": null` into a task with
  -- no name at all.
  refuses(
    [[{"schema": 1, "tasks": [{"id": "x", "name": null, "cwd": {"mode": "project"}, "argv": ["ls"]}]}]],
    "has no name"
  )
end

-- ---------------------------------------------------------------------------
-- cwd

T["cwd"] = new_set()

T["cwd"]["refuses a mode Milestone 1 does not have"] = function()
  refuses(
    document({ id = "x", name = "X", cwd = { mode = "nearest", markers = { "terragrunt.hcl" } }, argv = { "ls" } }),
    "unknown field"
  )
end

T["cwd"]["refuses an unsupported mode by name"] = function()
  refuses(
    document({ id = "x", name = "X", cwd = { mode = "file" }, argv = { "ls" } }),
    [[cwd.mode "file" is not supported]]
  )
end

T["cwd"]["refuses a path beside project mode"] = function()
  refuses(
    document({ id = "x", name = "X", cwd = { mode = "project", path = "plays" }, argv = { "ls" } }),
    "not allowed when mode is project"
  )
end

T["cwd"]["refuses relative mode with no path"] = function()
  refuses(document({ id = "x", name = "X", cwd = { mode = "relative" }, argv = { "ls" } }), "path is required")
end

T["cwd"]["refuses an absolute path"] = function()
  refuses(
    document({ id = "x", name = "X", cwd = { mode = "relative", path = "/etc" }, argv = { "ls" } }),
    "must not be absolute"
  )
end

T["cwd"]["refuses no cwd at all"] = function()
  refuses(document({ id = "x", name = "X", argv = { "ls" } }), "cwd is not an object")
end

-- ---------------------------------------------------------------------------
-- argv

T["argv"] = new_set()

T["argv"]["refuses an empty argv"] = function()
  refuses(document({ id = "x", name = "X", cwd = { mode = "project" }, argv = {} }), "argv is empty")
end

T["argv"]["refuses a number rather than coercing it"] = function()
  refuses(
    [[{"schema": 1, "tasks": [{"id": "x", "name": "X", "cwd": {"mode": "project"}, "argv": ["nc", "-l", 8080]}]}]],
    "argv[3] is 8080"
  )
end

T["argv"]["refuses an empty executable"] = function()
  refuses(document({ id = "x", name = "X", cwd = { mode = "project" }, argv = { "", "plan" } }), "nothing to run")
end

-- ---------------------------------------------------------------------------
-- env

T["env"] = new_set()

T["env"]["refuses a value that is not a string"] = function()
  refuses(
    [[{"schema": 1, "tasks": [{"id": "x", "name": "X", "cwd": {"mode": "project"}, "argv": ["ls"], "env": {"PORT": 8080}}]}]],
    "env.PORT"
  )
end

T["env"]["refuses a null value"] = function()
  refuses(
    [[{"schema": 1, "tasks": [{"id": "x", "name": "X", "cwd": {"mode": "project"}, "argv": ["ls"], "env": {"PORT": null}}]}]],
    "env.PORT"
  )
end

return T
