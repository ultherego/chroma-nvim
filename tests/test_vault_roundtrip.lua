-- Integration tests for ansible-vault.nvim, against the real CLI.

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
-- Where the subprocess runs

-- Regression: auth_for computed the project directory correctly and then threw
-- it away on the one branch where the password is typed rather than configured.
T["a prompted password still runs in the project directory"] = function()
  -- Two projects. Neovim sits in the first; the buffer belongs to the second.
  local elsewhere = vim.fn.tempname()
  local project_dir = vim.fn.tempname()
  vim.fn.mkdir(elsewhere, "p")
  vim.fn.mkdir(project_dir .. "/group_vars", "p")

  -- An ansible.cfg with no vault settings: enough for context_dir to find the
  -- project, not enough for a password source, so the prompt branch runs.
  vim.fn.writefile({ "[defaults]" }, project_dir .. "/ansible.cfg")

  local vault = project_dir .. "/group_vars/vault.yml"
  vim.fn.writefile({ "$ANSIBLE_VAULT;1.1;AES256", "3132333435" }, vault)

  local bin = vim.fn.tempname()
  vim.fn.mkdir(bin, "p")
  local log = bin .. "/cwd"
  vim.fn.writefile({
    "#!/bin/sh",
    ('printf "%%s\\n" "$PWD" >> %s'):format(vim.fn.shellescape(log)),
    'echo "secret: value"',
    "exit 0",
  }, bin .. "/ansible-vault")
  vim.fn.setfperm(bin .. "/ansible-vault", "rwxr-xr-x")

  local saved = {
    path = vim.env.PATH,
    config = vim.env.ANSIBLE_CONFIG,
    cwd = vim.fn.getcwd(),
    inputsecret = vim.fn.inputsecret,
  }
  vim.env.PATH = bin .. ":" .. vim.env.PATH
  -- Pins which ansible.cfg ansible-config resolves, so the case does not depend
  -- on whether the machine running it has one in $HOME.
  vim.env.ANSIBLE_CONFIG = project_dir .. "/ansible.cfg"
  vim.fn.inputsecret = function()
    return PASSWORD
  end

  vim.cmd.cd(elsewhere)
  require("ansible-vault").setup({ transparent = false })
  require("ansible-vault").reload()
  vim.cmd.edit({ args = { vault } })
  vim.cmd("VaultView")
  vim.wait(15000, function()
    return vim.uv.fs_stat(log) ~= nil
  end, 50)

  vim.fn.inputsecret = saved.inputsecret
  vim.env.ANSIBLE_CONFIG = saved.config
  vim.env.PATH = saved.path
  vim.cmd.cd(saved.cwd)

  -- Guards against the case passing because both paths happen to be the same.
  MiniTest.expect.no_equality(vim.uv.fs_realpath(elsewhere), vim.uv.fs_realpath(project_dir))

  local ran_in = vim.fn.readfile(log)[1]
  eq(vim.uv.fs_realpath(ran_in), vim.uv.fs_realpath(project_dir))
end

-- ---------------------------------------------------------------------------
-- The password typed at the prompt, and the file it is staged in

T["staged password"] = new_set()

--- A project whose ansible.cfg names no password source, so every command prompts,
--- with a fake `ansible-vault` on PATH and a runtime directory of its own.
---@return table
local function prompting_project()
  local dir = vim.fn.tempname()
  local bin = vim.fn.tempname()
  local runtime = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  vim.fn.mkdir(bin, "p")
  vim.fn.mkdir(runtime, "p")
  -- secure_dir refuses anything that is not 0700, and mkdir under the ambient
  -- umask does not produce that.
  vim.fn.setfperm(runtime, "rwx------")

  vim.fn.writefile({ "[defaults]" }, dir .. "/ansible.cfg")
  local vault = dir .. "/secrets.yml"
  vim.fn.writefile({ "$ANSIBLE_VAULT;1.1;AES256", "3132333435" }, vault)

  vim.fn.writefile({ "#!/bin/sh", 'echo "secret: value"', "exit 0" }, bin .. "/ansible-vault")
  vim.fn.setfperm(bin .. "/ansible-vault", "rwxr-xr-x")

  local h = {
    dir = dir,
    vault = vault,
    runtime = runtime,
    saved = {
      path = vim.env.PATH,
      config = vim.env.ANSIBLE_CONFIG,
      runtime_dir = vim.env.XDG_RUNTIME_DIR,
      inputsecret = vim.fn.inputsecret,
      unlink = vim.uv.fs_unlink,
      notify = vim.notify,
    },
  }

  vim.env.PATH = bin .. ":" .. vim.env.PATH
  vim.env.ANSIBLE_CONFIG = dir .. "/ansible.cfg"
  vim.env.XDG_RUNTIME_DIR = runtime
  vim.fn.inputsecret = function()
    return PASSWORD
  end

  ---Password files still staged in the runtime directory.
  ---@return string[]
  function h.staged()
    return vim.fn.glob(runtime .. "/ansible-vault.nvim/password.*", false, true)
  end

  function h.restore()
    vim.env.PATH = h.saved.path
    vim.env.ANSIBLE_CONFIG = h.saved.config
    vim.env.XDG_RUNTIME_DIR = h.saved.runtime_dir
    vim.fn.inputsecret = h.saved.inputsecret
    vim.uv.fs_unlink = h.saved.unlink
    vim.notify = h.saved.notify
  end

  require("ansible-vault").setup({ transparent = false })
  require("ansible-vault").reload()
  vim.cmd.edit({ args = { vault } })
  h.buf = vim.api.nvim_get_current_buf()

  ---`:VaultView` opens its float focused, so getting back to the vault buffer is
  ---part of asking for a second one.
  function h.focus()
    vim.api.nvim_set_current_buf(h.buf)
  end

  return h
