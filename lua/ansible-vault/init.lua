-- ansible-vault.nvim — Ansible Vault inside the editor.
--
-- Written because the survey of 2026-08-06 found no maintained candidate:
-- every existing plugin is a single-person project of 0–7 stars, the most
-- visible one untouched since 2023. See CONTRACT.md, rule #2.
--
-- Kept free of any dependency on the surrounding configuration so it can move
-- to its own repository unchanged.
--
-- The part these tools usually get wrong is not the encryption — that is one
-- subprocess call — but everything around it. Secrets end up in `ps` output,
-- in the undo file, in the swap file. This module treats those as the actual
-- problem; see lua/ansible-vault/cli.lua for the process side and
-- `harden_buffer` below for the editor side.

local cli = require("ansible-vault.cli")
local vault_config = require("ansible-vault.config")

local M = {}

---@class ansible_vault.Opts
---@field keymaps boolean|nil      create the default <leader>a mappings
---@field transparent boolean|nil  decrypt vault files on open, re-encrypt on write
local defaults = {
  keymaps = false,
  transparent = true,
}

M.options = vim.deepcopy(defaults)

--- Cached per working directory: ansible-config takes ~200ms to answer and the
--- answer only changes when ansible.cfg does.
local resolved_cache = {}

---@return ansible_vault.Auth|nil, string|nil err
local function auth_for(cwd)
  cwd = cwd or vim.fn.getcwd()

  if resolved_cache[cwd] == nil then
    local resolved, err = vault_config.resolve(cwd)
    if not resolved then
      return nil, err
    end
    resolved_cache[cwd] = resolved
  end

  local resolved = resolved_cache[cwd]

  if resolved.password_file or #resolved.identities > 0 then
    -- Deliberately passes no credential arguments. ansible already reads these
    -- from ansible.cfg, and repeating them on the command line registers a
    -- second identity under the same label, which ansible then refuses:
    --
    --   The vault-ids default,default are available to encrypt.
    --   Specify the vault-id to encrypt with --encrypt-vault-id
    --
    -- Found by running it, not by reading about it. All that is needed is to
    -- run in the directory where that ansible.cfg applies.
    return {
      cwd = cwd,
      identities = resolved.identities,
      encrypt_identity = resolved.encrypt_identity,
    }
  end

  -- Nothing configured: ask. inputsecret keeps the password off the screen and
  -- out of the command-line history.
  local password = vim.fn.inputsecret("Vault password: ")
  if password == "" then
    return nil, "cancelled"
  end

  return { password = password }
end

---Which identity to encrypt with.
---
---With one identity ansible picks it. With several it refuses to guess, so
---either vault_encrypt_identity is configured or the user is asked here.
---@param auth ansible_vault.Auth
---@return string|nil
local function encrypt_identity_for(auth)
  if auth.encrypt_identity then
    return auth.encrypt_identity
  end

  local ids = auth.identities or {}
  if #ids < 2 then
    return nil
  end

  local labels = {}
  for i, id in ipairs(ids) do
    -- vault_identity_list entries look like `dev@~/.dev_pass`; only the label
    -- goes to --encrypt-vault-id.
    table.insert(labels, ("%d. %s"):format(i, id:match("^([^@]+)") or id))
  end

  local choice = vim.fn.inputlist(vim.list_extend({ "Encrypt with which vault id?" }, labels))
  if choice < 1 or choice > #ids then
    return nil
  end

  return ids[choice]:match("^([^@]+)") or ids[choice]
end

