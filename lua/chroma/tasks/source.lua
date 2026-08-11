-- Where a project's task definitions are, if it has any.
--
-- This module answers one question — which file, and which directory is the
-- project root — and deliberately stops there. It does not read the file, hash
-- it, ask Neovim whether it is trusted or parse anything: the trust adapter
-- takes exactly one byte snapshot of what this points at, and a module that
-- had already read the file would make that snapshot the second reading of it.
--
-- Three answers, and the caller must be able to tell them apart:
--
--     found      a source, and no problem
--     missing    neither; this project has no tasks, which is not an error
--     refused    no source, and a problem naming the path and the reason
--
-- The rules are the frozen ones from concept.md §3: search upward from where
-- the editor is, stop at the first entry with that name whatever it turns out
-- to be, and require a readable regular file.

local M = {}

--- The directory a project declares its tasks in, and the file inside it.
local DIRECTORY = ".chroma"
local FILE = "tasks.json"

---@class chroma.tasks.Source
---@field root string the project root: the directory holding .chroma/
---@field path string the entry as it was found
---@field resolved string the same file with every symlink resolved

---What is wrong with a candidate entry, if anything.
---
---Two questions, not one, and in this order. `lstat` asks whether an entry
---exists *here* without following it anywhere; `realpath` then says what it
---leads to. Asking only about the target would make a broken symlink
---indistinguishable from nothing at all — and discovery would step over it and
---run the tasks of the repository above, which is the silent fallback the
---contract forbids.
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

  -- Readable, and asked of the filesystem rather than assumed from the mode
  -- bits: the answer depends on who is running, and a task file nobody can
  -- read is refused by name rather than a decode error two layers later.
  if not vim.uv.fs_access(resolved, "R") then
    return nil, ("%s cannot be read"):format(path)
  end

  return resolved, nil
end

---Finds the project whose tasks apply here.
---
---`from` is a seam for tests. The answer in a running editor is Neovim's
---effective working directory, which is what the contract says discovery starts
---from — `getcwd()` rather than the process directory, so a window-local `:lcd`
---is respected. Nothing else about a task is ever taken from it.
---@param from string|nil directory to start at; defaults to the editor's
---@return chroma.tasks.Source|nil source, string|nil problem
function M.find(from)
  local directory = from or vim.fn.getcwd()

  -- Nothing is remembered between calls, and that is the contract rather than
  -- an oversight: a file trusted since the last look, a file just written, a
  -- file just deleted and a different project all have to be seen by the next
  -- explicit Run Task. `chroma.components` caches for the opposite reason —
  -- it reads an immutable release tree; this reads a file somebody is editing.
  while directory do
    local path = vim.fs.joinpath(directory, DIRECTORY, FILE)

    local entry, failure, code = vim.uv.fs_lstat(path)

    if entry then
      -- Found something with that name. Whatever it is, the search ends here:
      -- stepping over an unusable entry would hand this project's Run Task to
      -- whichever repository happens to be above it.
      local resolved, problem = acceptable(path)
      if problem then
        return nil, problem
      end
      return { root = directory, path = path, resolved = resolved }, nil
    end

    -- "There is nothing here" and "I was not allowed to look" are two answers,
    -- and only the first may continue upward. Measured: luv fails with the code
    -- as its third value, so an unreadable `.chroma/` answers EACCES while a
    -- missing one answers ENOENT — and reading both as absence turns a
    -- permission problem into somebody else's tasks running. ENOTDIR is
    -- absence too: it means a path component is not a directory, so no entry
    -- of that name exists here either.
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
