-- Which file holds a project's tasks, and which directory is its root. Nothing
-- here reads, hashes or parses it: the trust adapter takes exactly one byte
-- snapshot, and reading first would make that the second reading.
--
-- Three answers the caller must tell apart: a source; nothing, which is not an
-- error; or a problem naming the path. The rules are `doc/CONTRACT.md`, "The
-- execution layer".

local M = {}

--- The directory a project declares its tasks in, and the file inside it.
local DIRECTORY = ".chroma"
local FILE = "tasks.json"

---@class chroma.tasks.Source
---@field root string the project root: the directory holding .chroma/
---@field path string the entry as it was found
---@field resolved string the same file with every symlink resolved

---What is wrong with a candidate entry, if anything. The caller's `lstat` asks
---whether an entry exists here at all; this asks what it leads to. Asking only
---the target would make a broken symlink look like nothing, and discovery would
---step over it into the repository above.
---@param path string
---@return string|nil resolved, string|nil problem
local function acceptable(path)
  local resolved = vim.uv.fs_realpath(path)
  if not resolved then
    return nil, ("%s cannot be resolved; it is a broken symlink or unreadable"):format(path)
  end

  local target = vim.uv.fs_stat(resolved)
  if not target then
    return nil, ("%s cannot be read"):format(path)
  end
  if target.type ~= "file" then
    return nil, ("%s is a %s, not a file"):format(path, target.type)
  end

  -- Asked of the filesystem rather than read off the mode bits: the answer
  -- depends on who is running.
  if not vim.uv.fs_access(resolved, "R") then
    return nil, ("%s cannot be read"):format(path)
  end

  return resolved, nil
end

---Finds the project whose tasks apply here.
---
---`from` is a seam for tests; in a running editor it is `getcwd()`, so a
---window-local `:lcd` is respected. Nothing else about a task comes from it.
---@param from string|nil directory to start at; defaults to the editor's
---@return chroma.tasks.Source|nil source, string|nil problem
function M.find(from)
  local directory = from or vim.fn.getcwd()

  -- Nothing is remembered between calls: this reads a file somebody is
  -- editing, where `chroma.components` reads an immutable release tree.
  while directory do
    local path = vim.fs.joinpath(directory, DIRECTORY, FILE)

    local entry, failure, code = vim.uv.fs_lstat(path)

    if entry then
      -- Whatever it is, the search ends here: stepping over an unusable entry
      -- would hand this project's Run Task to the repository above it.
      local resolved, problem = acceptable(path)
      if problem then
        return nil, problem
      end
      return { root = directory, path = path, resolved = resolved }, nil
    end

    -- "Nothing here" and "not allowed to look" are two answers and only the
    -- first may continue upward: measured, an unreadable `.chroma/` answers
    -- EACCES and a missing one ENOENT. ENOTDIR is absence too.
    if code ~= "ENOENT" and code ~= "ENOTDIR" then
      return nil, ("%s cannot be inspected: %s"):format(path, failure or code or "unknown filesystem error")
    end

    local parent = vim.fs.dirname(directory)
    if parent == directory then
      break
    end
    directory = parent
  end

  return nil, nil
end

return M
