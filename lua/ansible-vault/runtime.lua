-- Where this plugin is allowed to put a secret.
--
-- ansible-vault.nvim writes exactly one kind of file outside the buffer: a
-- password, staged for the moment it takes a subprocess to read it. There is
-- one place on a Linux machine designed to hold that — the XDG runtime
-- directory, which the specification requires to be owned by the user, to have
-- mode 0700, and not to survive logout.
--
-- Checking that $XDG_RUNTIME_DIR is set is not the same as checking that what
-- it points at still has those properties. It is an environment variable:
-- anything able to set it can redirect these writes into a directory it can
-- read, and the old check — set, and stat succeeds — accepted a world-readable
-- /tmp without a word.
--
-- This file is deliberately part of ansible-vault.nvim rather than shared with
-- the rest of the configuration. See DECISIONS.md, "Each is a plugin, not a
-- file in a shared namespace": the module has to be liftable into its own
-- repository unchanged, and a shared helper is exactly what makes that
-- impossible. terraform.nvim carries its own copy of this policy for the same
-- reason.

local M = {}

local OWNER_ONLY = tonumber("700", 8)
local PERMISSION_BITS = tonumber("1000", 8)

---Owner and permissions of a directory that is about to hold a secret.
---@param path string
---@param label string how to name it in an error
---@return boolean ok, string|nil err
local function directory_is_private(path, label)
  -- fs_stat follows symlinks, which is what is wanted: a link is harmless, the
  -- question is what it ends at.
  local stat = vim.uv.fs_stat(path)
  if not stat then
    return false, ("%s does not exist: %s"):format(label, path)
  end

  if stat.type ~= "directory" then
    return false, ("%s is not a directory: %s"):format(label, path)
  end

  local uid = vim.uv.getuid and vim.uv.getuid()
  if uid and stat.uid ~= uid then
    return false, ("%s is owned by uid %d, not by you (uid %d): %s"):format(label, stat.uid, uid, path)
  end

  -- mode carries the file type as well, so the permission bits are taken
  -- modulo 0o1000 rather than compared whole.
  local permissions = stat.mode % PERMISSION_BITS
  if permissions ~= OWNER_ONLY then
    return false, ("%s has mode %04o, expected 0700: %s"):format(label, permissions, path)
  end

  return true
end

---A validated, private directory for this plugin's short-lived files.
---@param name string subdirectory to use inside the runtime directory
---@return string|nil path, string|nil err
function M.secure_dir(name)
  local root = vim.env.XDG_RUNTIME_DIR
  if not root or root == "" then
    return nil, "XDG_RUNTIME_DIR is not set, so there is no in-memory directory to use."
  end

  -- vim.fs.is_absolute does not exist in Neovim, and vim.fs.abspath converts
  -- rather than tests. vim.fn.isabsolutepath is the predicate — but it answers
  -- 1 for `~/x`, which is not absolute until something expands the tilde, and
  -- nothing here does. Both checked, both verified.
  if vim.fn.isabsolutepath(root) ~= 1 or root:sub(1, 1) == "~" then
    return nil, ("XDG_RUNTIME_DIR is not an absolute path: %s"):format(root)
  end

  local ok, err = directory_is_private(root, "XDG_RUNTIME_DIR")
  if not ok then
    return nil, err
  end

  local path = vim.fs.joinpath(root, name)
  if not vim.uv.fs_stat(path) then
    local made, mkdir_err = vim.uv.fs_mkdir(path, OWNER_ONLY)
    -- Not an error on its own: another Neovim may have created it between the
    -- stat and the mkdir. The check below is what decides.
    if not made and not vim.uv.fs_stat(path) then
      return nil, ("could not create %s: %s"):format(path, mkdir_err or "unknown error")
    end
    -- mkdir applies the umask. It cannot loosen 0700, but it can strip bits
    -- from it, so the mode is set rather than hoped for.
    pcall(vim.uv.fs_chmod, path, OWNER_ONLY)
  end

  local sub_ok, sub_err = directory_is_private(path, "the runtime directory")
  if not sub_ok then
    return nil, sub_err
  end

  return path
end

return M
