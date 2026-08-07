-- `:checkhealth ansible-vault`

local vault_config = require("ansible-vault.config")

local M = {}

function M.check()
  local health = vim.health

  health.start("ansible-vault.nvim")

  if vim.fn.executable("ansible-vault") ~= 1 then
    health.error("`ansible-vault` not found", "install ansible, or put it on PATH")
    return
  end
  health.ok("`ansible-vault` found")

  if vim.fn.executable("ansible-config") ~= 1 then
    health.error(
      "`ansible-config` not found",
      "it ships with ansible and is how this plugin discovers vault settings "
        .. "instead of parsing ansible.cfg itself"
    )
    return
  end
  health.ok("`ansible-config` found")

  health.start("Password for " .. vim.fn.getcwd())

  local resolved, err = vault_config.resolve()
  if not resolved then
    health.error(err)
    return
  end

  if #resolved.identities > 1 and not resolved.encrypt_identity then
    health.warn(
      ("%d vault ids are configured but vault_encrypt_identity is not set"):format(#resolved.identities),
      "ansible refuses to guess which one to encrypt with; you will be asked each time. "
        .. "Set vault_encrypt_identity in ansible.cfg to stop being asked."
    )
  end

  if resolved.password_file then
    if vim.uv.fs_stat(resolved.password_file) then
      health.ok(vault_config.describe(resolved))
    else
      health.error(
        ("vault_password_file points at %s, which does not exist"):format(resolved.password_file),
        ("configured in %s"):format(resolved.source or "?")
      )
    end
  elseif #resolved.identities > 0 then
    health.ok(vault_config.describe(resolved))
  else
    health.info("No vault password configured here — you will be prompted when one is needed")
  end

  health.start("Plaintext handling")

  -- The same call the staging path makes, so this reports what will actually happen.
  local runtime_dir, runtime_err = require("ansible-vault.runtime").secure_dir("ansible-vault.nvim")
  if runtime_dir then
    health.ok(("Prompted passwords will be staged in %s (tmpfs, 0700)"):format(runtime_dir))
  else
    health.warn(
      runtime_err,
      "prompting for a password will be refused rather than staging it somewhere unsafe. "
        .. "Configure vault_password_file in ansible.cfg instead."
    )
  end

  if vim.o.undofile then
    health.info(
      "'undofile' is on globally, which is why decrypted buffers are given "
        .. "'noundofile' individually — otherwise plaintext would persist under "
        .. vim.fn.stdpath("state")
    )
  end
end

return M
