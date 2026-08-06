-- Integration tests for ansible-vault.nvim, against the real CLI.
--
-- These exist because of what the audit found. Every one of the seven defects
-- in these modules was in an integration path — a signature that no longer
-- matched its callers, a write hook that was never attached, an option that did
-- not disable anything, a rename that ate a symlink. The unit tests cover pure
-- functions and would not have caught a single one of them.
--
-- So each case here reproduces one of those failures. If any of them regresses,
-- a test goes red rather than a secret going to disk in the clear.
--
-- Skipped when ansible is not installed, rather than failing: the suite still
-- has to be runnable on a machine that does not have it.

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local PASSWORD = "test-password"

--- A throwaway project with ansible.cfg, a password file, and one encrypted
--- vault. Returns the directory and the path of the vault inside it.
---@param contents string
---@return string dir, string vault
local function project(contents)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")

  vim.fn.writefile({ PASSWORD }, dir .. "/.vault_pass")
  vim.uv.fs_chmod(dir .. "/.vault_pass", tonumber("600", 8))
  vim.fn.writefile({ "[defaults]", "vault_password_file = ./.vault_pass" }, dir .. "/ansible.cfg")

  local vault = dir .. "/secrets.yml"
  vim.fn.writefile(vim.split(contents, "\n"), vault)

  local result = vim.system({ "ansible-vault", "encrypt", vault }, { cwd = dir, text = true }):wait()
  assert(result.code == 0, "could not encrypt the fixture: " .. (result.stderr or ""))

  return dir, vault
end

---Decrypts a file with the CLI, so assertions never depend on the plugin.
---@param dir string
---@param path string
---@return string
local function decrypt_externally(dir, path)
  local result = vim.system({ "ansible-vault", "decrypt", "--output", "-", path }, { cwd = dir, text = true }):wait()
  assert(result.code == 0, "could not decrypt: " .. (result.stderr or ""))
  return result.stdout or ""
end

---@param path string
---@return boolean
local function is_ciphertext(path)
  local first = vim.fn.readfile(path, "", 1)[1]
  return first ~= nil and first:match("^%$ANSIBLE_VAULT") ~= nil
end

---Opens a file with a clean plugin state and returns the buffer.
---@param path string
---@param opts table
---@return integer
local function open_with(path, opts)
  require("ansible-vault").setup(opts)
  vim.cmd.edit({ args = { path } })
  vim.wait(15000, function()
    return not vim.b.ansible_vault_pending
  end, 100)
  return vim.api.nvim_get_current_buf()
end

local T = new_set({
  hooks = {
    pre_case = function()
      if vim.fn.executable("ansible-vault") ~= 1 then
        MiniTest.skip("ansible-vault is not installed")
      end
      -- Each case starts from the plugin's default configuration.
      require("ansible-vault").setup({ transparent = true })
      require("ansible-vault").reload()
    end,
    post_case = function()
      require("ansible-vault").setup({ transparent = true })
      vim.cmd("silent! %bwipeout!")
    end,
  },
})

-- Regression: auth_for took a directory while its callers passed a buffer, so
-- every operation handed vim.system a buffer number as its cwd and failed.
T["encrypting a whole buffer produces a decryptable file"] = function()
  local dir, vault = project("---\nsecret: value\n")
  vim.fn.delete(vault)
  vim.fn.writefile({ "---", "secret: plain-value" }, vault)

  require("ansible-vault").setup({ transparent = false })
  vim.cmd.edit({ args = { vault } })
  vim.cmd("VaultEncryptFile")
  vim.wait(15000, function()
    return is_ciphertext and vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]:match("^%$ANSIBLE_VAULT") ~= nil
  end, 100)
  vim.cmd("silent write")
  vim.wait(3000)

  eq(is_ciphertext(vault), true)
  eq(decrypt_externally(dir, vault):find("plain%-value") ~= nil, true)
end