end

-- The staged file holds the password in the clear. It used to be removed after the
-- process returned, on a path an exception could skip entirely.
T["staged password"]["a spawn that cannot start still removes it"] = function()
  local h = prompting_project()

  -- Runs once with the project intact, which also caches what ansible-config said
  -- about it: the second attempt then reaches the spawn rather than stopping earlier.
  h.focus()
  vim.cmd("VaultView")
  vim.wait(5000)
  eq(h.staged(), {})

  -- Measured: vim.system raises ENOENT before starting anything when its cwd is gone.
  vim.fn.delete(h.dir, "rf")

  local notices = {}
  vim.notify = function(message, _)
    table.insert(notices, tostring(message))
  end
  h.focus()
  local ok, err = pcall(vim.cmd, "VaultView")
  vim.wait(5000)
  h.restore()

  eq(ok, true, err)
  eq(table.concat(notices, " "):find("could not run ansible%-vault") ~= nil, true)
  eq(h.staged(), {})
end

-- The configuration lookup runs in the same directory and raises the same way, before
-- any password is staged. It is a message about the project, not a stack trace.
T["staged password"]["a configuration lookup that cannot run is reported"] = function()
  local h = prompting_project()

  -- Nothing cached, so the lookup itself has to run in the directory that is gone.
  require("ansible-vault").reload()
  vim.fn.delete(h.dir, "rf")

  local notices = {}
  vim.notify = function(message, _)
    table.insert(notices, tostring(message))
  end
  h.focus()
  local ok, err = pcall(vim.cmd, "VaultView")
  vim.wait(5000)
  h.restore()

  eq(ok, true, err)
  eq(table.concat(notices, " "):find("could not run ansible%-config") ~= nil, true)
  eq(h.staged(), {})
end

-- pcall around a synchronous libuv call answers true whether or not the file went
-- away, so a failure to remove the password used to be indistinguishable from success.
-- Ansible resolves vault ids by running programs, and a program can wait on a
-- person. Unbounded, that was the editor frozen with the staged password still
-- on disk for as long as the freeze lasted.
T["staged password"]["a command that never answers is stopped, and the password goes"] = function()
  local h = prompting_project()

  -- Replaces the fake with one that hangs rather than answering.
  local bin = vim.fs.dirname(vim.fn.exepath("ansible-vault"))
  vim.fn.writefile({ "#!/bin/sh", "sleep 120" }, bin .. "/ansible-vault")
  vim.fn.setfperm(bin .. "/ansible-vault", "rwxr-xr-x")

  local notices = {}
  vim.notify = function(message, _)
    table.insert(notices, tostring(message))
  end

  local started = vim.uv.hrtime()
  h.focus()
  local ok = pcall(vim.cmd, "VaultView")
  local elapsed = (vim.uv.hrtime() - started) / 1e9
  h.restore()

  eq(ok, true)
  -- Bounded, with room for the kill of a child that outlives it.
  eq(elapsed < 60, true)
  eq(table.concat(notices, " "):find("did not answer within") ~= nil, true)
  eq(h.staged(), {})
end

