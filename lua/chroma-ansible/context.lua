-- Where Ansible will run, and which file it will be handed. This stats,
-- resolves and refuses: it starts no process, opens no picker and reads the
-- contents of nothing. The rules are `doc/chroma-ansible-design.md` §3–5.
--
-- **The working directory is part of what a command means.** Ansible reads
-- `ansible.cfg` from the current directory and does not search upward (§3.1,
-- measured), and that file can decide roles, collections, the default
-- inventory, vault settings and become defaults. So it is chosen rather than
-- taken from the editor, and then frozen: `:cd` and anything like it may move
-- Neovim afterwards and none of them may move the run.
--
-- **A playbook is a readable regular file ending in `.yml` or `.yaml`**, and
-- that is the whole test (§4.2). Whether it looks like a playbook is Ansible's
-- judgement.

local M = {}

--- The file whose presence is reported beside a candidate directory.
local CONFIG = "ansible.cfg"

--- What a playbook's name may end in. Only ever used to decide whether to
--- *offer* the current buffer, never to refuse a path the operator typed.
local SUFFIXES = { ".yml", ".yaml" }

---A path as the filesystem knows it, or nil.
---@param path string
---@return string|nil
local function canonical(path)
  return vim.uv.fs_realpath(path)
end

---Whether a resolved path is a readable regular file. `fs_stat` follows
---symlinks deliberately — a symlink to a playbook is a playbook — and the read
---check is asked of the filesystem, because the answer depends on who is
---running.
---@param resolved string
---@return boolean
local function readable_file(resolved)
  local entry = vim.uv.fs_stat(resolved)
  return entry ~= nil and entry.type == "file" and vim.uv.fs_access(resolved, "R") == true
end

---Whether a resolved path is a directory this user may enter and read.
---@param resolved string
---@return boolean
local function usable_directory(resolved)
  local entry = vim.uv.fs_stat(resolved)
  if not entry or entry.type ~= "directory" then
    return false
  end
  -- Ansible needs both: `X` is the right to traverse a directory, `R` the
  -- right to list it, and one without the other fails deep inside Ansible.
  return vim.uv.fs_access(resolved, "R") == true and vim.uv.fs_access(resolved, "X") == true
end

---Whether a name ends in one of the playbook suffixes.
---@param path string
---@return boolean
local function suffixed(path)
  for _, suffix in ipairs(SUFFIXES) do
    if vim.endswith(path:lower(), suffix) then
      return true
    end
  end
  return false
end

---Whether a buffer's file is worth offering as the playbook. A suggestion only:
---a buffer with no file behind it has nothing to offer, which is not a failure.
---@param name string the buffer's name, as `vim.api.nvim_buf_get_name` gives it
---@return string|nil path the canonical path to offer
function M.suggestion(name)
  if type(name) ~= "string" or name == "" then
    return nil
  end
  -- A buffer name can be a URI for a plugin's virtual buffer, and the suffix
  -- test alone would accept `oil:///tmp/x.yml`. The realpath is what rejects it.
  if not suffixed(name) then
    return nil
  end

  local resolved = canonical(name)
  if not resolved or not readable_file(resolved) then
    return nil
  end

  return resolved
end

---Accepts a playbook path, or says why not. The contents are not read: a broken
---playbook is discovered by Ansible, with Ansible's own error (§4.4).
---@param path string
---@return string|nil resolved, string|nil problem
function M.playbook(path)
  if type(path) ~= "string" or path == "" then
    return nil, "no playbook was given"
  end

  local resolved = canonical(path)
  if not resolved then
    return nil, ("%s does not exist"):format(path)
  end

  local entry = vim.uv.fs_stat(resolved)
  if not entry then
    return nil, ("%s cannot be read"):format(path)
  end
  if entry.type ~= "file" then
    return nil, ("%s is a %s, not a file"):format(path, entry.type)
  end
  if not vim.uv.fs_access(resolved, "R") then
    return nil, ("%s cannot be read"):format(path)
  end

  return resolved, nil
end

---@class chroma_ansible.Candidate
---@field path string canonical
---@field why string what makes it a candidate, for the picker's second column
---@field config boolean whether an ansible.cfg sits in it