---Reads the whole buffer as one string.
---@param buf integer
---@return string
local function buffer_text(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n") .. "\n"
end

---True when the buffer holds a vault-encrypted document.
---@param buf integer
---@return boolean
local function is_encrypted(buf)
  local first = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
  return first ~= nil and first:match("^%$ANSIBLE_VAULT") ~= nil
end

---Forgets what ansible-config said, for when ansible.cfg changes mid-session.
function M.reload()
  resolved_cache = {}
end

---Describes where the password will come from, without using it.
---@return string
function M.status()
  local cwd = vim.fn.getcwd()
  local resolved, err = vault_config.resolve(cwd)
  if not resolved then
    return ("ansible-vault.nvim: %s"):format(err)
  end
  return ("ansible-vault.nvim: %s"):format(vault_config.describe(resolved))
end

--- Buffer options that keep plaintext from being written anywhere.
---
--- This matters more than it looks. This configuration enables 'undofile'
--- globally, so without these a decrypted secret would be persisted verbatim
--- to stdpath("state")/undo the moment the buffer is edited — a plaintext copy
--- of the vault, surviving reboots, that nobody thinks to look for.
---@param buf integer
local function harden_buffer(buf)
  vim.bo[buf].undofile = false
  vim.bo[buf].swapfile = false
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].buflisted = false
end

---Finds the `!vault` block the cursor is inside or immediately above.
---@param buf integer
---@param lnum integer 1-indexed
---@return table|nil { first, last, indent, ciphertext, key }
local function block_at(buf, lnum)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  -- Walk up to the `!vault` marker, then down over the indented body.
  local start
  for i = math.min(lnum, #lines), 1, -1 do
    if lines[i]:match("!vault") then
      start = i
      break
    end
    -- A non-indented, non-empty line means we left the block.
    if i < lnum and lines[i]:match("^%S") and not lines[i]:match("^%s*$") then
      break
    end
  end

  if not start then
    return nil
  end

  local body_indent
  local last = start
  local ciphertext = {}

  for i = start + 1, #lines do
    local indent, content = lines[i]:match("^(%s+)(%S.*)$")
    if not indent then
      break
    end
    if not body_indent then
      body_indent = #indent
    elseif #indent < body_indent then
      break
    end
    table.insert(ciphertext, content)
    last = i
  end

  if #ciphertext == 0 or not ciphertext[1]:match("^%$ANSIBLE_VAULT") then
    return nil
  end

  return {
    first = start,
    last = last,
    indent = lines[start]:match("^(%s*)") or "",
    key = lines[start]:match("^%s*([%w_%-%.]+)%s*:"),
    ciphertext = table.concat(ciphertext, "\n"),
  }
end

---Shows plaintext in a scratch float that is never written anywhere.
---@param plaintext string
---@param title string
local function show(plaintext, title)
  local lines = vim.split(plaintext:gsub("\n$", ""), "\n", { plain = true })
  local buf = vim.api.nvim_create_buf(false, true)

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  harden_buffer(buf)
  vim.bo[buf].modifiable = false

  local width = 0
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = math.min(math.max(width + 2, 24), vim.o.columns - 4),
    height = math.min(#lines, 12),
    style = "minimal",
    border = "rounded",
    title = (" %s "):format(title),
  })

  vim.wo[win].winhighlight = "NormalFloat:NormalFloat"

  for _, key in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", key, function()
      vim.api.nvim_win_close(win, true)
    end, { buffer = buf, nowait = true, desc = "Close" })
  end
end

---Reveals the encrypted value under the cursor, without touching the file.
function M.reveal()
  local buf = vim.api.nvim_get_current_buf()
  local block = block_at(buf, vim.api.nvim_win_get_cursor(0)[1])

  if not block then
    vim.notify("No !vault block under the cursor", vim.log.levels.WARN)
    return
  end

  local auth, err = auth_for()
  if not auth then
    if err ~= "cancelled" then
      vim.notify(err, vim.log.levels.ERROR)
    end
    return
  end

  local plaintext, decrypt_err = cli.decrypt_string(block.ciphertext, { auth = auth, cwd = auth.cwd })
  if not plaintext then
    vim.notify(decrypt_err, vim.log.levels.ERROR)
    return
  end

  show(plaintext, block.key or "vault")
end

