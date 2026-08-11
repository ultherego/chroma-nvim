-- Finding a project's task file.
--
-- Every case here is one of the ways the search can quietly answer for the
-- wrong project: looking only where the editor stands, stepping over an entry
-- it cannot use, following a symlink into somewhere that is not a file, or
-- remembering an answer from before the filesystem changed under it.

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local source = require("chroma.tasks.source")

local DOCUMENT = [[{ "schema": 1, "tasks": [] }]]

---A throwaway directory tree. Returns its root.
---@return string
local function tree()
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, "p")
  return root
end

---Writes a task file for `root`, creating `.chroma/` on the way.
---@param root string
---@return string path
local function tasks_in(root)
  vim.fn.mkdir(vim.fs.joinpath(root, ".chroma"), "p")
  local path = vim.fs.joinpath(root, ".chroma", "tasks.json")
  vim.fn.writefile({ DOCUMENT }, path)
  return path
end

---The `.chroma` directory of `root`, created.
---@param root string
---@return string
local function chroma_in(root)
  local dir = vim.fs.joinpath(root, ".chroma")
  vim.fn.mkdir(dir, "p")
  return dir
end

local T = new_set()

-- ---------------------------------------------------------------------------
-- Where it looks

T["searching"] = new_set()

T["searching"]["finds a task file in the directory it starts from"] = function()
  local root = tree()
  local path = tasks_in(root)

  local found, problem = source.find(root)

  eq(problem, nil)
  eq(found.root, root)
  eq(found.path, path)
  eq(found.resolved, vim.uv.fs_realpath(path))
end

T["searching"]["climbs to an ancestor"] = function()
  -- The case a search that only looked at the starting directory would fail:
  -- somebody is editing deep inside a repository whose tasks live at its top.
  local root = tree()
  tasks_in(root)
  local deep = vim.fs.joinpath(root, "terraform", "environments", "prod")
  vim.fn.mkdir(deep, "p")

  local found, problem = source.find(deep)

  eq(problem, nil)
  eq(found.root, root)
end

T["searching"]["answers with nothing when no ancestor has one"] = function()
  -- Not a problem: a repository that has never heard of Chroma is a repository
  -- with no project tasks, and the search has to terminate at the filesystem
  -- root rather than climb forever.
  local found, problem = source.find(tree())

  eq(found, nil)
  eq(problem, nil)
end

-- ---------------------------------------------------------------------------
-- Where it stops

T["stopping"] = new_set()

T["stopping"]["refuses a directory of that name instead of using the parent's"] = function()
  local root = tree()
  tasks_in(root)

  local child = vim.fs.joinpath(root, "sub")
  vim.fn.mkdir(vim.fs.joinpath(child, ".chroma", "tasks.json"), "p")

  local found, problem = source.find(child)

  eq(found, nil)
  if not problem:find("is a directory", 1, true) then
    error(("refusal %q does not say it is a directory"):format(problem))
  end
  -- And it must be about the child, not the perfectly good file above it.
  eq(problem:find(child, 1, true) ~= nil, true)
end

T["stopping"]["refuses a broken symlink instead of using the parent's"] = function()
  -- The trap behind asking `stat` whether an entry exists: a broken symlink
  -- has no target, so target-stat says "nothing here" and the search walks up
  -- into another project's tasks. `lstat` sees the link itself.
  local root = tree()
  tasks_in(root)

  local child = vim.fs.joinpath(root, "sub")
  local link = vim.fs.joinpath(chroma_in(child), "tasks.json")
  eq(vim.uv.fs_symlink(vim.fs.joinpath(child, "nowhere.json"), link), true)

  local found, problem = source.find(child)

  eq(found, nil)
  eq(problem:find(child, 1, true) ~= nil, true)
end