T["staged password"]["one that cannot be removed is reported with its path"] = function()
  local h = prompting_project()

  local real_unlink = vim.uv.fs_unlink
  vim.uv.fs_unlink = function(path)
    if path:find("/password%.") then
      return nil, "EPERM: operation not permitted"
    end
    return real_unlink(path)
  end

  local notices = {}
  vim.notify = function(message, _)
    table.insert(notices, tostring(message))
  end

  h.focus()
  vim.cmd("VaultView")
  vim.wait(5000)
  h.restore()

  local said = table.concat(notices, "\n")
  eq(said:find("SECURITY") ~= nil, true)
  eq(said:find("EPERM") ~= nil, true)

  -- The path is in the message because removing it by hand is what is left to do.
  local leftover = h.staged()
  eq(#leftover, 1)
  eq(said:find(leftover[1], 1, true) ~= nil, true)

  real_unlink(leftover[1])
end

-- ---------------------------------------------------------------------------
-- Converting an existing plaintext file into a vault

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

-- The undo file is why this command needed reworking: switching 'undofile' off stops
-- new ones appearing and removes nothing already on disk.
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

-- Fail closed: completing the conversion would announce a vault while a plaintext
-- copy of it stayed on disk.
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

-- Proves the write goes through persist() rather than Neovim's own path, which is
-- also what keeps it from backing up the plaintext file it replaces.
T["conversion"]["the first write goes through the guarded path"] = function()
  local dir, file = plaintext_project("---\nsecret: plain-value\n")
  local buf = open_plaintext(file)

  vim.cmd("VaultEncryptFile")
  wait_for_ciphertext(buf)

  eq(writers_for(buf), 1)

  -- 'backup' is kept rather than deleted after the write, so the copy is
  -- visible afterwards instead of only existing for the duration of the write.
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

  -- Asserted before the write on purpose: without the writer, `:write` falls back to
  -- Neovim's path and blocks on its changed-file prompt, which no headless run answers.
  eq(writers_for(buf), 1)

  -- Another writer lands between the conversion and the write, differing from the
  -- fingerprint in size as well as in mtime.
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

T["decrypt ordering"] = new_set()

---Runs `fn` with the writer refusing to install, and returns what was notified.
---@param fn fun()
---@return string
local function with_failing_writer(fn)
  local vault = require("ansible-vault")
  local real_attach, real_notify = vault.attach_writer, vim.notify
  local notices = {}

  vault.attach_writer = function()
    error("synthetic writer failure")
  end
  vim.notify = function(message, _)
    table.insert(notices, tostring(message))
  end

  local ok, err = pcall(fn)

  vault.attach_writer = real_attach
  vim.notify = real_notify
  assert(ok, err)

  return table.concat(notices, " ")
end

-- The plaintext must not appear in a file buffer the writer does not cover. What
-- actually raises there is nvim_buf_set_lines on a 'nomodifiable' buffer, but the
-- order has to hold whichever of the two steps fails.
T["decrypt ordering"]["a writer that cannot be installed leaves the ciphertext"] = function()
  local _, vault = project("---\nsecret: must-not-appear\n")

  local buf = open_with(vault, { transparent = false })
  local said = with_failing_writer(function()
    vim.cmd("VaultDecryptFile")
    vim.wait(5000)
  end)

  eq(said:find("Refusing to decrypt") ~= nil, true)
  eq(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]:match("^%$ANSIBLE_VAULT") ~= nil, true)
  eq(vim.b[buf].ansible_vault_plain, nil)
  eq(writers_for(buf), 0)
end

T["decrypt ordering"]["transparent decrypt fails the same way"] = function()
  local _, vault = project("---\nsecret: must-not-appear\n")

  local buf
  local said = with_failing_writer(function()
    require("ansible-vault").setup({ transparent = true })
    require("ansible-vault").reload()
    vim.cmd.edit({ args = { vault } })
    buf = vim.api.nvim_get_current_buf()
    vim.wait(5000)
  end)

  eq(said:find("Refusing to decrypt") ~= nil, true)
  eq(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]:match("^%$ANSIBLE_VAULT") ~= nil, true)
  eq(vim.b[buf].ansible_vault_plain, nil)
  eq(writers_for(buf), 0)
end