---The working directories worth offering, in order and deduplicated: Neovim's,
---the playbook's, then ancestors holding an `ansible.cfg`. Deduplicated by
---canonical path, keeping the first reason a directory appeared.
---
---`config` is a `stat`, not a claim that Ansible would find that file — it
---would not, unless this is the directory that gets chosen (§3.1).
---@param playbook string a canonical playbook path
---@param editor string|nil Neovim's working directory
---@return chroma_ansible.Candidate[]
function M.candidates(playbook, editor)
  local out, seen = {}, {}

  ---@param path string|nil
  ---@param why string
  local function offer(path, why)
    if not path then
      return
    end
    local resolved = canonical(path)
    if not resolved or seen[resolved] or not usable_directory(resolved) then
      return
    end
    seen[resolved] = true
    table.insert(out, {
      path = resolved,
      why = why,
      config = vim.uv.fs_stat(vim.fs.joinpath(resolved, CONFIG)) ~= nil,
    })
  end

  offer(editor, "Neovim's directory")

  local directory = vim.fs.dirname(playbook)
  offer(directory, "playbook directory")

  -- Nearest first, and offered as candidates: Ansible would not find any of
  -- them by itself.
  local parent = vim.fs.dirname(directory)
  while parent and parent ~= directory do
    if vim.uv.fs_stat(vim.fs.joinpath(parent, CONFIG)) then
      offer(parent, "ancestor with ansible.cfg")
    end
    directory, parent = parent, vim.fs.dirname(parent)
  end

  return out
end

---Freezes a chosen working directory. Resolved once, here; nothing in the
---planner calls `getcwd()` again (§3.4).
---@param path string
---@return string|nil frozen canonical, string|nil problem
function M.freeze(path)
  if type(path) ~= "string" or path == "" then
    return nil, "no working directory was given"
  end

  local resolved = canonical(path)
  if not resolved then
    return nil, ("the working directory %s does not exist"):format(path)
  end
  if not usable_directory(resolved) then
    return nil, ("the working directory %s is not a directory you can read"):format(path)
  end

  return resolved, nil
end

---A path as the process will resolve it: relative paths belong to the frozen
---working directory, because that is where the process starts.
---@param directory string
---@param path string
---@return string
function M.under(directory, path)
  if vim.startswith(path, "/") then
    return path
  end
  return vim.fs.joinpath(directory, path)
end

---Accepts an inventory source, or says why not. A file or a directory (§5.2) —
---a `hosts.yml`, a directory of them, an executable script or a plugin
---configuration are all one of those two things on disk.
---
---**Resolved here, and stored resolved.** A typed path is relative to whatever
---the operator was looking at; `-i` is relative to the frozen working
---directory, and the two differ when the playbook lives one level down. The
---problem below names the path the subprocess would have opened, so a
---misanchored prefix can be read off the message.
---@param directory string the frozen working directory
---@param path string as typed
---@return string|nil resolved canonical, string|nil problem
function M.inventory(directory, path)
  if type(path) ~= "string" or path == "" then
    return nil, "no inventory source was given"
  end

  local target = M.under(directory, path)
  local resolved = canonical(target)
  if not resolved then
    return nil, ("the inventory source %s does not exist"):format(target)
  end

  local entry = vim.uv.fs_stat(resolved)
  if entry and entry.type == "directory" then
    if not usable_directory(resolved) then
      return nil, ("the inventory source %s is not a directory you can read"):format(target)
    end
    return resolved, nil
  end

  if not readable_file(resolved) then
    -- Named by what it is: a socket or a device answering `-i` fails inside
    -- Ansible with a message about parsing rather than about the file.
    local kind = entry and entry.type or "unreadable"
    if kind == "file" then
      return nil, ("the inventory source %s cannot be read"):format(target)
    end
    return nil, ("the inventory source %s is a %s, not a file or a directory"):format(target, kind)
  end

  return resolved, nil
end

---Whether what was chosen can still be run, or why not. Asked when a repeat is
---recalled (§14.4) and again just before the terminal opens (§16), because an
---hour can pass between two repeats.
---
---The sources are checked alongside the playbooks: a `-i` that has gone is not
---an error to Ansible. It warns, resolves an inventory of nothing, reports
---`skipping: no hosts matched` and exits 0.
---@param directory string the frozen working directory
---@param playbooks string[] as stored, relative or absolute
---@param inventory string[]|nil the sources, as stored
---@return string|nil problem
function M.runnable(directory, playbooks, inventory)
  local gone = M.still_usable(directory)
  if gone then
    return gone
  end

  for _, playbook in ipairs(playbooks) do
    local _, unreadable = M.playbook(M.under(directory, playbook))
    if unreadable then
      return unreadable
    end
  end

  for _, source in ipairs(inventory or {}) do
    local _, missing = M.inventory(directory, source)
    if missing then
      return missing
    end
  end

  return nil
end

---Whether a frozen directory is still one, just before a process starts. Asked
---again rather than trusted: it can be removed, replaced by a file or have its
---permissions changed between the choice and the confirmation (§16).
---@param frozen string
---@return string|nil problem
function M.still_usable(frozen)
  if type(frozen) ~= "string" or frozen == "" then
    return "the working directory is not set"
  end

  local resolved = canonical(frozen)
  if not resolved or not usable_directory(resolved) then
    return ("the working directory %s is no longer usable"):format(frozen)
  end
  -- Compared, not just re-resolved: a path that now leads somewhere else is
  -- not the directory that was frozen.
  if resolved ~= frozen then
    return ("the working directory %s now resolves to %s"):format(frozen, resolved)
  end

  return nil
end

return M
