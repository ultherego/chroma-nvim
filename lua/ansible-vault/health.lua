-- `:checkhealth ansible-vault`
--
-- Answers the two questions that make this plugin useless when the answer is
-- wrong: can it run ansible, and does it know a password for the project you
-- are sitting in.

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

  if vim.env.XDG_RUNTIME_DIR and vim.uv.fs_stat(vim.env.XDG_RUNTIME_DIR) then
    health.ok(("Prompted passwords will be staged in %s (tmpfs)"):format(vim.env.XDG_RUNTIME_DIR))
  else
    health.warn(
      "XDG_RUNTIME_DIR is not set",
      "prompting for a password will be refused rather than writing it to persistent "
        .. "storage. Configure vault_password_file in ansible.cfg instead."
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