---Encrypts the visual selection in place, as an inline `!vault` value.
function M.encrypt_selection()
  local buf = vim.api.nvim_get_current_buf()

  -- '< and '> are only set once the selection has been left, which is the case
  -- by the time a command or <cmd> mapping runs.
  local first = vim.fn.line("'<")
  local last = vim.fn.line("'>")
  if first == 0 then
    vim.notify("No visual selection", vim.log.levels.WARN)
    return
  end

  local lines = vim.api.nvim_buf_get_lines(buf, first - 1, last, false)
  local plaintext = table.concat(lines, "\n")

  -- A `key: value` selection is encrypted as that key, so the result drops
  -- straight back in place.
  local key, value = plaintext:match("^%s*([%w_%-%.]+)%s*:%s*(.*)$")
  local indent = lines[1]:match("^(%s*)") or ""

  local auth, err = auth_for()
  if not auth then
    if err ~= "cancelled" then
      vim.notify(err, vim.log.levels.ERROR)
    end
    return
  end

  local out, encrypt_err = cli.encrypt_string(key and value or plaintext, {
    auth = auth,
    cwd = auth.cwd,
    name = key,
  })
  if not out then
    vim.notify(encrypt_err, vim.log.levels.ERROR)
    return
  end

  -- ansible-vault indents its output for a top-level key; re-indent to wherever
  -- the value actually sits.
  local replacement = {}
  for i, line in ipairs(out) do
    table.insert(replacement, i == 1 and (indent .. line) or (indent .. line:gsub("^%s+", "    ")))
  end

  vim.api.nvim_buf_set_lines(buf, first - 1, last, false, replacement)
  vim.notify(("Encrypted %s"):format(key or "selection"), vim.log.levels.INFO)
end

--- Keeps a decrypted document from being written anywhere except back into the
--- vault. The buffer stays a real file buffer so `:w` still means what it
--- normally means; what changes is that nothing persists in clear.
---@param buf integer
local function harden_file_buffer(buf)
  vim.bo[buf].undofile = false
  vim.bo[buf].swapfile = false
  -- 'backup' and 'writebackup' are global-local; setting them buffer-locally
  -- stops a plaintext copy being left beside the vault while it is written.
  vim.bo[buf].modeline = false
  vim.b[buf].ansible_vault_plain = true
end

---Encrypts the whole current buffer and writes the ciphertext to its file.
function M.encrypt_file()
  local buf = vim.api.nvim_get_current_buf()

  if is_encrypted(buf) then
    vim.notify("Buffer is already encrypted", vim.log.levels.WARN)
    return
  end

  local auth, err = auth_for()
  if not auth then
    if err ~= "cancelled" then
      vim.notify(err, vim.log.levels.ERROR)
    end
    return
  end

  local ciphertext, encrypt_err = cli.encrypt_document(buffer_text(buf), {
    auth = auth,
    cwd = auth.cwd,
    encrypt_identity = encrypt_identity_for(auth),
  })
  if not ciphertext then
    vim.notify(encrypt_err, vim.log.levels.ERROR)
    return
  end

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(ciphertext:gsub("\n$", ""), "\n"))
  vim.b[buf].ansible_vault_plain = nil
  vim.notify("Encrypted buffer — write it to persist", vim.log.levels.INFO)
end

---Decrypts the whole current buffer in place, leaving it unsaved.
function M.decrypt_file()
  local buf = vim.api.nvim_get_current_buf()

  if not is_encrypted(buf) then
    vim.notify("Buffer is not vault-encrypted", vim.log.levels.WARN)
    return
  end

  local auth, err = auth_for()
  if not auth then
    if err ~= "cancelled" then
      vim.notify(err, vim.log.levels.ERROR)
    end
    return
  end

  local plaintext, decrypt_err = cli.decrypt_document(buffer_text(buf), { auth = auth, cwd = auth.cwd })
  if not plaintext then
    vim.notify(decrypt_err, vim.log.levels.ERROR)
    return
  end

  harden_file_buffer(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(plaintext:gsub("\n$", ""), "\n"))
  vim.notify("Decrypted buffer — it will be re-encrypted on write", vim.log.levels.INFO)
end