T["stopping"]["refuses a symlink that leads to a directory"] = function()
  local root = tree()
  local elsewhere = vim.fs.joinpath(root, "elsewhere")
  vim.fn.mkdir(elsewhere, "p")

  local link = vim.fs.joinpath(chroma_in(root), "tasks.json")
  eq(vim.uv.fs_symlink(elsewhere, link), true)

  local found, problem = source.find(root)

  eq(found, nil)
  if not problem:find("is a directory", 1, true) then
    error(("refusal %q does not say what it leads to"):format(problem))
  end
end

T["stopping"]["refuses something that is not a file at all"] = function()
  local root = tree()
  local path = vim.fs.joinpath(chroma_in(root), "tasks.json")
  vim.fn.system({ "mkfifo", path })
  if vim.v.shell_error ~= 0 then
    MiniTest.skip("mkfifo is not available here")
  end

  local found, problem = source.find(root)

  eq(found, nil)
  if not problem:find("is a fifo", 1, true) then
    error(("refusal %q does not name what the entry is"):format(problem))
  end
end

T["stopping"]["accepts a symlink that leads to a regular file"] = function()
  -- The other side of following links: this one is legal, and what comes back
  -- is the target, because that is the file whose bytes will be trusted.
  local root = tree()
  local real = vim.fs.joinpath(root, "shared-tasks.json")
  vim.fn.writefile({ DOCUMENT }, real)

  local link = vim.fs.joinpath(chroma_in(root), "tasks.json")
  eq(vim.uv.fs_symlink(real, link), true)

  local found, problem = source.find(root)

  eq(problem, nil)
  eq(found.resolved, vim.uv.fs_realpath(real))
  eq(found.root, root)
end

T["stopping"]["refuses when it could not look, rather than calling it absent"] = function()
  -- The permission version of the broken symlink: an unreadable `.chroma/`
  -- answers EACCES, not ENOENT, and reading every failure as "nothing here"
  -- walks up into the parent's tasks. Injected rather than produced with
  -- chmod, so the case says the same thing when the suite runs as root.
  local root = tree()
  tasks_in(root)

  local child = vim.fs.joinpath(root, "sub")
  local candidate = vim.fs.joinpath(child, ".chroma", "tasks.json")
  vim.fn.mkdir(child, "p")

  local real = vim.uv.fs_lstat
  vim.uv.fs_lstat = function(path)
    if path == candidate then
      return nil, ("EACCES: permission denied: %s"):format(path), "EACCES"
    end
    return real(path)
  end
  local ok, found, problem = pcall(source.find, child)
  vim.uv.fs_lstat = real

  eq(ok, true)
  eq(found, nil)
  if not problem:find("cannot be inspected", 1, true) then
    error(("refusal %q does not say the entry could not be inspected"):format(problem))
  end
  eq(problem:find("EACCES", 1, true) ~= nil, true)
end

T["stopping"]["refuses a file it cannot read"] = function()
  if vim.uv.getuid() == 0 then
    -- Root reads everything, so the case would pass for the wrong reason.
    MiniTest.skip("running as root")
  end

  local root = tree()
  local path = tasks_in(root)
  eq(vim.uv.fs_chmod(path, 0), true)

  local found, problem = source.find(root)

  eq(found, nil)
  if not problem:find("cannot be read", 1, true) then
    error(("refusal %q does not say it cannot be read"):format(problem))
  end
end

-- ---------------------------------------------------------------------------
-- What it remembers

T["remembering"] = new_set()

T["remembering"]["sees a file that was written since the last call"] = function()
  -- Stronger than asking twice about two directories: the same question, the
  -- same place, a different filesystem. A cached answer cannot survive it.
  local root = tree()

  local before = source.find(root)
  eq(before, nil)

  tasks_in(root)
  local after, problem = source.find(root)

  eq(problem, nil)
  eq(after.root, root)
end

T["remembering"]["sees a file that has been deleted since the last call"] = function()
  local root = tree()
  local path = tasks_in(root)

  eq(source.find(root).root, root)

  vim.fn.delete(path)
  local after, problem = source.find(root)

  eq(after, nil)
  eq(problem, nil)
end

return T
