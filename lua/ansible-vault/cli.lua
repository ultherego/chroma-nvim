-- Running ansible-vault without leaking what it is protecting.
--
-- Plaintext goes in on stdin, never in argv, where `ps` would show it.
-- Ciphertext is not secret and may go anywhere. The password has to be a file
-- because ansible accepts nothing else; see :help devops-nvim-vault-pass.

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

  -- Only for identities a caller wants passed explicitly. Ones ansible already
  -- reads from ansible.cfg must not arrive here, or it sees each of them twice.
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

---Removes a file and says whether it is gone. The synchronous libuv calls report
---ordinary failures by returning `nil, err`, so `pcall` around one answers true even
---when the file is still there.
---@param path string
---@return boolean removed, string|nil err
local function unlink_checked(path)
  local ok, err = vim.uv.fs_unlink(path)
  if ok then
    return true
  end

  -- Already gone is what this was for.
  if not vim.uv.fs_stat(path) then
    return true
  end

  return false, err or "unlink failed"
end

---Writes a typed password where ansible can read it, and returns a cleanup function.
---@param password string
---@return string|nil path, function|nil cleanup, string|nil err
local function stage_password(password)
  -- /tmp is neither private nor cleared at logout, so this refuses instead.
  local dir, dir_err = require("ansible-vault.runtime").secure_dir("ansible-vault.nvim")
  if not dir then
    return nil, nil, ("%s\nConfigure vault_password_file in ansible.cfg instead."):format(dir_err)
  end

  local path = ("%s/password.%d.%d"):format(dir, vim.uv.os_getpid(), vim.uv.hrtime())

  local fd, open_err = vim.uv.fs_open(path, "wx", tonumber("600", 8))
  if not fd then
    return nil, nil, ("could not create %s: %s"):format(path, open_err or "unknown error")
  end

  -- A short write, or a deferred error surfacing at close, hands ansible a
  -- truncated password — which it reports as "decryption failed".
  local payload = password .. "\n"

  ---Gives up on a file that may already hold part of the password.
  ---@param reason string
  local function abandon(reason)
    local removed, unlink_err = unlink_checked(path)
    if removed then
      return nil, nil, ("could not stage the password: %s"):format(reason)
    end
    return nil,
      nil,
      ("could not stage the password: %s\nSECURITY: it was left behind and may hold what you typed (%s):\n%s"):format(
        reason,
        unlink_err,
        path
      )
  end

  local function fail(reason)
    vim.uv.fs_close(fd)
    return abandon(reason)
  end

  local written, write_err = vim.uv.fs_write(fd, payload)
  if not written or written < #payload then
    return fail(write_err or "short write")
  end

  -- Free where the runtime directory is memory-backed, and needed where it is not.
  local synced, sync_err = vim.uv.fs_fsync(fd)
  if synced == nil then
    return fail(sync_err or "fsync failed")
  end

  local closed, close_err = vim.uv.fs_close(fd)
  if not closed then
    return abandon(close_err or "close failed")
  end

  return path, function()
    return unlink_checked(path)
  end
end

---@param args string[]           arguments after `ansible-vault`
---@param opts table              { auth, stdin, cwd }
---@return string|nil stdout, string|nil err
local function run(args, opts)
  -- A buffer number reached this as `cwd` once, and surfaced as ansible failing.
  if opts.cwd ~= nil and type(opts.cwd) ~= "string" then
    error(("ansible-vault.cli: cwd must be a string or nil, got %s"):format(type(opts.cwd)), 2)
  end

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

  -- vim.system raises before it starts anything when `cwd` has been removed or is not
  -- a directory. Raising past this point would skip the cleanup below and leave the
  -- password staged for the rest of the session.
  local ran, result = pcall(function()
    return vim
      .system(cmd, {
        cwd = opts.cwd,
        stdin = opts.stdin,
        text = true,
        -- No terminal for a prompt nobody could see, so a misconfiguration fails fast.
        env = vim.tbl_extend("force", vim.fn.environ(), { ANSIBLE_NOCOLOR = "1" }),
      })
      :wait()
  end)

  if cleanup then
    local removed, cleanup_err = cleanup()
    if not removed then
      -- Not folded into the return value: rekey may already have rewritten the file,
      -- and calling a finished operation failed would be the worse lie of the two.
      vim.notify(
        ("SECURITY: the staged Vault password file could not be removed (%s).\nIt holds the password you typed — remove it yourself:\n%s"):format(
          cleanup_err,
          password_path
        ),
        vim.log.levels.ERROR
      )
    end
  end

  if not ran then
    return nil, ("could not run ansible-vault: %s"):format(result)
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
  if opts.encrypt_identity then
    table.insert(args, "--encrypt-vault-id")
    table.insert(args, opts.encrypt_identity)
  end

  -- The plaintext goes in on stdin; see rule 1 above.
  local out, err = run(args, { auth = opts.auth, cwd = opts.cwd, stdin = plaintext })
  if not out then
    return nil, err
  end

  return vim.split(out:gsub("%s+$", ""), "\n", { trimempty = true })
end

---Encrypts a whole document in memory, so transparent editing needs no plaintext file.
---@param plaintext string
---@param opts table { auth, cwd, encrypt_identity }
---@return string|nil ciphertext, string|nil err
function M.encrypt_document(plaintext, opts)
  opts = opts or {}

  local args = { "encrypt", "--output", "-" }
  if opts.encrypt_identity then
    table.insert(args, "--encrypt-vault-id")
    table.insert(args, opts.encrypt_identity)
  end

  return run(args, { auth = opts.auth, cwd = opts.cwd, stdin = plaintext })
end

---Decrypts a whole document, in memory.
---@param ciphertext string
---@param opts table { auth, cwd }
---@return string|nil plaintext, string|nil err
function M.decrypt_document(ciphertext, opts)
  opts = opts or {}
  return run({ "decrypt", "--output", "-" }, { auth = opts.auth, cwd = opts.cwd, stdin = ciphertext })
end

---Re-encrypts a file in place, which is the only form `rekey` has.
---
---Only `--new-vault-id` is offered: `--new-vault-password-file` writes a 1.1
---header, which records no vault id and so cannot be resolved on the next open.
---@param path string
---@param opts table { auth, cwd, new_identity }
---@return boolean ok, string|nil err
function M.rekey(path, opts)
  opts = opts or {}

  local args = { "rekey" }
  if opts.new_identity then
    table.insert(args, "--new-vault-id")
    table.insert(args, opts.new_identity)
  end
  table.insert(args, path)

  local out, err = run(args, { auth = opts.auth, cwd = opts.cwd })
  if not out then
    return false, err
  end
  return true
end

---Decrypts a `$ANSIBLE_VAULT...` block.
---@param ciphertext string  the block, already dedented
---@param opts table { auth, cwd }
---@return string|nil plaintext, string|nil err
function M.decrypt_string(ciphertext, opts)
  opts = opts or {}

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
