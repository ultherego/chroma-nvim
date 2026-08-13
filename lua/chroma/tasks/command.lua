-- The argument vector and the environment. Exactly one element changes:
-- `argv[0]` becomes an absolute path, `argv[1..]` are untouched byte for byte.
--
-- Measured on 0.12.4: `jobstart` validates the first element before it looks at
-- the `env` and `cwd` it was handed, so a bare name is searched in the editor's
-- PATH and `./script` against the editor's directory — both raise `E475` even
-- when the task's own PATH and directory hold exactly what was asked for.
--
-- Nothing here starts anything, and nothing here reads a shell.

local M = {}

---The overrides as declared, and nothing else: merging with what Neovim
---inherited is what `jobstart` already does with `env`.
---@param task table
---@return table<string, string> overrides
local function overrides(task)
  local env = {}
  for name, value in pairs(task.env or {}) do
    env[name] = value
  end
  return env
end

---Whether a path is a file this user may execute. Both halves matter: a
---directory answers yes to an execute check, so `X` alone accepts `bin/`.
---@param path string
---@return boolean
local function runnable(path)
  local entry = vim.uv.fs_stat(path)
  return entry ~= nil and entry.type == "file" and vim.uv.fs_access(path, "X") == true
end

---Where a bare name is looked for. An empty entry means the current directory,
---which for the child is the task's — the answer `execvp` gives after `chdir`.
---@param path string the effective PATH
---@param directory string the task's working directory
---@return string[]
local function search(path, directory)
  local places = {}
  for _, entry in ipairs(vim.split(path or "", ":", { plain = true })) do
    if entry == "" then
      table.insert(places, directory)
    elseif vim.startswith(entry, "/") then
      table.insert(places, entry)
    else
      table.insert(places, vim.fs.joinpath(directory, entry))
    end
  end
  return places
end

---The absolute path `argv[0]` names, or why there is none. Not passed through
---`realpath`: a tool reached by a symlink is meant to start under the name it
---was reached with, and plenty read `argv[0]` and behave differently.
---@param name string
---@param directory string the task's working directory
---@param path string|nil the task's effective PATH
---@return string|nil executable, string|nil problem
local function locate(name, directory, path)
  if name:find("/", 1, true) then
    local candidate = name
    if not vim.startswith(candidate, "/") then
      -- Against the task's directory, not the editor's. The leading `./` is
      -- dropped and nothing else is normalised: `a/../b` is not `b` when `a`
      -- is a symlink.
      candidate = vim.fs.joinpath(directory, (candidate:gsub("^%./", "")))
    end

    if not runnable(candidate) then
      return nil, ("%s is not an executable file"):format(name)
    end
    return candidate, nil
  end

  for _, place in ipairs(search(path, directory)) do
    local candidate = vim.fs.joinpath(place, name)
    -- Kept looking: stopping at a non-executable of the same name would hide
    -- the one further along the PATH that a shell would have found.
    if runnable(candidate) then
      return candidate, nil
    end
  end

  return nil, ("%s was not found on the PATH this task runs with"):format(name)
end

---Prepares one task for execution.
---
---@param task table one task, already valid by chroma.tasks.schema
---@param directory string the working directory, already resolved by chroma.tasks.cwd
---@return table|nil prepared { argv = string[], env = table<string, string> }
---@return string|nil problem
function M.prepare(task, directory)
  local env = overrides(task)

  -- The PATH the child would have. `vim.fn.executable` would answer for the
  -- editor and ignore the override entirely.
  local executable, problem = locate(task.argv[1], directory, env.PATH or vim.env.PATH)
  if problem then
    return nil, problem
  end

  local argv = { executable }
  for index = 2, #task.argv do
    -- Copied, not rewritten: a relative path is the program's to interpret.
    table.insert(argv, task.argv[index])
  end

  return { argv = argv, env = env }, nil
end

return M