-- A reload that cannot be decrypted must not leave the previous decrypt's flag
-- behind: the buffer holds ciphertext from the moment the file is re-read.
T["decrypt ordering"]["a failed reload clears the flag the last decrypt set"] = function()
  local dir, vault = project("---\nsecret: value\n")

  local buf = open_with(vault, { transparent = true })
  vim.wait(15000, function()
    return vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "---"
  end, 100)
  eq(vim.b[buf].ansible_vault_plain, true)

  -- The password file keeps its path, so auth still resolves; only the password
  -- it holds is now the wrong one.
  vim.fn.writefile({ "not-the-password" }, dir .. "/.vault_pass")

  local notify = vim.notify
  vim.notify = function() end
  vim.cmd("edit!")
  vim.wait(5000)
  vim.notify = notify

  eq(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]:match("^%$ANSIBLE_VAULT") ~= nil, true)
  eq(vim.b[buf].ansible_vault_plain, nil)
end

-- `:edit!` reloads the ciphertext and keeps buffer variables, so the flag saying "this
-- buffer holds plaintext" outlived the plaintext. Measured without the guard: the writer
-- hands the ciphertext back to ansible-vault, which answers "input is already encrypted",
-- and the write fails for good.
T["decrypt ordering"]["a reloaded buffer writes its ciphertext verbatim"] = function()
  local dir, vault = project("---\nsecret: single-layer\n")

  local buf = open_with(vault, { transparent = false })
  vim.cmd("VaultDecryptFile")
  vim.wait(15000, function()
    return vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "---"
  end, 100)
  eq(vim.b[buf].ansible_vault_plain, true)

  vim.cmd("edit!")
  eq(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]:match("^%$ANSIBLE_VAULT") ~= nil, true)
  eq(writers_for(buf), 1)

  vim.cmd("silent write")
  vim.wait(5000)

  -- One layer, not two: decrypting once has to reach the secret, not another header.
  local decrypted = decrypt_externally(dir, vault)
  eq(decrypted:find("^%$ANSIBLE_VAULT"), nil)
  eq(decrypted:find("single%-layer") ~= nil, true)
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

  -- The refusal propagates out of BufWriteCmd, so `:write` fails rather than appearing
  -- to succeed and `:wq` aborts instead of quitting with unsaved changes.
  local wrote = pcall(vim.cmd, "silent write")
  vim.wait(5000)

  eq(wrote, false)

  local on_disk = decrypt_externally(dir, vault)
  eq(on_disk:find("from: elsewhere") ~= nil, true)
  eq(on_disk:find("from: us"), nil)
  eq(vim.bo.modified, true)
end

-- A conversion can start from a buffer whose file does not exist yet. The
-- baseline was then nil, which the conflict check reads as "nothing remembered,
-- nothing to protect" — so a file that appeared in between was overwritten.
-- Neovim's own E13 stops a plain `:write` here and tells you to add `!`; the
-- bang is meant to override Neovim's checks, not this plugin's.
T["a file that appears before the first write refuses it"] = function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  vim.fn.writefile({ PASSWORD }, dir .. "/.vault_pass")
  vim.uv.fs_chmod(dir .. "/.vault_pass", tonumber("600", 8))
  vim.fn.writefile({ "[defaults]", "vault_password_file = ./.vault_pass" }, dir .. "/ansible.cfg")

  local target = dir .. "/secrets.yml"
  eq(vim.uv.fs_stat(target), nil)

  require("ansible-vault").setup({ transparent = true })
  vim.cmd.edit({ args = { target } })
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "---", "mine: from-the-buffer" })
  vim.cmd("VaultEncryptFile")
  vim.wait(15000, function()
    return vim.b.ansible_vault_stat ~= nil
  end, 100)

  -- Somebody else gets there first.
  vim.fn.writefile({ "$ANSIBLE_VAULT;1.1;AES256", "3031323334" }, target)
  local theirs = vim.fn.readfile(target)

  local notices, real_notify = {}, vim.notify
  vim.notify = function(message, _)
    table.insert(notices, tostring(message))
  end
  pcall(vim.cmd, "silent write!")
  vim.wait(5000)
  vim.notify = real_notify

  eq(table.concat(notices, " "):find("a file has appeared on disk") ~= nil, true)
  eq(vim.fn.readfile(target), theirs)
  eq(vim.bo.modified, true)
end