---Opens an encrypted file's contents read-only, without altering the buffer.
function M.view_file()
  local buf = vim.api.nvim_get_current_buf()

  if not is_encrypted(buf) then
    vim.notify("Buffer is not vault-encrypted", vim.log.levels.WARN)
    return
  end

  local auth, err = auth_for()
  if not auth then
    if err ~= "cancelled" then
      vim.notify(err, vim.log.levels.ERROR)
    end
    return
  end

  local plaintext, decrypt_err = cli.decrypt_document(buffer_text(buf), { auth = auth, cwd = auth.cwd })
  if not plaintext then
    vim.notify(decrypt_err, vim.log.levels.ERROR)
    return
  end

  show(plaintext, vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":t"))
end

---Re-encrypts the current file with a different password.
function M.rekey_file()
  local buf = vim.api.nvim_get_current_buf()
  local path = vim.api.nvim_buf_get_name(buf)

  if path == "" or not is_encrypted(buf) then
    vim.notify("Current buffer is not a saved, vault-encrypted file", vim.log.levels.WARN)
    return
  end

  if vim.bo[buf].modified then
    vim.notify("Save the buffer first — rekey works on the file", vim.log.levels.WARN)
    return
  end

  local auth, err = auth_for()
  if not auth then
    if err ~= "cancelled" then
      vim.notify(err, vim.log.levels.ERROR)
    end
    return
  end

  local new_password = vim.fn.inputsecret("New vault password: ")
  if new_password == "" then
    return
  end

  -- The new password needs a file of its own, staged the same way as a typed
  -- password: tmpfs, 0600, removed immediately.
  local staged, cleanup, stage_err = require("ansible-vault.cli").stage_password_for_rekey(new_password)
  if not staged then
    vim.notify(stage_err, vim.log.levels.ERROR)
    return
  end

  local ok, rekey_err = cli.rekey(path, {
    auth = auth,
    cwd = auth.cwd,
    new_password_file = staged,
  })
  cleanup()

  if not ok then
    vim.notify(rekey_err, vim.log.levels.ERROR)
    return
  end

  vim.cmd.edit({ bang = true })
  vim.notify("Rekeyed " .. vim.fn.fnamemodify(path, ":t"), vim.log.levels.INFO)
end

---Decrypts vault files as they are opened and re-encrypts them on write.
local function enable_transparent_editing()
  local group = vim.api.nvim_create_augroup("ansible_vault_transparent", { clear = true })

  -- Forward declaration: the reader attaches the writer once a buffer has
  -- actually been decrypted.
  local attach_writer

  vim.api.nvim_create_autocmd("BufReadPost", {
    group = group,
    callback = function(ev)
      -- The decision is made on what the buffer actually holds, not on a flag
      -- set earlier. `:edit!` on a decrypted buffer reloads the ciphertext from
      -- disk while the flag is still set, and keying off the flag left the user
      -- staring at base64 with no way back. Found by reloading during testing.
      if not is_encrypted(ev.buf) then
        return
      end

      -- Harden before the plaintext exists, not after: 'undofile' is consulted
      -- when the undo file is written, but there is no reason to leave a window
      -- in which it is still true.
      harden_file_buffer(ev.buf)

      local auth, err = auth_for()
      if not auth then
        vim.b[ev.buf].ansible_vault_plain = nil
        if err ~= "cancelled" then
          vim.notify(err, vim.log.levels.ERROR)
        end
        return
      end

      local plaintext, decrypt_err = cli.decrypt_document(buffer_text(ev.buf), { auth = auth, cwd = auth.cwd })
      if not plaintext then
        vim.b[ev.buf].ansible_vault_plain = nil
        vim.notify(decrypt_err, vim.log.levels.ERROR)
        return
      end

      vim.api.nvim_buf_set_lines(ev.buf, 0, -1, false, vim.split(plaintext:gsub("\n$", ""), "\n"))
      vim.bo[ev.buf].modified = false
      attach_writer(ev.buf)

      -- Filetype was detected against ciphertext, so it is worth another look
      -- now that the buffer holds YAML.
      vim.cmd("filetype detect")
    end,
  })

  -- Registered per buffer, at the moment that buffer is decrypted.
  --
  -- An earlier version attached this to every buffer and fell back to an
  -- ordinary write for the rest. That intercepts every `:write` in the editor,
  -- and it broke immediately: writing a scratch buffer produced an error from
  -- inside this plugin. A BufWriteCmd is a takeover of the write command; it
  -- has no business existing on buffers this plugin does not own.
  ---@param buf integer
  attach_writer = function(buf)
    vim.api.nvim_create_autocmd("BufWriteCmd", {
      group = group,
      buffer = buf,
      callback = function(ev)
        if not vim.b[ev.buf].ansible_vault_plain then
          -- The buffer was decrypted once but is no longer ours — for instance
          -- :VaultEncryptFile re-encrypted it. Write it verbatim.
          local path = vim.api.nvim_buf_get_name(ev.buf)
          vim.fn.writefile(vim.api.nvim_buf_get_lines(ev.buf, 0, -1, false), path)
          vim.bo[ev.buf].modified = false
          return
        end

        local auth, err = auth_for()
        if not auth then
          vim.notify(err or "cancelled", vim.log.levels.ERROR)
          return
        end

        local ciphertext, encrypt_err = cli.encrypt_document(buffer_text(ev.buf), {
          auth = auth,
          cwd = auth.cwd,
          encrypt_identity = encrypt_identity_for(auth),
        })
        if not ciphertext then
          vim.notify(encrypt_err, vim.log.levels.ERROR)
          return
        end

        local path = vim.api.nvim_buf_get_name(ev.buf)
        local fd = vim.uv.fs_open(path, "w", tonumber("600", 8))
        if not fd then
          vim.notify("Could not write " .. path, vim.log.levels.ERROR)
          return
        end
        vim.uv.fs_write(fd, ciphertext)
        vim.uv.fs_close(fd)

        vim.bo[ev.buf].modified = false
        vim.notify(("Encrypted and wrote %s"):format(vim.fn.fnamemodify(path, ":t")), vim.log.levels.INFO)
      end,
    })
  end
