-- What is actually executed: the argument vector and the environment.
--
-- The task wrote what it meant; this turns that into something a process can be
-- started from, and changes exactly one element while doing it.
--
--     argv[1..]   untouched, byte for byte
--     argv[0]     resolved to an absolute path
--     env         the task's overrides, over what Neovim inherited
--
-- Resolving `argv[0]` is not Chroma reinterpreting a command. It is the only
-- way the execution rules in `doc/CONTRACT.md` can hold at all. Measured on
-- Neovim 0.12.4:
-- `jobstart` validates the first element *before* it looks at the `env` and
-- `cwd` it was handed, so a bare name is searched in the editor's PATH and a
-- `./script` against the editor's directory — both raise `E475: … is not
-- executable` even when the task's own PATH and working directory contain
-- exactly what was asked for. Passing the absolute path this module found is
-- what makes the process start as the task described rather than as the editor
-- happens to be configured.
--
-- Nothing here starts anything, and nothing here reads a shell.

local M = {}

---The environment a task's process would see.
---
---The overrides as declared, and nothing else: the merge with what Neovim
---inherited belongs to the process layer, where it is what `jobstart` already
---does with `env`. What this module needs from it is the effective PATH.
---@param task table
---@return table<string, string> overrides
local function overrides(task)
  local env = {}
  for name, value in pairs(task.env or {}) do
    env[name] = value
  end
  return env
end

---Whether a path is a file this user may execute.
---
---Both halves matter. A directory answers yes to an execute check — that is
---what makes it traversable — so `X` alone would accept `bin/` as the command.
---@param path string
---@return boolean
local function runnable(path)
  local entry = vim.uv.fs_stat(path)
  return entry ~= nil and entry.type == "file" and vim.uv.fs_access(path, "X") == true
end

---Where a bare name is looked for.
---
---An empty entry means the current directory, which for the child process is
---the task's working directory — the same answer `execvp` gives after the
---`chdir`, and the same one a relative entry gets.
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

---The absolute path `argv[0]` names, or why there is none.
---
---Not passed through `realpath`. A tool reached by a symlink is meant to be
---started by the name it was reached with — plenty of them read `argv[0]` and
---behave differently — and the contract asks for the path resolution produced,
---not for the file's canonical identity.
---@param name string
---@param directory string the task's working directory
---@param path string|nil the task's effective PATH
---@return string|nil executable, string|nil problem
local function locate(name, directory, path)
  if name:find("/", 1, true) then
    local candidate = name
    if not vim.startswith(candidate, "/") then
      -- Against the task's directory, not the editor's. This is the case
      -- `./scripts/deploy` exists for.
      --
      -- The leading `./` is dropped, and only that: `./x` and `x` name the same
      -- file whatever the directory is made of, so removing it costs nothing
      -- and keeps the path out of the preview looking like `/repo/./scripts`.
      -- Nothing else is normalised — `a/../b` is not `b` when `a` is a symlink,
      -- and tidying a path is not this module's business.
      candidate = vim.fs.joinpath(directory, (candidate:gsub("^%./", "")))
    end

    if not runnable(candidate) then
      return nil, ("%s is not an executable file"):format(name)
    end
    return candidate, nil
  end

  for _, place in ipairs(search(path, directory)) do
    local candidate = vim.fs.joinpath(place, name)
    -- Kept looking. A name that exists here without being executable is not
    -- the answer, and stopping at it would hide the one further along the PATH
    -- that is — which is exactly what a shell would have found.
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

  -- The PATH the child would have, which is the task's override when it has
  -- one and the editor's otherwise. Asking `vim.fn.executable` instead would
  -- answer for the editor and ignore the override entirely.
  local executable, problem = locate(task.argv[1], directory, env.PATH or vim.env.PATH)
  if problem then
    return nil, problem
  end

  local argv = { executable }
  for index = 2, #task.argv do
    -- Copied, not rewritten. `../inventories/dev/hosts.yml` is the program's
    -- to interpret against its own working directory.
    table.insert(argv, task.argv[index])
  end

  return { argv = argv, env = env }, nil
end

return M