-- `:write` is several commands. Taking over BufWriteCmd covers `:w`, and leaves
-- `:1,10w elsewhere` (FileWriteCmd) and `:1,10w >> elsewhere` (FileAppendCmd) to
-- Neovim's own writer — which would put the plaintext in the buffer on disk. The
-- whole-buffer forms reach BufWriteCmd but name a different target, which the
-- writer ignored: it re-encrypted into the vault's own file and said nothing.
T["a decrypted vault refuses every write that is not its own file"] = function()
  local dir, vault = project("---\napi_key: SUPERSECRET\n")

  local notices, real_notify = {}, vim.notify
  open_with(vault, { transparent = true })
  vim.wait(15000, function()
    return vim.b.ansible_vault_plain == true
  end, 100)
  eq(vim.b.ansible_vault_plain, true)

  ---@param command string
  ---@param target string
  local function refuses(command, target)
    notices = {}
    vim.notify = function(message, _)
      table.insert(notices, tostring(message))
    end
    pcall(vim.cmd, command)
    vim.wait(2000)
    vim.notify = real_notify

    local said = table.concat(notices, " "):gsub("\n", " ")
    eq({ command, said:find("Refusing") ~= nil }, { command, true })
    -- And nothing of it reached the disk, whatever the message said.
    if vim.uv.fs_stat(target) then
      eq({ command, vim.fn.readfile(target) }, { command, {} })
    end
  end

  refuses("silent write " .. dir .. "/elsewhere", dir .. "/elsewhere")
  refuses("silent 1,2write " .. dir .. "/part", dir .. "/part")
  refuses("silent 1,2write >> " .. dir .. "/appended", dir .. "/appended")
  refuses("silent saveas! " .. dir .. "/renamed", dir .. "/renamed")

  -- The vault itself is untouched by all of that.
  eq(is_ciphertext(vault), true)
  eq(decrypt_externally(dir, vault):find("SUPERSECRET") ~= nil, true)
end

-- Staging does not write the working tree. It writes `.git/index` and a blob
-- object, so a decrypted vault staged from the buffer puts the plaintext into
-- git — past the writer, the atomic replacement and everything else that guards
-- the file. Measured before the guard existed: the index held the secret and the
-- ciphertext was gone.
T["gitsigns cannot stage a decrypted vault"] = function()
  local root = vim.fn.stdpath("data") .. "/lazy/gitsigns.nvim"
  if not vim.uv.fs_stat(root) then
    MiniTest.skip("gitsigns.nvim is not installed")
  end
  vim.opt.rtp:append(root)

  local dir, vault = project("---\npassword: VAULT_GITSIGNS_SENTINEL\n")
  vim.fn.system({ "git", "-C", dir, "init", "-q" })
  vim.fn.system({ "git", "-C", dir, "config", "user.email", "t@example.com" })
  vim.fn.system({ "git", "-C", dir, "config", "user.name", "T" })
  vim.fn.system({ "git", "-C", dir, "add", "secrets.yml" })
  vim.fn.system({ "git", "-C", dir, "-c", "commit.gpgsign=false", "commit", "-qm", "vault" })

  -- The options this configuration ships, on_attach included.
  local spec
  for _, entry in ipairs(require("plugins.git")) do
    if entry[1] == "lewis6991/gitsigns.nvim" then
      spec = entry
    end
  end
  local gitsigns = require("gitsigns")
  gitsigns.setup(spec.opts)

  local saved_cwd = vim.fn.getcwd()
  vim.cmd.cd(dir)
  open_with(vault, { transparent = true })
  vim.wait(15000, function()
    return vim.b.ansible_vault_plain == true
  end, 100)
  eq(vim.b.ansible_vault_plain, true)

  -- Hunks are computed asynchronously; staging before they exist stages nothing
  -- and would pass for the wrong reason.
  vim.wait(10000, function()
    return #(gitsigns.get_hunks(0) or {}) > 0
  end, 100)
  eq(#(gitsigns.get_hunks(0) or {}), 0)

  pcall(gitsigns.stage_buffer)
  vim.wait(3000)
  vim.cmd.cd(saved_cwd)

  local staged = vim.fn.system({ "git", "-C", dir, "show", ":secrets.yml" })
  eq(staged:find("VAULT_GITSIGNS_SENTINEL", 1, true), nil)
  eq(staged:find("$ANSIBLE_VAULT", 1, true) ~= nil, true)
end

-- Detaching a language server is not silent: `reset_buf` flushes the client's
-- pending changes before it removes the tracking, so a client attached while the
-- buffer held ciphertext was told, by the detach itself, what the buffer had
-- changed to. Measured against an in-process server: didOpen carried the
-- ciphertext and didChange carried the secret.
T["a language server is never told what a decrypted vault says"] = function()
  local dir, vault = project("---\npassword: LSP_SENTINEL\n")

  local seen = {}
  local function server(dispatchers)
    local closing = false
    return {
      request = function(method, _, callback)
        if method == "initialize" then
          callback(nil, { capabilities = { textDocumentSync = 1 } })
        elseif method == "shutdown" then
          callback(nil, nil)
        end
        return true, 1
      end,
      notify = function(method, params)
        local text
        if method == "textDocument/didOpen" then
          text = params.textDocument.text
        elseif method == "textDocument/didChange" then
          text = (params.contentChanges[1] or {}).text
        end
        table.insert(seen, text or "")
        return true
      end,
      is_closing = function()
        return closing
      end,
      terminate = function()
        closing = true
        dispatchers.on_exit(0, 0)
      end,
    }
  end

  -- Attached the way a real server is: by filetype, which is decided before the
  -- decrypt handler runs.
  local group = vim.api.nvim_create_augroup("vault_test_lsp", { clear = true })
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "yaml",
    callback = function(ev)
      vim.lsp.start({ name = "vault-test", cmd = server, root_dir = dir }, { bufnr = ev.buf })
    end,
  })

  open_with(vault, { transparent = true })
  vim.wait(15000, function()
    return vim.b.ansible_vault_plain == true
  end, 100)
  vim.wait(2000)
  pcall(vim.api.nvim_del_augroup_by_id, group)

  eq(vim.b.ansible_vault_plain, true)
  -- It was attached at some point, or the case proves nothing.
  eq(#seen > 0, true)
  for _, text in ipairs(seen) do
    eq(text:find("LSP_SENTINEL", 1, true), nil)
  end
end

T["repeated writes keep working"] = function()
  -- The guard above was first written without refreshing the remembered state, which
  -- made the second save impossible.
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
-- The temporary file the replacement goes through

T["atomic replacement"] = new_set()

---Opens a vault transparently and waits for the plaintext to arrive.
---@param path string
local function opened_decrypted(path)
  open_with(path, { transparent = true })
  vim.wait(15000, function()
    return vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] == "---"
  end, 100)
