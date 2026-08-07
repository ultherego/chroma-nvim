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

-- ---------------------------------------------------------------------------
-- Converting an existing plaintext file into a vault
-- ---------------------------------------------------------------------------
--
-- :VaultEncryptFile used to replace the buffer's contents and stop there. On a
-- file that had never been a vault that left three things undone, and all three
-- are the same problem: the plaintext this command exists to remove was still
-- reachable afterwards.

--- A project whose ansible.cfg has a password file, holding a plaintext file
--- that has never been encrypted — the case :VaultEncryptFile is for.
---@param contents string
---@return string dir, string file
local function plaintext_project(contents)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")

  vim.fn.writefile({ PASSWORD }, dir .. "/.vault_pass")
  vim.uv.fs_chmod(dir .. "/.vault_pass", tonumber("600", 8))
  vim.fn.writefile({ "[defaults]", "vault_password_file = ./.vault_pass" }, dir .. "/ansible.cfg")

  local file = dir .. "/secrets.yml"
  vim.fn.writefile(vim.split(contents, "\n"), file)

  return dir, file
end

---Opens a plaintext file the way the configuration would: undo files on.
---@param path string
---@return integer buf
local function open_plaintext(path)
  require("ansible-vault").setup({ transparent = true })
  require("ansible-vault").reload()
  vim.cmd.edit({ args = { path } })
  local buf = vim.api.nvim_get_current_buf()
  -- What lua/config/options.lua sets globally. The plugin has to turn this off
  -- itself rather than rely on it being off.
  vim.bo[buf].undofile = true
  return buf
end

---@param buf integer
---@return integer
local function writers_for(buf)
  local ok, cmds = pcall(vim.api.nvim_get_autocmds, {
    group = "ansible_vault_writer",
    event = "BufWriteCmd",
    buffer = buf,
  })
  return ok and #cmds or 0
end

---@param buf integer
local function wait_for_ciphertext(buf)
  vim.wait(15000, function()
    local first = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
    return first ~= nil and first:match("^%$ANSIBLE_VAULT") ~= nil
  end, 100)
end

T["conversion"] = new_set()

T["conversion"]["hardens the buffer and installs one writer"] = function()
  local _, file = plaintext_project("---\nsecret: plain-value\n")
  local buf = open_plaintext(file)

  vim.cmd("VaultEncryptFile")
  wait_for_ciphertext(buf)

  eq(vim.bo[buf].undofile, false)
  eq(vim.bo[buf].swapfile, false)
  eq(vim.bo[buf].modeline, false)
  eq(writers_for(buf), 1)
  -- The buffer holds ciphertext now, so the writer must write it verbatim
  -- rather than encrypting it a second time.
  eq(vim.b[buf].ansible_vault_plain, nil)
end

-- The undo file is the reason this command needed reworking. 'undofile' is
-- consulted when the undo file is written, so switching it off stops new ones
-- appearing — it does not remove the one already on disk, and that one holds
-- every earlier state of the buffer.
T["conversion"]["removes the persistent undo file holding the plaintext"] = function()
  local _, file = plaintext_project("---\nsecret: undo-marker-value\n")
  local buf = open_plaintext(file)

  -- Produce an undo file the way an ordinary editing session would.
  vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "another: line" })
  vim.cmd("silent write")
  vim.wait(2000)

  local undo = vim.fn.undofile(file)
  eq(vim.uv.fs_stat(undo) ~= nil, true)

  vim.cmd("VaultEncryptFile")
  wait_for_ciphertext(buf)

  eq(vim.uv.fs_stat(undo), nil)
end

