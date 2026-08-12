-- Which directory a task runs in.
--
-- Two modes in schema 1 and one invariant over both of them, from
-- `doc/CONTRACT.md`, "The execution layer":
--
--     realpath(resolved cwd) MUST equal realpath(project root),
--     or be a descendant of it, compared by path components
--
-- Both sides are resolved before they are compared, so neither a `..` in the
-- task nor a symlink in the repository can put a command somewhere outside the
-- project that declared it. A textual prefix does not implement this: `/project`
-- is a prefix of `/project-evil`, and the difference between those two is the
-- difference between a plan and somebody else's infrastructure.
--
-- Neovim's current directory is not consulted here at all. Discovery used it
-- once, to know where to start looking; from then on a task's directory comes
-- from the project it was declared in, because `:cd`, `:lcd`, `:tcd` and any
-- plugin can move the editor's idea of where it is between reading a plan and
-- agreeing to it.

local M = {}

---Whether `path` is the directory `root` or something inside it.
---
---Compared by path components. The separator appended to the root is what does
---that: without it `/project-evil` passes a prefix test against `/project`.
---@param path string canonical
---@param root string canonical
---@return boolean
local function inside(path, root)
  if path == root then
    return true
  end

  local prefix = root
  if prefix:sub(-1) ~= "/" then
    prefix = prefix .. "/"
  end
  return path:sub(1, #prefix) == prefix
end

---A directory as the filesystem knows it, or the reason it is not one.
---@param path string
---@param what string how to name it in a refusal
---@return string|nil resolved, string|nil problem
local function directory(path, what)
  local resolved = vim.uv.fs_realpath(path)
  if not resolved then
    return nil, ("%s %s does not exist"):format(what, path)
  end

  local entry = vim.uv.fs_stat(resolved)
  if not entry or entry.type ~= "directory" then
    return nil, ("%s %s is not a directory"):format(what, path)
  end

  return resolved, nil
end

---Where a task runs.
---
---@param source chroma.tasks.Source the project its definitions came from
---@param task table one task, already valid by chroma.tasks.schema
---@return string|nil cwd canonical, and inside the project
---@return string|nil problem
function M.resolve(source, task)
  -- The project root is resolved too, and it is not enough for it to resolve:
  -- discovery looked a moment ago, and a root that has since become a regular
  -- file would otherwise be compared against as though it were a directory.
  local root, problem = directory(source.root, "the project root")
  if problem then
    return nil, problem
  end

  local candidate
  if task.cwd.mode == "project" then
    -- The root itself, and nothing else is read. `path` beside `project` is
    -- refused by the schema; re-deciding that here would be a second reader of
    -- the same document.
    candidate = source.root
  elseif task.cwd.mode == "relative" then
    candidate = vim.fs.joinpath(source.root, task.cwd.path)
  else
    return nil, ("cwd.mode %q cannot be resolved"):format(tostring(task.cwd.mode))
  end

  local resolved
  resolved, problem = directory(candidate, "the working directory")
  if problem then
    return nil, problem
  end

  if not inside(resolved, root) then
    return nil, ("the working directory %s escapes the project root %s"):format(resolved, root)
  end

  return resolved, nil
end

return M