end

---@param opts ansible_vault.Opts|nil
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})

  vim.api.nvim_create_user_command("VaultReveal", M.reveal, {
    desc = "Reveal the encrypted value under the cursor",
  })

  vim.api.nvim_create_user_command("VaultEncrypt", M.encrypt_selection, {
    desc = "Encrypt the visual selection as an inline vault value",
    range = true,
  })

  vim.api.nvim_create_user_command("VaultStatus", function()
    vim.notify(M.status(), vim.log.levels.INFO)
  end, { desc = "Show where the vault password comes from" })

  vim.api.nvim_create_user_command("VaultReload", M.reload, {
    desc = "Re-read ansible.cfg for vault settings",
  })

  vim.api.nvim_create_user_command("VaultEncryptFile", M.encrypt_file, {
    desc = "Encrypt the whole buffer",
  })

  vim.api.nvim_create_user_command("VaultDecryptFile", M.decrypt_file, {
    desc = "Decrypt the whole buffer in place",
  })

  vim.api.nvim_create_user_command("VaultView", M.view_file, {
    desc = "View an encrypted file without decrypting the buffer",
  })

  vim.api.nvim_create_user_command("VaultRekey", M.rekey_file, {
    desc = "Re-encrypt this file with a new password",
  })

  if M.options.transparent then
    enable_transparent_editing()
  end

  if M.options.keymaps then
    vim.keymap.set("n", "<leader>av", M.reveal, { desc = "Reveal vault value" })
    vim.keymap.set("x", "<leader>av", ":VaultEncrypt<cr>", { desc = "Encrypt selection" })
    vim.keymap.set("n", "<leader>aV", "<cmd>VaultStatus<cr>", { desc = "Vault password source" })
    vim.keymap.set("n", "<leader>ae", "<cmd>VaultEncryptFile<cr>", { desc = "Encrypt whole file" })
    vim.keymap.set("n", "<leader>ad", "<cmd>VaultDecryptFile<cr>", { desc = "Decrypt whole file" })
    vim.keymap.set("n", "<leader>aw", "<cmd>VaultView<cr>", { desc = "View encrypted file" })
    vim.keymap.set("n", "<leader>ak", "<cmd>VaultRekey<cr>", { desc = "Rekey encrypted file" })
  end
end

return M
