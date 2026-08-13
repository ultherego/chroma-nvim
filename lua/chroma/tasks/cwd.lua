-- Which directory a task runs in. One invariant over both schema-1 modes, from
-- `doc/CONTRACT.md`, "The execution layer":
--
--     realpath(resolved cwd) MUST equal realpath(project root),
--     or be a descendant of it, compared by path components
--
-- Both sides are resolved first, so neither a `..` nor a symlink puts a command
-- outside the project that declared it. Neovim's current directory is never
-- consulted: `:cd` and any plugin can move it between reading a plan and
-- agreeing to it.

local M = {}

---Whether `path` is the directory `root` or something inside it.
---
---By path components: the appended separator is what does that, since
---`/project-evil` passes a textual prefix test against `/project`.
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
  -- Resolved and stat'ed again: discovery looked a moment ago, and a root that
  -- has since become a file would be compared against as though it were not.
  local root, problem = directory(source.root, "the project root")
  if problem then
    return nil, problem
  end

  local candidate
  if task.cwd.mode == "project" then
    -- Nothing else is read: `path` beside `project` is the schema's to refuse.
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