-- Regression: :VaultDecryptFile hardened the buffer and filled it with
-- plaintext but never attached the write hook, so :w wrote the secret out.
T["decrypting then writing re-encrypts rather than leaking"] = function()
  local dir, vault = project("---\nsecret: must-not-leak\n")

  open_with(vault, { transparent = false })
  vim.cmd("VaultDecryptFile")
  vim.wait(15000, function()
    return vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] == "---"
  end, 100)

  vim.cmd("silent write")
  vim.wait(5000)

  eq(is_ciphertext(vault), true)
  eq(vim.fn.readfile(vault)[1]:find("must%-not%-leak"), nil)
end

-- Regression: transparent = false left the previous setup's autocmds in place,
-- so the option looked respected and was not.
T["transparent = false leaves the buffer encrypted"] = function()
  local _, vault = project("---\nsecret: value\n")

  open_with(vault, { transparent = false })
  vim.wait(2000)

  eq(vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]:match("^%$ANSIBLE_VAULT") ~= nil, true)
end

T["transparent = true decrypts on open and re-encrypts on write"] = function()
  local dir, vault = project("---\nsecret: value\n")

  open_with(vault, { transparent = true })
  vim.wait(15000, function()
    return vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] == "---"
  end, 100)

  vim.api.nvim_buf_set_lines(0, -1, -1, false, { "added: later" })
  vim.cmd("silent write")
  vim.wait(5000)

  eq(is_ciphertext(vault), true)
  eq(decrypt_externally(dir, vault):find("added: later") ~= nil, true)
end

-- Regression: the atomic rename replaced the symlink with a regular file and
-- the target never saw the change.
T["writing through a symlink keeps the link and updates the target"] = function()
  local dir, vault = project("---\nsecret: value\n")
  local link = dir .. "/link.yml"
  vim.uv.fs_symlink(vault, link)

  open_with(link, { transparent = true })
  vim.wait(15000, function()
    return vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] == "---"
  end, 100)

  vim.api.nvim_buf_set_lines(0, -1, -1, false, { "through: link" })
  vim.cmd("silent write")
  vim.wait(5000)

  eq(vim.uv.fs_lstat(link).type, "link")
  eq(decrypt_externally(dir, vault):find("through: link") ~= nil, true)
end

-- Regression: noswapfile plus BufWriteCmd removed both of Neovim's protections
-- against two editors clobbering each other.
T["a file changed underneath refuses the write"] = function()
  local dir, vault = project("---\nsecret: value\n")

  open_with(vault, { transparent = true })
  vim.wait(15000, function()
    return vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] == "---"
  end, 100)

  -- Somebody else writes the file while this buffer holds an older copy.
  local other = dir .. "/other.yml"
  vim.fn.writefile({ "---", "secret: value", "from: elsewhere" }, other)
  vim.system({ "ansible-vault", "encrypt", "--output", vault, other }, { cwd = dir, text = true }):wait()

  vim.api.nvim_buf_set_lines(0, -1, -1, false, { "from: us" })

  -- The refusal propagates out of BufWriteCmd, so `:write` fails rather than
  -- appearing to succeed. That is the behaviour we want — `:wq` aborts instead
  -- of quitting with unsaved changes — so the test asserts on it.
  local wrote = pcall(vim.cmd, "silent write")
  vim.wait(5000)

  eq(wrote, false)

  local on_disk = decrypt_externally(dir, vault)
  eq(on_disk:find("from: elsewhere") ~= nil, true)
  eq(on_disk:find("from: us"), nil)
  eq(vim.bo.modified, true)
end

T["repeated writes keep working"] = function()
  -- The guard above was first written without refreshing the remembered state,
  -- which made the second save impossible — a worse failure than the one it
  -- prevents.
  local dir, vault = project("---\none: 1\n")

  open_with(vault, { transparent = true })
  vim.wait(15000, function()
    return vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] == "---"
  end, 100)

  for i = 2, 4 do
    vim.api.nvim_buf_set_lines(0, -1, -1, false, { ("line%d: %d"):format(i, i) })
    vim.cmd("silent write")
    vim.wait(5000)
  end

  local on_disk = decrypt_externally(dir, vault)
  eq(on_disk:find("line2") ~= nil, true)
  eq(on_disk:find("line4") ~= nil, true)
  eq(vim.bo.modified, false)
end

return T
