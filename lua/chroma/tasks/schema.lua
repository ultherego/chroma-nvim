-- Schema 1: what a `.chroma/tasks.json` may say, and what it may not.
--
-- This is the first half of reading project tasks, and deliberately the half
-- that touches nothing: it is handed the bytes of a document and answers with
-- the tasks it declares, or with one problem naming where the document is
-- wrong. It does not read files, resolve paths, ask about trust or run
-- anything — see cli/../concept.md §3 for the contract these rules implement.
--
-- Strict, in the same way and for the same reason as `chroma.components`: a
-- `cmd` written for `argv` decodes cleanly and would leave a task that runs
-- nothing, and a file that decides what a machine executes is the worst place
-- to be quietly generous. Every rule here is a refusal, and every refusal names
-- the task and the field.
--
-- The bytes come from the caller rather than being read here. That is not
-- fastidiousness either: the trust adapter authorises one exact byte string,
-- and hashing one representation of a file while parsing another would answer a
-- different question from the one Neovim's trust database answered.

local M = {}

--- The only schema this configuration understands.
M.VERSION = 1

--- The fields each level may carry. Anything else is a mistake worth reporting
--- rather than ignoring.
local KNOWN = {
  document = { schema = true, tasks = true },
  task = { id = true, name = true, group = true, cwd = true, argv = true, env = true },
  cwd = { mode = true, path = true },
}

--- The working directory modes Milestone 1 has. `file`, `nearest` and `prompt`
--- are deferred, and a document naming one of them is refused rather than
--- half-honoured.
local MODES = { project = true, relative = true }

---Whether a decoded value is a non-empty string.
---
---`vim.NIL` is what a JSON `null` decodes to, so a field written as null is
---present and not a string, which is the answer we want: absent is absent, and
---present has a value.
---@param value any
---@return boolean
local function text(value)
  return type(value) == "string" and value ~= ""
end

---Whether a decoded value is a JSON array.
---
---An empty array and an empty object both decode to `{}`, so an empty one
---passes as either. That is the single ambiguity Lua's decoder leaves and it
---costs nothing here: an empty `tasks` means no tasks whichever it was written
---as, and an empty `argv` is refused by the rule below regardless.
---@param value any
---@return boolean
local function array(value)
  return type(value) == "table" and not (next(value) ~= nil and #value == 0)
end

---The first field name at this level that does not belong.
---@param decoded table
---@param known table<string, boolean>
---@return string|nil
local function unknown_field(decoded, known)
  for key in pairs(decoded) do
    if not known[key] then
      return key
    end
  end
  return nil
end

---What is wrong with a task's `cwd`, if anything.
---@param cwd any
---@return string|nil problem
local function cwd_problem(cwd)
  if type(cwd) ~= "table" or array(cwd) and next(cwd) == nil then
    return "cwd is not an object"
  end

  local unknown = unknown_field(cwd, KNOWN.cwd)
  if unknown then
    return ("cwd has an unknown field %q"):format(unknown)
  end

  if not text(cwd.mode) then
    return "cwd has no mode"
  end
  if not MODES[cwd.mode] then
    return ("cwd.mode %q is not supported"):format(cwd.mode)
  end

  if cwd.mode == "project" then
    -- Refused rather than ignored: a path written beside `project` means
    -- somebody expected it to be used, and the difference between "ignored"
    -- and "used" is which directory an apply runs in.
    if cwd.path ~= nil then
      return "cwd.path is not allowed when mode is project"
    end
    return nil
  end

  if not text(cwd.path) then
    return "cwd.path is required when mode is relative"
  end
  -- Always relative to the project root. An absolute path is refused here
  -- rather than left to the containment check, so the message names the
  -- mistake in the document instead of its consequence.
  if vim.startswith(cwd.path, "/") then
    return "cwd.path must not be absolute"
  end

  return nil
end

---What is wrong with a task's `argv`, if anything.
---@param argv any
---@return string|nil problem
local function argv_problem(argv)
  if not array(argv) then
    return "argv is not an array"
  end
  if #argv == 0 then
    return "argv is empty"
  end

  for index, word in ipairs(argv) do
    -- Numbers and booleans are refused rather than coerced. A task that means
    -- `8080` writes "8080"; a document that leaves it to the reader produces a
    -- different command in a different JSON library.
    if type(word) ~= "string" then
      return ("argv[%d] is %s, which is not a string"):format(index, vim.inspect(word))
    end
  end

  if argv[1] == "" then
    return "argv[1] is empty, so there is nothing to run"
  end

  return nil
end

---What is wrong with a task's `env`, if anything.
---@param env any
---@return string|nil problem
local function env_problem(env)
  if env == nil then
    return nil
  end
  if type(env) ~= "table" or array(env) and next(env) ~= nil then
    return "env is not an object"
  end

  for key, value in pairs(env) do
    if not text(key) then
      return "env has an empty name"
    end
    if not text(value) then
      return ("env.%s is %s, which is not a non-empty string"):format(key, vim.inspect(value))
    end
  end

  return nil
end

---What is wrong with one task, if anything.
---@param task any
---@return string|nil problem
local function task_problem(task)
  if type(task) ~= "table" then
    return ("is %s, which is not an object"):format(vim.inspect(task))
  end

  local unknown = unknown_field(task, KNOWN.task)
  if unknown then
    return ("has an unknown field %q"):format(unknown)
  end

  if not text(task.id) then
    return "has no id"
  end
  if not text(task.name) then
    return "has no name"
  end
  if task.group ~= nil and not text(task.group) then
    return "has an empty group"
  end

  return cwd_problem(task.cwd) or argv_problem(task.argv) or env_problem(task.env)
end

---How a task is named in a problem, before it is known to have a usable id.
---@param task any
---@param index integer
---@return string
local function called(task, index)
  if type(task) == "table" and text(task.id) then
    return ("task %q"):format(task.id)
  end
  return ("task #%d"):format(index)
end

---Reads one task document.
---
---The problem, when there is one, is a sentence fragment the caller prefixes
---with the path it came from, so the whole reads:
---
---    .chroma/tasks.json: task "ansible-run": cwd.mode "foo" is not supported
---
---@param bytes string the exact bytes of the document
---@return table|nil tasks, string|nil problem
function M.read(bytes)
  if type(bytes) ~= "string" then
    return nil, "is not a document"
  end

  local ok, decoded = pcall(vim.json.decode, bytes)
  if not ok or type(decoded) ~= "table" then
    return nil, "is not valid JSON"
  end

  local unknown = unknown_field(decoded, KNOWN.document)
  if unknown then
    return nil, ("has an unknown field %q"):format(unknown)
  end

  -- An unsupported schema is a different answer from a malformed document, and
  -- says so: one is a file from a newer Chroma, the other is a mistake.
  if decoded.schema == nil then
    return nil, "has no schema"
  end
  if decoded.schema ~= M.VERSION then
    return nil, ("declares schema %s; this configuration understands %d"):format(vim.inspect(decoded.schema), M.VERSION)
  end

  if not array(decoded.tasks) then
    return nil, "has no tasks array"
  end

  local seen = {}
  for index, task in ipairs(decoded.tasks) do
    local problem = task_problem(task)
    if problem then
      return nil, ("%s: %s"):format(called(task, index), problem)
    end

    -- Neither last nor first wins. Both are a silent choice between two things
    -- somebody wrote on purpose, and one of them would never run.
    if seen[task.id] then
      return nil, ("task %q is declared twice"):format(task.id)
    end
    seen[task.id] = true
  end

  return decoded.tasks, nil
end

return M