end

-- Regression: the temporary name was built from the pid alone. A file left behind
-- by a crashed session came back as soon as that pid was reused, and `wx` refuses
-- an existing name — so every write of that vault failed with EEXIST for the life
-- of the process, with the work still only in the buffer.
T["atomic replacement"]["a leftover temporary file does not block the write"] = function()
  local dir, vault = project("---\nsecret: value\n")
  opened_decrypted(vault)

  -- Exactly what the old scheme would have called it, in a session that never got
  -- to remove it.
  local stale = ("%s.ansible-vault.nvim.%d.tmp"):format(vim.uv.fs_realpath(vault), vim.uv.os_getpid())
  vim.fn.writefile({ "leftover" }, stale)

  vim.api.nvim_buf_set_lines(0, -1, -1, false, { "written: yes" })
  pcall(vim.cmd, "silent write")
  vim.wait(5000)

  eq(vim.bo.modified, false)
  eq(decrypt_externally(dir, vault):find("written: yes") ~= nil, true)
  -- Left alone: it was never this write's file.
  eq(vim.fn.readfile(stale), { "leftover" })
end

-- pcall around fs_unlink answers true whether or not the file went away, so a
-- temporary copy could stay beside the vault with nothing said about it.
T["atomic replacement"]["a temporary file that cannot be removed is named"] = function()
  local dir, vault = project("---\nsecret: value\n")
  opened_decrypted(vault)

  local real_rename, real_unlink, real_notify = vim.uv.fs_rename, vim.uv.fs_unlink, vim.notify
  local notices = {}

  ---@param path string
  ---@return boolean
  local function ours(path)
    return path:find("%.ansible%-vault%.nvim%.") ~= nil
  end

  -- The write gets as far as a finished temporary file, and then can neither put it
  -- in place nor take it away.
  vim.uv.fs_rename = function(from, to)
    if ours(from) then
      return nil, "EXDEV: cross-device link"
    end
    return real_rename(from, to)
  end
  vim.uv.fs_unlink = function(path)
    if ours(path) then
      return nil, "EPERM: operation not permitted"
    end
    return real_unlink(path)
  end
  vim.notify = function(message, _)
    table.insert(notices, tostring(message))
  end

  vim.api.nvim_buf_set_lines(0, -1, -1, false, { "written: no" })
  pcall(vim.cmd, "silent write")
  vim.wait(5000)

  vim.uv.fs_rename = real_rename
  vim.uv.fs_unlink = real_unlink
  vim.notify = real_notify

  local said = table.concat(notices, " "):gsub("\n", " ")
  local leftovers = vim.fn.glob(vim.fs.dirname(vim.uv.fs_realpath(vault)) .. "/*.ansible-vault.nvim.*.tmp", false, true)

  eq(#leftovers, 1)
  eq(said:find("EXDEV") ~= nil, true)
  eq(said:find("temporary copy could not be removed") ~= nil, true)
  eq(said:find(leftovers[1], 1, true) ~= nil, true)
  -- And the vault itself still holds what it held.
  eq(decrypt_externally(dir, vault):find("written: no"), nil)

  vim.fn.delete(leftovers[1])
end

---Runs `fn` recording every path fsynced during it, optionally failing one.
---@param fail_path string|nil the path whose fsync should report an error
---@param fn function
---@return string[] paths
local function watching_fsync(fail_path, fn)
  local real_open, real_fsync = vim.uv.fs_open, vim.uv.fs_fsync
  local of, synced = {}, {}

  -- fsync takes a descriptor, so the path it belongs to has to be remembered
  -- when the descriptor is handed out.
  vim.uv.fs_open = function(path, flags, mode)
    local fd, err = real_open(path, flags, mode)
    if fd then
      of[fd] = path
    end
    return fd, err
  end

  vim.uv.fs_fsync = function(fd)
    local path = of[fd]
    table.insert(synced, path or "?")
    if fail_path and path == fail_path then
      return nil, "EIO: i/o error"
    end
    return real_fsync(fd)
  end

  local ok, err = pcall(fn)

  vim.uv.fs_open = real_open
  vim.uv.fs_fsync = real_fsync
  assert(ok, err)

  return synced
end

-- The rename is atomic but not durable on its own: until the directory holding
-- the entry is synced, a power cut can leave the old name in place.
T["atomic replacement"]["the directory entry is synced after the rename"] = function()
  local dir, vault = project("---\nsecret: value\n")
  opened_decrypted(vault)
  vim.api.nvim_buf_set_lines(0, -1, -1, false, { "written: yes" })

  local holding = vim.fs.dirname(vim.uv.fs_realpath(vault))
  local synced = watching_fsync(nil, function()
    pcall(vim.cmd, "silent write")
  end)

  eq(vim.tbl_contains(synced, holding), true)
  eq(decrypt_externally(dir, vault):find("written: yes") ~= nil, true)
end

-- Durability is the one failure here with nothing to undo: the vault is already
-- in place, so reporting a failed write would be false and would leave the
-- buffer modified over work that did reach the disk.
T["atomic replacement"]["a directory that cannot be synced still counts as written"] = function()
  local dir, vault = project("---\nsecret: value\n")
  opened_decrypted(vault)
  vim.api.nvim_buf_set_lines(0, -1, -1, false, { "written: yes" })

  local holding = vim.fs.dirname(vim.uv.fs_realpath(vault))
  local notices, real_notify = {}, vim.notify
  vim.notify = function(message, _)
    table.insert(notices, tostring(message))
  end

  watching_fsync(holding, function()
    pcall(vim.cmd, "silent write")
  end)
  vim.notify = real_notify

  local said = table.concat(notices, " "):gsub("\n", " ")
  eq(said:find("could not be confirmed as on%-disk") ~= nil, true)
  eq(said:find("Could not write"), nil)
  eq(vim.bo.modified, false)
  eq(decrypt_externally(dir, vault):find("written: yes") ~= nil, true)
end

-- ---------------------------------------------------------------------------
-- Rekey

--- A project whose ansible.cfg knows two vault ids, with the file encrypted
--- under the first. This is the shape rekey needs: the new password has to come
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

  -- Still readable, and still decrypted in the buffer after the reload, which only
  -- works because ansible resolves the new id for itself.
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

  -- Asked away from the project: --vault-id adds to the list from ansible.cfg rather
  -- than replacing it, so an in-project check would prove nothing.
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

  -- Answers the identity prompt for real, so with the guard removed the rekey happens
  -- and the assertions below have something to catch.
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

-- ---------------------------------------------------------------------------
-- Choosing which identity encrypts

T["encrypt identity"] = new_set()

---Answers the identity list with `choice`, runs `fn`, and puts the prompt back.
---@param choice integer what inputlist returns; 0 is the dismissal
---@param fn fun()
---@return string notified
local function choosing(choice, fn)
  local input, notify = vim.fn.inputlist, vim.notify
  local notices = {}

  vim.fn.inputlist = function()
    return choice
  end
  vim.notify = function(message, _)
    table.insert(notices, tostring(message))
  end

  local ok, err = pcall(fn)

  vim.fn.inputlist = input
  vim.notify = notify
  assert(ok, err)

  return table.concat(notices, " ")
end

---Which of the two configured passwords opens a file, asked outside the project so
---ansible.cfg cannot answer for it.
---@param dir string
---@param path string
---@param id string
---@return boolean
local function opens_with(dir, path, id)
  local elsewhere = vim.fn.tempname()
  vim.fn.mkdir(elsewhere, "p")
  vim.fn.writefile(vim.fn.readfile(path), elsewhere .. "/f.yml")

  local result = vim
    .system(
      { "ansible-vault", "view", "--vault-password-file", ("%s/.%s_pass"):format(dir, id), "f.yml" },
      { cwd = elsewhere, text = true }
    )
    :wait()
  return result.code == 0
end

-- Regression: the inline path never passed --encrypt-vault-id, so with several
-- identities configured the whole-file commands asked and this one did not.
T["encrypt identity"]["an inline value is encrypted with the chosen id"] = function()
  local dir, _ = two_identity_project()

  local plain = dir .. "/vars.yml"
  vim.fn.writefile({ "secret: inline-value" }, plain)
  open_with(plain, { transparent = false })

  local said = choosing(2, function()
    vim.cmd("1VaultEncrypt")
    vim.wait(15000, function()
      return vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]:find("!vault") ~= nil
    end, 100)
  end)
  eq(said:find("Encrypted secret") ~= nil, true)

  vim.cmd("silent write")
  vim.wait(3000)

  -- The block carries the id it was encrypted under, and only that password opens it.
  local block = table.concat(vim.fn.readfile(plain), "\n")
  eq(block:find("$ANSIBLE_VAULT;1.2;AES256;new", 1, true) ~= nil, true)

  -- The block on its own, dedented, so ansible-vault can be pointed straight at it.
  local extracted = dir .. "/extracted.yml"
  local block_lines = {}
  for _, line in ipairs(vim.fn.readfile(plain)) do
    if line:find("$ANSIBLE_VAULT", 1, true) or line:find("^%s+%x+$") then
      table.insert(block_lines, (line:gsub("^%s+", "")))
    end
  end
  vim.fn.writefile(block_lines, extracted)
  eq(opens_with(dir, extracted, "new"), true)
  eq(opens_with(dir, extracted, "old"), false)
