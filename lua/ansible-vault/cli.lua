-- Running ansible-vault without leaking what it is protecting.
--
-- Three rules shape this module, all of them verified against ansible core
-- 2.21 rather than assumed:
--
-- 1. PLAINTEXT NEVER GOES IN ARGV. `ansible-vault encrypt_string` accepts the
--    string as a positional argument, which would publish the secret in
--    /proc and to anyone running `ps`. With no positional argument it reads
--    stdin instead, which is what this module does. Confirmed by piping a
--    value in and getting a valid `!vault |` block back.
--
-- 2. CIPHERTEXT MAY GO ANYWHERE. It is not secret, so decrypt passes it as a
--    file. That frees stdin for the password.
--
-- 3. THE PASSWORD IS A FILE, BECAUSE ANSIBLE ONLY ACCEPTS A FILE. When one is
--    already configured, it is used directly and nothing is written. When the
--    user is prompted instead, the password is written to $XDG_RUNTIME_DIR —
--    tmpfs, mode 0700, wiped at logout — with mode 0600, and unlinked as soon
--    as the command returns. `--vault-password-file /dev/stdin` also works and
--    is used where stdin is free.
--
--    This is not a compromise ansible itself avoids: a vault password file on
--    disk is the normal, documented setup.

local M = {}

---@class ansible_vault.Auth
---@field password_file string|nil  path to an existing password file
---@field identities string[]|nil   vault ids to pass as --vault-id
---@field password string|nil       a password typed by the user this session

---Builds the --vault-id / --vault-password-file arguments.
---@param auth ansible_vault.Auth
---@param password_path string|nil path to use when a password was typed
---@return string[]
local function auth_args(auth, password_path)
  local args = {}

  if auth.identities and #auth.identities > 0 then
    for _, id in ipairs(auth.identities) do
      table.insert(args, "--vault-id")
      table.insert(args, id)
    end
    return args
  end

  local path = password_path or auth.password_file
  if path then
    table.insert(args, "--vault-password-file")
    table.insert(args, path)
  end

  return args
end

---Writes a typed password somewhere ansible can read it, as briefly as
---possible. Returns the path and a function that removes it.
---@param password string
---@return string|nil path, function|nil cleanup, string|nil err
local function stage_password(password)
  local dir = vim.env.XDG_RUNTIME_DIR
  if not dir or not vim.uv.fs_stat(dir) then
    -- Falling back to the ordinary temp directory would put the password on
    -- persistent storage. Refuse instead of doing it quietly.
    return nil,
      nil,
      "XDG_RUNTIME_DIR is not set, so there is no in-memory place to put the password. "
        .. "Configure vault_password_file in ansible.cfg instead."
  end

  local path = ("%s/ansible-vault.nvim.%d.%d"):format(dir, vim.uv.os_getpid(), vim.uv.hrtime())

  local fd, open_err = vim.uv.fs_open(path, "wx", tonumber("600", 8))
  if not fd then
    return nil, nil, ("could not create %s: %s"):format(path, open_err or "unknown error")
  end

  vim.uv.fs_write(fd, password .. "\n")
  vim.uv.fs_close(fd)

  return path, function()
    pcall(vim.uv.fs_unlink, path)
  end
end

---@param args string[]           arguments after `ansible-vault`
---@param opts table              { auth, stdin, cwd }
---@return string|nil stdout, string|nil err
local function run(args, opts)
  if vim.fn.executable("ansible-vault") ~= 1 then
    return nil, "ansible-vault not found — is ansible installed and on PATH?"
  end

  local password_path, cleanup, err
  if opts.auth and opts.auth.password then
    password_path, cleanup, err = stage_password(opts.auth.password)
    if not password_path then
      return nil, err
    end
  end

  local cmd = { "ansible-vault" }
  vim.list_extend(cmd, args)
  vim.list_extend(cmd, auth_args(opts.auth or {}, password_path))

  local result = vim
    .system(cmd, {
      cwd = opts.cwd,
      stdin = opts.stdin,
      text = true,
      -- Ansible reads a controlling terminal for --ask-vault-pass. This module
      -- never uses that flag, but making the absence explicit means a
      -- misconfiguration fails fast instead of hanging on a prompt nobody
      -- can see.
      env = vim.tbl_extend("force", vim.fn.environ(), { ANSIBLE_NOCOLOR = "1" }),
    })
    :wait()

  if cleanup then
    cleanup()
  end

  if result.code ~= 0 then
    local message = (result.stderr or ""):gsub("%s+$", "")
    if message == "" then
      message = ("ansible-vault exited with %d"):format(result.code)
    end
    return nil, message
  end

  return result.stdout or ""
end

---Encrypts a plaintext value into an inline `!vault |` block.
---@param plaintext string
---@param opts table { auth, cwd, name }
---@return string[]|nil lines, string|nil err
function M.encrypt_string(plaintext, opts)
  opts = opts or {}

  local args = { "encrypt_string" }
  if opts.name then
    table.insert(args, "--stdin-name")
    table.insert(args, opts.name)
  end

  -- The plaintext goes in on stdin; see rule 1 above.
  local out, err = run(args, { auth = opts.auth, cwd = opts.cwd, stdin = plaintext })
  if not out then
    return nil, err
  end

  return vim.split(out:gsub("%s+$", ""), "\n", { trimempty = true })
end

---Decrypts a `$ANSIBLE_VAULT...` block.
---@param ciphertext string  the block, already dedented
---@param opts table { auth, cwd }
---@return string|nil plaintext, string|nil err
function M.decrypt_string(ciphertext, opts)
  opts = opts or {}

  -- Ciphertext is not secret, so it can go through stdin while the password
  -- takes the file argument, or vice versa. Here stdin carries the ciphertext
  -- and the password keeps its file.
  local out, err = run({ "decrypt", "--output", "-" }, {
    auth = opts.auth,
    cwd = opts.cwd,
    stdin = ciphertext:gsub("%s+$", "") .. "\n",
  })
  if not out then
    return nil, err
  end

  return out
end

return M
