-- Where Ansible will run, and which file it will be handed.
--
-- Two questions with one property in common: both are answered from the
-- filesystem and from the operator, never from a guess about what a file
-- contains. This module stats, resolves and refuses. It starts no process,
-- opens no picker and reads the contents of nothing. The rules are
-- `doc/chroma-ansible-design.md`, sections 3 and 4.
--
-- **The working directory is part of what a command means.** Ansible reads
-- `ansible.cfg` from the current directory and **does not search upward**
-- (§3.1, measured), and that file can decide `roles_path`, `collections_path`,
-- the default inventory, vault settings, callback plugins and become defaults.
-- So the directory is offered as a choice rather than taken from the editor,
-- and once chosen it is frozen: `:cd`, `:lcd`, `:tcd`, a session plugin or a
-- file manager may move Neovim afterwards and none of them may move the run.
--
-- **A playbook is a readable regular file whose name ends in `.yml` or
-- `.yaml`.** That is the whole test (§4.2). Nothing here opens one to decide
-- whether it "looks like a playbook": that is Ansible's judgement, and being
-- wrong in either direction is worse than asking.

local M = {}

--- The file whose presence is reported beside a candidate directory.
local CONFIG = "ansible.cfg"

--- What a playbook's name may end in. Ansible itself is not fussy, so this is
--- only ever used to decide whether to *offer* the current buffer — never to
--- refuse a path the operator typed.
local SUFFIXES = { ".yml", ".yaml" }

---A path as the filesystem knows it, or nil.
---@param path string
---@return string|nil
local function canonical(path)
  return vim.uv.fs_realpath(path)
end

---Whether a resolved path is a readable regular file.
---
---Two questions, not one. `fs_stat` follows symlinks, which is deliberate — a
---symlink to a playbook is a playbook — and the read check is asked of the
---filesystem rather than inferred from the mode bits, because the answer
---depends on who is running.
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
  -- `X` on a directory is the right to traverse it, `R` the right to list it.
  -- Ansible needs both, and a directory answering yes to only one produces a
  -- failure from the subprocess that reads nothing like "you cannot use this".
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

---Whether a buffer's file is worth offering as the playbook.
---
---A suggestion, and only that. A buffer with no file behind it — a dashboard, a
---terminal, oil, an unnamed buffer — simply has nothing to offer, which is not
---a failure and is not reported as one.
---@param name string the buffer's name, as `vim.api.nvim_buf_get_name` gives it
---@return string|nil path the canonical path to offer
function M.suggestion(name)
  if type(name) ~= "string" or name == "" then
    return nil
  end
  -- A buffer name can be a URI for a plugin's virtual buffer. Those resolve to
  -- nothing, so the realpath below is what rejects them; the suffix test alone
  -- would happily accept `oil:///tmp/x.yml`.
  if not suffixed(name) then
    return nil
  end

  local resolved = canonical(name)
  if not resolved or not readable_file(resolved) then
    return nil
  end

  return resolved
end

---Accepts a playbook path, or says why not.
---
---The contents are not read, not parsed and not validated. A playbook that is
---broken is discovered by Ansible, with Ansible's own error (§4.4).
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

---The working directories worth offering, in order and deduplicated.
---
---Order is Neovim's directory, the playbook's directory, then ancestors of the
---playbook holding an `ansible.cfg`. Deduplicated by canonical path, keeping
---the first reason a directory appeared: a directory that is both Neovim's and
---the playbook's is offered once, described as Neovim's.
---
---`config` is a `stat` and nothing more — a fact about the filesystem, not a
---claim that Ansible would find that file. It would not, unless this is the
---directory that gets chosen (§3.1).
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

  -- Ancestors carrying a config, nearest first. Offered because that is very
  -- often the directory somebody means, and offered as a *candidate* because
  -- Ansible would not find any of them by itself.
  local parent = vim.fs.dirname(directory)
  while parent and parent ~= directory do
    if vim.uv.fs_stat(vim.fs.joinpath(parent, CONFIG)) then
      offer(parent, "ancestor with ansible.cfg")
    end
    directory, parent = parent, vim.fs.dirname(parent)
  end

  return out
end

---Freezes a chosen working directory.
---
---Resolved once, here, and every later step reads what this returned. Nothing
---in the planner calls `getcwd()` again (§3.4).
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

---A path as the process will resolve it.
---
---Relative paths belong to the frozen working directory, because that is where
---the process starts. Resolving one against Neovim's directory would answer for
---a file nobody is about to run — and would pass or fail for the wrong reason.
---@param directory string
---@param path string
---@return string
function M.under(directory, path)
  if vim.startswith(path, "/") then
    return path
  end
  return vim.fs.joinpath(directory, path)
end

---Whether what was chosen can still be run, or why not.
---
---Asked twice on purpose: once when a repeat is recalled (§14.4) and once
---immediately before the terminal opens (§16). Minutes can pass while somebody
---reads a preview, and an hour can pass between two repeats.
---@param directory string the frozen working directory
---@param playbooks string[] as stored, relative or absolute
---@return string|nil problem
function M.runnable(directory, playbooks)
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

  return nil
end

---Whether a frozen directory is still one, just before a process starts.
---
---Asked again rather than trusted: freezing happened when the operator chose,
---and a directory can be removed, replaced by a file or have its permissions
---changed between then and the confirmation (§16).
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
  -- Compared, not just re-resolved: if the path now leads somewhere else, this
  -- is not the directory that was frozen, and running there would be running
  -- somewhere the operator never agreed to.
  if resolved ~= frozen then
    return ("the working directory %s now resolves to %s"):format(frozen, resolved)
  end

  return nil
end

return M