end

T["encrypt identity"]["dismissing the list leaves an inline value alone"] = function()
  local dir, _ = two_identity_project()

  local plain = dir .. "/vars.yml"
  vim.fn.writefile({ "secret: inline-value" }, plain)
  open_with(plain, { transparent = false })

  local said = choosing(0, function()
    vim.cmd("1VaultEncrypt")
    vim.wait(2000)
  end)

  -- Silence is the assertion that matters: ansible refuses to guess between two
  -- identities, so running it anyway would also leave the value unencrypted — but
  -- with an error about --encrypt-vault-id rather than nothing at all.
  eq(said, "")
  eq(vim.api.nvim_buf_get_lines(0, 0, 1, false)[1], "secret: inline-value")
end

T["encrypt identity"]["dismissing the list leaves a whole buffer alone"] = function()
  local dir, _ = two_identity_project()

  local plain = dir .. "/whole.yml"
  vim.fn.writefile({ "secret: whole-value" }, plain)
  open_with(plain, { transparent = false })

  local said = choosing(0, function()
    vim.cmd("VaultEncryptFile")
    vim.wait(2000)
  end)

  eq(said, "")
  eq(vim.api.nvim_buf_get_lines(0, 0, 1, false)[1], "secret: whole-value")
  eq(vim.fn.readfile(plain)[1], "secret: whole-value")
end

-- The write is where dismissing costs most, so it says so rather than looking done.
T["encrypt identity"]["dismissing the list refuses the write"] = function()
  local dir, vault = two_identity_project()

  local buf = open_with(vault, { transparent = true })
  vim.wait(15000, function()
    return vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "key: value"
  end, 100)

  vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "added: later" })
  local said = choosing(0, function()
    vim.cmd("silent write")
    vim.wait(3000)
  end)

  eq(said:find("no vault id was chosen") ~= nil, true)
  eq(vim.bo[buf].modified, true)
  -- The file still holds what the last successful write put there.
  eq(decrypt_externally(dir, vault):find("added: later"), nil)
end

return T
