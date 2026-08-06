-- Where the vault password comes from.
--
-- Ansible resolves its own configuration from ANSIBLE_CONFIG, ./ansible.cfg,
-- ~/.ansible.cfg and /etc/ansible/ansible.cfg, with rules that change between
-- releases. Reimplementing that lookup here would be a guess with a long shelf
-- life, so this module asks ansible instead:
--
--   ansible-config dump
--
-- prints the resolved values and, in parentheses, which file each came from.
-- Verified against ansible core 2.21: a project-local ansible.cfg is picked up
-- and the password path comes back absolute.

local M = {}

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

  local result = vim.system({ "ansible-config", "dump" }, { cwd = cwd, text = true }):wait()

  if result.code ~= 0 then
    -- ansible-config fails loudly on a malformed ansible.cfg, which is worth
    -- surfacing rather than silently falling back to "no password file".
    return nil, (result.stderr or ""):gsub("%s+$", "")
  end

  return vim.split(result.stdout or "", "\n", { trimempty = true })
end

---Turns `ansible-config dump` output into the fields this plugin needs.
---
---Separated from the process call so it can be tested without ansible: the
---shape of these lines is the contract with an external tool, and a change in
---it should fail a test rather than silently produce "no password configured".
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
      -- Which identity to encrypt with when several are available. Ansible
      -- refuses to guess: "The vault-ids dev,prod are available to encrypt.
      -- Specify the vault-id to encrypt with --encrypt-vault-id".
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
