-- Where the vault password comes from: `ansible-config dump`, rather than a
-- reimplementation of ansible's own configuration lookup.

local M = {}

--- Bound on the configuration lookup, matching the one in cli.lua: this call
--- blocks the editor and ansible's configuration can name programs to run.
local TIMEOUT_MS = 10000

---@class ansible_vault.Resolved
---@field password_file string|nil     absolute path, from ansible's own config
---@field identities string[]          vault ids from vault_identity_list
---@field encrypt_identity string|nil  which id to encrypt with, when several exist
---@field source string|nil            which config file supplied the password file

---Runs ansible-config in `cwd` so that a project-local ansible.cfg applies.
---@param cwd string
---@return string[]|nil lines, string|nil err
local function dump(cwd)
  if vim.fn.executable("ansible-config") ~= 1 then
    return nil, "ansible-config not found — is ansible installed and on PATH?"
  end

  -- Raises rather than returns when `cwd` has been removed or is not a
  -- directory, which is an error like any other.
  local ran, result = pcall(function()
    -- Bounded: it resolves configuration that can name programs, and this call
    -- blocks the editor.
    return vim.system({ "ansible-config", "dump" }, { cwd = cwd, text = true }):wait(TIMEOUT_MS)
  end)

  if not ran then
    return nil, ("could not run ansible-config in %s: %s"):format(cwd, result)
  end

  if not result or result.code == 124 then
    return nil, ("ansible-config did not answer within %d seconds and was stopped"):format(TIMEOUT_MS / 1000)
  end

  if result.code ~= 0 then
    -- A malformed ansible.cfg is worth surfacing, not reading as "no password file".
    return nil, (result.stderr or ""):gsub("%s+$", "")
  end

  return vim.split(result.stdout or "", "\n", { trimempty = true })
end

---Turns `ansible-config dump` output into the fields this plugin needs.
---Separate from the process call so the parsing can be tested without ansible.
---@param lines string[]
---@return ansible_vault.Resolved
function M.parse_dump(lines)
  local resolved = { identities = {} }

  for _, line in ipairs(lines) do
    -- Lines look like:
    --   DEFAULT_VAULT_PASSWORD_FILE(/path/to/ansible.cfg) = /path/to/pass
    --   DEFAULT_VAULT_IDENTITY_LIST(default) = []
    local key, source, value = line:match("^(%u[%u_]+)%(([^)]*)%)%s*=%s*(.*)$")
    if key == "DEFAULT_VAULT_PASSWORD_FILE" and value ~= "None" then
      resolved.password_file = vim.fs.normalize(value)
      resolved.source = source
    elseif key == "DEFAULT_VAULT_ENCRYPT_IDENTITY" and value ~= "None" then
      -- Which id to encrypt with; ansible refuses to guess between several.
      resolved.encrypt_identity = value
    elseif key == "DEFAULT_VAULT_IDENTITY_LIST" and value ~= "[]" then
      -- Rendered as a Python list literal: ['dev@~/.dev_pass', 'prod@prompt']
      for id in value:gmatch("'([^']+)'") do
        table.insert(resolved.identities, id)
      end
    end
  end

  return resolved
end

---@param cwd string? defaults to the current working directory
---@return ansible_vault.Resolved|nil, string|nil err
function M.resolve(cwd)
  cwd = cwd or vim.fn.getcwd()

  local lines, err = dump(cwd)
  if not lines then
    return nil, err
  end

  return M.parse_dump(lines)
end

---Human-readable description of what will be used, for messages and health.
---@param resolved ansible_vault.Resolved
---@return string
function M.describe(resolved)
  if #resolved.identities > 0 then
    return ("vault ids: %s"):format(table.concat(resolved.identities, ", "))
  end
  if resolved.password_file then
    return ("password file: %s (from %s)"):format(resolved.password_file, resolved.source or "?")
  end
  return "no vault password configured — you will be prompted"
end

return M
