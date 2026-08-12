-- Where this plugin may put a plan file, which quotes the values a run resolved.
--
-- $XDG_RUNTIME_DIR is validated, not trusted: it is an environment variable,
-- and anything able to set it can redirect these writes somewhere readable.
--
-- Duplicated in chroma-vault.nvim on purpose — see `doc/DECISIONS.md`,
-- "The runtime-directory check is duplicated on purpose".

local M = {}

local OWNER_ONLY = tonumber("700", 8)
--- Everything below the file type: the nine permission bits and the three special
--- ones. Masking to 0777 instead would call 01700 a 0700 directory — the same
--- answer for a directory the specification does not describe.
local MODE_BITS = tonumber("10000", 8)

---Owner and permissions of a directory about to hold something private.
---@param path string
---@param label string how to name it in an error
---@return boolean ok, string|nil err
local function directory_is_private(path, label)
  -- Follows symlinks deliberately: the question is what the path ends at.
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

  -- mode carries the file type too, so only the mode bits are compared.
  local permissions = stat.mode % MODE_BITS
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
    return nil, "XDG_RUNTIME_DIR is not set, so there is no private runtime directory to use."
  end

  -- isabsolutepath answers 1 for `~/x`, which nothing here expands.
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
    -- Another Neovim may have created it in between; the check below decides.
    if not made and not vim.uv.fs_stat(path) then
      return nil, ("could not create %s: %s"):format(path, mkdir_err or "unknown error")
    end
    -- mkdir applies the umask, which can strip bits from 0700.
    pcall(vim.uv.fs_chmod, path, OWNER_ONLY)
  end

  local sub_ok, sub_err = directory_is_private(path, "the runtime directory")
  if not sub_ok then
    return nil, sub_err
  end

  return path
end

return M