-- Fail closed. Completing the conversion would mean announcing a vault while a
-- plaintext copy of it stays on disk, which is the failure this command is
-- supposed to prevent rather than one it may cause.
T["conversion"]["refuses when the undo file cannot be removed"] = function()
  local _, file = plaintext_project("---\nsecret: stays-plain\n")

  -- An undo directory of our own, so it can be made unwritable without
  -- touching the real one.
  local undodir = vim.fn.tempname()
  vim.fn.mkdir(undodir, "p")
  local saved_undodir = vim.o.undodir
  vim.o.undodir = undodir

  local buf = open_plaintext(file)
  vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "another: line" })
  vim.cmd("silent write")
  vim.wait(2000)

  local undo = vim.fn.undofile(file)
  eq(vim.uv.fs_stat(undo) ~= nil, true)

  -- Unlink needs write permission on the directory, not on the file.
  vim.fn.setfperm(undodir, "r-x------")

  local notices = {}
  local notify = vim.notify
  vim.notify = function(message, _)
    table.insert(notices, tostring(message))
  end

  vim.cmd("VaultEncryptFile")
  vim.wait(5000)

  vim.notify = notify
  vim.fn.setfperm(undodir, "rwx------")
  vim.o.undodir = saved_undodir

  local said = table.concat(notices, " ")
  eq(said:find("Conversion aborted") ~= nil, true)

  -- The buffer is untouched, so nothing was half-converted.
  eq(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1], "---")
  eq(is_ciphertext(file), false)
  -- And persistent undo stays off: the intent to convert has been stated, so
  -- resuming plaintext undo files would be the worse of the two outcomes.
  eq(vim.bo[buf].undofile, false)
end

-- Proves the write actually goes through persist() rather than Neovim's own
-- write path — which is also what keeps Neovim from making a backup copy of
-- the plaintext file it is replacing. 'backup' and 'writebackup' are global
-- options and cannot be turned off per buffer; taking the write over is what
-- replaces them.
T["conversion"]["the first write goes through the guarded path"] = function()
  local dir, file = plaintext_project("---\nsecret: plain-value\n")
  local buf = open_plaintext(file)

  vim.cmd("VaultEncryptFile")
  wait_for_ciphertext(buf)

  eq(writers_for(buf), 1)

  -- 'backup' is kept rather than deleted after the write, so the copy is
  -- visible afterwards instead of only existing for the duration of the write.
  -- 'backupskip' has to go too: it covers /tmp/* by default, and these fixtures
  -- live in a temporary directory, so leaving it would make the assertion below
  -- pass for a reason that has nothing to do with this plugin. Checked — with
  -- the writer removed and backupskip left alone, no backup appears either.
  local saved_backup, saved_skip = vim.o.backup, vim.o.backupskip
  vim.o.backup = true
  vim.o.backupskip = ""

  vim.cmd("silent write")
  vim.wait(5000)

  vim.o.backup = saved_backup
  vim.o.backupskip = saved_skip

  eq(is_ciphertext(file), true)
  eq(decrypt_externally(dir, file):find("plain%-value") ~= nil, true)
  -- Neovim's write machinery never ran, so it made no backup of the plaintext.
  eq(vim.uv.fs_stat(file .. "~"), nil)
end

T["conversion"]["a file changed underneath refuses the write"] = function()
  local _, file = plaintext_project("---\nsecret: plain-value\n")
  local buf = open_plaintext(file)

  vim.cmd("VaultEncryptFile")
  wait_for_ciphertext(buf)

  -- Asserted before the write, not after, and deliberately. Without the writer
  -- the `:write` below goes back to Neovim's own path, which asks "the file has
  -- changed since reading it, write anyway?" — and in a headless run that
  -- question blocks forever. Checking here turns that regression into a failing
  -- expectation instead of a CI job that times out.
  eq(writers_for(buf), 1)

  -- Another writer lands between the conversion and the write. The fingerprint
  -- was taken of the plaintext file during the conversion, so this differs from
  -- it in size as well as in mtime.
  vim.fn.writefile({ "---", "secret: someone-else" }, file)

  local notices = {}
  local notify = vim.notify
  vim.notify = function(message, _)
    table.insert(notices, tostring(message))
  end

  vim.cmd("silent write")
  vim.wait(3000)
  vim.notify = notify

  local said = table.concat(notices, " ")
  eq(said:find("changed on disk") ~= nil, true)
  -- The other writer's content survives rather than being overwritten, and the
  -- buffer stays modified: the work is still only in memory.
  eq(vim.fn.readfile(file)[2], "secret: someone-else")
  eq(vim.bo[buf].modified, true)
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

-- ---------------------------------------------------------------------------
-- Rekey
-- ---------------------------------------------------------------------------

--- A project whose ansible.cfg knows two vault ids, with the file encrypted
--- under the first. This is the shape rekey needs: the new password has to come
--- from somewhere that outlives the command.
---@return string dir, string vault
local function two_identity_project()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")

  for _, id in ipairs({ "old", "new" }) do
    vim.fn.writefile({ id .. "-password" }, ("%s/.%s_pass"):format(dir, id))
    vim.uv.fs_chmod(("%s/.%s_pass"):format(dir, id), tonumber("600", 8))
  end
  vim.fn.writefile({
    "[defaults]",
    ("vault_identity_list = old@%s/.old_pass,new@%s/.new_pass"):format(dir, dir),
  }, dir .. "/ansible.cfg")

  local vault = dir .. "/secrets.yml"
  vim.fn.writefile({ "key: value" }, vault)
  local result = vim
    .system({ "ansible-vault", "encrypt", "--encrypt-vault-id", "old", vault }, { cwd = dir, text = true })
    :wait()
  assert(result.code == 0, "could not encrypt the fixture: " .. (result.stderr or ""))

  return dir, vault
end

---@param path string
---@return string|nil
local function header_label(path)
  local first = vim.fn.readfile(path, "", 1)[1] or ""
  return first:match("^%$ANSIBLE_VAULT;[^;]+;[^;]+;(.+)$")
end

-- Regression: rekey gated on is_encrypted(buf), which inspects buffer contents.
-- Under transparent editing the buffer holds plaintext, so the command refused
-- on precisely the files it exists for.
T["rekey works on a transparently decrypted buffer"] = function()
  local dir, vault = two_identity_project()
  eq(header_label(vault), "old")

  open_with(vault, { transparent = true })
  vim.wait(15000, function()
    return vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] == "key: value"
  end, 100)
  -- The buffer holds plaintext; the file on disk is still a vault.
  eq(vim.api.nvim_buf_get_lines(0, 0, 1, false)[1], "key: value")

  local input = vim.fn.inputlist
  vim.fn.inputlist = function()
    return 2 -- the `new` identity
  end
  local notices = {}
  local notify = vim.notify
  vim.notify = function(message, _)
    table.insert(notices, tostring(message))
  end

  require("ansible-vault").rekey_file()

  vim.fn.inputlist = input
  vim.notify = notify

  local said = table.concat(notices, " ")
  eq(said:find("not vault%-encrypted"), nil)
  eq(said:find("Rekeyed") ~= nil, true)
  eq(header_label(vault), "new")

  -- Still readable, and readable as plaintext in the buffer after the reload
  -- that follows — which is only possible because the new id is one ansible
  -- resolves for itself.
  eq(decrypt_externally(dir, vault):find("key: value") ~= nil, true)
  eq(vim.api.nvim_buf_get_lines(0, 0, 1, false)[1], "key: value")
end

T["rekey leaves the old password unable to open the file"] = function()
  local dir, vault = two_identity_project()

  open_with(vault, { transparent = true })
  vim.wait(15000, function()
    return vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] == "key: value"
  end, 100)

  local input = vim.fn.inputlist
  vim.fn.inputlist = function()
    return 2
  end
  require("ansible-vault").rekey_file()
  vim.fn.inputlist = input

  eq(header_label(vault), "new")

  -- Asked away from the project, so ansible.cfg cannot quietly supply the new
  -- secret: --vault-id adds to the configured list rather than replacing it,
  -- which makes an in-project check meaningless here.
  local elsewhere = vim.fn.tempname()
  vim.fn.mkdir(elsewhere, "p")
  vim.fn.writefile(vim.fn.readfile(vault), elsewhere .. "/f.yml")

  local with_old = vim
    .system({
      "ansible-vault",
      "view",
      "--vault-password-file",
      dir .. "/.old_pass",
      "f.yml",
    }, { cwd = elsewhere, text = true })
    :wait()
  eq(with_old.code ~= 0, true)

  local with_new = vim
    .system({
      "ansible-vault",
      "view",
      "--vault-password-file",
      dir .. "/.new_pass",
      "f.yml",
    }, { cwd = elsewhere, text = true })
    :wait()
  eq(with_new.code, 0)
end

-- Regression: rekey went straight to the CLI and so was the one mutating path
-- that skipped the hard-link policy the writer enforces.
--
-- This is not the writer's failure mode repeated. Writing renames over one
-- name and leaves the others stale, which is recoverable. ansible-vault shreds
-- the inode before unlinking it, so the data behind the other name is
-- overwritten with random bytes. Measured against ansible-core 2.21.2: the
-- second name came back 4096 bytes long and no longer vault data at all.
--
-- The assertions below are therefore about the untouched name as much as about
-- the refusal.
T["rekey refuses a file with hard links, leaving both names intact"] = function()
  local dir, vault = two_identity_project()

  local other = dir .. "/linked.yml"
  assert(vim.uv.fs_link(vault, other), "could not create the hard link")

  local before = vim.fn.readfile(vault, "b")
  eq(vim.fn.readfile(other, "b"), before)
  eq(vim.uv.fs_stat(vault).nlink, 2)

  open_with(vault, { transparent = true })
  vim.wait(15000, function()
    return vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] == "key: value"
  end, 100)

  -- Answers the identity prompt for real rather than cancelling it. That is
  -- what gives the assertions below their force: with the guard removed this
  -- case does not merely reach a question it should not have reached, it goes
  -- on to perform the rekey — and a rekey through a hard link is what leaves
  -- the other name unrecoverable. Removing the guard was tried: the case fails
  -- at the missing refusal, which is the first expectation it reaches.
  local asked = false
  local input = vim.fn.inputlist
  vim.fn.inputlist = function()
    asked = true
    return 2 -- the `new` identity
  end
  local notices = {}
  local notify = vim.notify
  vim.notify = function(message, _)
    table.insert(notices, tostring(message))
  end

  require("ansible-vault").rekey_file()

  vim.fn.inputlist = input
  vim.notify = notify

  local said = table.concat(notices, " ")
  eq(said:find("Refusing to rekey") ~= nil, true)
  eq(said:find("hard links") ~= nil, true)
  -- The refusal comes before the question, because by the time the question is
  -- answered the damage is one CLI call away.
  eq(asked, false)

  -- Both names still hold exactly what they held, byte for byte, and still
  -- share the inode.
  eq(vim.fn.readfile(vault, "b"), before)
  eq(vim.fn.readfile(other, "b"), before)
  eq(vim.uv.fs_stat(vault).ino, vim.uv.fs_stat(other).ino)
  eq(header_label(vault), "old")

  -- And the untouched name is still a vault the old identity opens, which is
  -- the property the shred destroys.
  eq(decrypt_externally(dir, other):find("key: value") ~= nil, true)
end

-- Rekeying to a password typed once would leave a file that nothing can open
-- again, so with no persistent source configured the command refuses instead.
T["rekey refuses when no vault identity is configured"] = function()
  local _, vault = project("key: value\n")

  open_with(vault, { transparent = true })
  vim.wait(15000, function()
    return vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] == "key: value"
  end, 100)

  local notices = {}
  local notify = vim.notify
  vim.notify = function(message, _)
    table.insert(notices, tostring(message))
  end

  require("ansible-vault").rekey_file()
  vim.notify = notify

  local said = table.concat(notices, " ")
  eq(said:find("outlives this command") ~= nil, true)
  eq(said:find("vault_identity_list") ~= nil, true)
  eq(is_ciphertext(vault), true)
end

return T
