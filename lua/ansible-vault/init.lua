-- ansible-vault.nvim — Ansible Vault inside the editor.
-- What is kept off disk and what is not: :help devops-nvim-vault.

local cli = require("ansible-vault.cli")
local vault_config = require("ansible-vault.config")
local fs = require("ansible-vault.fs")

local M = {}

---@class ansible_vault.Opts
---@field keymaps boolean|nil      create the default <leader>a mappings
---@field transparent boolean|nil  decrypt vault files on open, re-encrypt on write
local defaults = {
  keymaps = false,
  transparent = true,
}

M.options = vim.deepcopy(defaults)

--- Cached per directory: ansible-config takes ~200ms and only changes with ansible.cfg.
local resolved_cache = {}

--- The directory whose ansible.cfg applies to a buffer — not Neovim's cwd, which
--- may belong to an entirely different project.
---@param buf integer|nil
---@return string
local function context_dir(buf)
  local name = vim.api.nvim_buf_get_name(buf or 0)
  if name == "" then
    return vim.fn.getcwd()
  end

  local start = vim.fs.dirname(name)
  local found = vim.fs.find("ansible.cfg", { path = start, upward = true, type = "file" })[1]
  return found and vim.fs.dirname(found) or start
end

--- Takes a BUFFER, not a directory; passing a directory reaches vim.system as a bad cwd.
---@param buf integer|nil
---@return ansible_vault.Auth|nil, string|nil err
local function auth_for(buf)
  local cwd = context_dir(buf)

  if resolved_cache[cwd] == nil then
    local resolved, err = vault_config.resolve(cwd)
    if not resolved then
      return nil, err
    end
    resolved_cache[cwd] = resolved
  end

  local resolved = resolved_cache[cwd]

  if resolved.password_file or #resolved.identities > 0 then
    -- No credential arguments: ansible reads them from ansible.cfg, and repeating
    -- them registers a second identity under the same label, which ansible refuses.
    return {
      cwd = cwd,
      -- NOT `identities`, which cli.auth_args would turn into --vault-id arguments.
      configured_identities = resolved.identities,
      encrypt_identity = resolved.encrypt_identity,
    }
  end

  local password = vim.fn.inputsecret("Vault password: ")
  if password == "" then
    return nil, "cancelled"
  end

  -- cwd matters here too: without it ansible runs in Neovim's directory and the
  -- wrong ansible.cfg applies.
  return { password = password, cwd = cwd }
end

---Which identity to encrypt with; ansible refuses to guess when several are configured.
---
---Answering "no identity is needed" and "the user cancelled" with the same `nil` made
---dismissing the list encrypt with the default instead of stopping, so the two are
---separate return values.
---@param auth ansible_vault.Auth
---@return string|nil identity  what to pass as --encrypt-vault-id, nil when unnecessary
---@return boolean proceed      false when the choice was dismissed
local function encrypt_identity_for(auth)
  if auth.encrypt_identity then
    return auth.encrypt_identity, true
  end

  local ids = auth.configured_identities or {}
  if #ids < 2 then
    return nil, true
  end

  local labels = {}
  for i, id in ipairs(ids) do
    -- Entries look like `dev@~/.dev_pass`; only the label goes to --encrypt-vault-id.
    table.insert(labels, ("%d. %s"):format(i, id:match("^([^@]+)") or id))
  end

  local choice = vim.fn.inputlist(vim.list_extend({ "Encrypt with which vault id?" }, labels))
  if choice < 1 or choice > #ids then
    return nil, false
  end

  return ids[choice]:match("^([^@]+)") or ids[choice], true
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

---The first line of a file, or nil if it cannot be read.
---@param path string
---@return string|nil
local function first_line(path)
  local ok, lines = pcall(vim.fn.readfile, path, "", 1)
  if not ok or type(lines) ~= "table" then
    return nil
  end
  return lines[1]
end

---True when the FILE ON DISK is a vault; under transparent editing the buffer is not.
---@param path string
---@return boolean
local function file_is_vault(path)
  local first = first_line(path)
  return first ~= nil and first:match("^%$ANSIBLE_VAULT") ~= nil
end

---The vault id from a 1.2 header (`$ANSIBLE_VAULT;1.2;AES256;prod`); nil for 1.1.
---@param path string
---@return string|nil
local function vault_label(path)
  local first = first_line(path)
  if not first then
    return nil
  end
  return first:match("^%$ANSIBLE_VAULT;[^;]+;[^;]+;(.+)$")
end

---Forgets what ansible-config said, for when ansible.cfg changes mid-session.
function M.reload()
  resolved_cache = {}
end

---Describes where the password will come from, without using it.
---@return string
function M.status()
  local cwd = context_dir()
  local resolved, err = vault_config.resolve(cwd)
  if not resolved then
    return ("ansible-vault.nvim: %s"):format(err)
  end
  return ("ansible-vault.nvim: %s"):format(vault_config.describe(resolved))
end

--- A scratch buffer holding plaintext: nothing about it is written anywhere.
---@param buf integer
local function harden_buffer(buf)
  vim.bo[buf].undofile = false
  vim.bo[buf].swapfile = false
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].buflisted = false
end

---Finds the `!vault` block the cursor is in: its marker line or the indented body.
---@param buf integer
---@param lnum integer 1-indexed
---@return table|nil { first, last, indent, ciphertext, key }
local function block_at(buf, lnum)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  -- Up to the `!vault` marker. The `i < lnum` exception lets the cursor sit on
  -- that marker line, which is itself unindented.
  local start
  for i = math.min(lnum, #lines), 1, -1 do
    if lines[i]:match("!vault") then
      start = i
      break
    end
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

  -- Without this the scan's own exception let the first line after a block match it.
  if lnum < start or lnum > last then
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

  local auth, err = auth_for(buf)
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

---Encrypts a range of lines in place, as an inline `!vault` value.
---@param opts table|nil the user-command options; requires a range
function M.encrypt_selection(opts)
  local buf = vim.api.nvim_get_current_buf()

  -- From the command's range, never the '< '> marks: those outlive their selection
  -- and would encrypt whatever was selected last, somewhere else in the file.
  if not opts or (opts.range or 0) == 0 then
    vim.notify("VaultEncrypt needs a range — select the lines first, or use :N,MVaultEncrypt", vim.log.levels.WARN)
    return
  end

  local first = opts.line1
  local last = opts.line2

  local lines = vim.api.nvim_buf_get_lines(buf, first - 1, last, false)
  local plaintext = table.concat(lines, "\n")

  -- A `key: value` selection is encrypted as that key, so the result drops back in place.
  local key, value = plaintext:match("^%s*([%w_%-%.]+)%s*:%s*(.*)$")
  local indent = lines[1]:match("^(%s*)") or ""

  local auth, err = auth_for(buf)
  if not auth then
    if err ~= "cancelled" then
      vim.notify(err, vim.log.levels.ERROR)
    end
    return
  end

  -- The same question the whole-file paths ask: with several configured identities
  -- ansible refuses to guess, and an inline value is no different.
  local identity, proceed = encrypt_identity_for(auth)
  if not proceed then
    return
  end

  local out, encrypt_err = cli.encrypt_string(key and value or plaintext, {
    auth = auth,
    cwd = auth.cwd,
    name = key,
    encrypt_identity = identity,
  })
  if not out then
    vim.notify(encrypt_err, vim.log.levels.ERROR)
    return
  end

  -- ansible-vault indents for a top-level key; re-indent to where the value sits.
  local replacement = {}
  for i, line in ipairs(out) do
    table.insert(replacement, i == 1 and (indent .. line) or (indent .. line:gsub("^%s+", "    ")))
  end

  vim.api.nvim_buf_set_lines(buf, first - 1, last, false, replacement)
  vim.notify(("Encrypted %s"):format(key or "selection"), vim.log.levels.INFO)
end

--- What the file looked like when it was read. Nanoseconds, inode and device as well
--- as size: same-second writes of equal length are otherwise indistinguishable.
---@param path string
---@return table|nil
local function file_fingerprint(path)
  local stat = vim.uv.fs_stat(path)
  if not stat then
    return nil
  end

  return {
    mtime_sec = stat.mtime.sec,
    mtime_nsec = stat.mtime.nsec,
    size = stat.size,
    ino = stat.ino,
    dev = stat.dev,
  }
end

---@param buf integer
local function remember_file_state(buf)
  -- Three states, not two. "There was no file" is something this plugin looked at
  -- and knows; storing nil for it is indistinguishable from never having looked,
  -- and the check below reads that as nothing to protect.
  local fingerprint = file_fingerprint(vim.api.nvim_buf_get_name(buf))
  vim.b[buf].ansible_vault_stat = fingerprint or { absent = true }
end

---@param buf integer
---@return string|nil description of the change
local function file_changed_since_read(buf)
  local remembered = vim.b[buf].ansible_vault_stat
  if not remembered then
    return nil
  end

  local current = file_fingerprint(vim.api.nvim_buf_get_name(buf))

  if remembered.absent then
    -- `:write` on a buffer whose file never existed is Neovim's E13, and E13 tells
    -- you to add `!`. The bang overrides Neovim's checks, not this one.
    if current then
      return "a file has appeared on disk since this buffer was converted"
    end
    return nil
  end

  if not current then
    return "the file has been removed"
  end

  if current.ino ~= remembered.ino or current.dev ~= remembered.dev then
    return "the file has been replaced on disk since it was read"
  end

  if
    current.mtime_sec ~= remembered.mtime_sec
    or current.mtime_nsec ~= remembered.mtime_nsec
    or current.size ~= remembered.size
  then
    return "the file has changed on disk since it was read"
  end

  return nil
end

--- Resolves symlinks and refuses a file another name also points at. Every operation
--- that replaces a vault asks this, because each breaks the other names differently.
---@param path string
---@return string|nil target the resolved path, nil when the file has other names
---@return string|nil err
local function check_hardlinks(path)
  local target = vim.uv.fs_realpath(path) or path
  local stat = vim.uv.fs_stat(target)

  if stat and (stat.nlink or 1) > 1 then
    return nil, ("%s has %d hard links"):format(target, stat.nlink)
  end

  return target
end

--- Replaces a file without ever leaving it truncated: sibling temp file, then rename.
---Puts a directory's own entries on the disk, which is what makes a rename durable.
---@param dir string
---@return boolean synced, string|nil err
local function sync_directory(dir)
  -- Read-only is how a directory is opened for this; there is nothing to write to it.
  local fd, open_err = vim.uv.fs_open(dir, "r", tonumber("500", 8))
  if not fd then
    return false, open_err or "could not be opened"
  end

  local synced, sync_err = vim.uv.fs_fsync(fd)
  vim.uv.fs_close(fd)

  if synced == nil then
    return false, sync_err or "fsync failed"
  end

  return true
end

---@param path string
---@param contents string
---@return boolean ok, string|nil err
local function write_atomically(path, contents)
  -- rename() replaces exactly the name it is given: a symlink becomes a regular file
  -- and the real vault stays stale, and other hard links keep the old contents.
  local target, link_err = check_hardlinks(path)
  if not target then
    return false,
      ("%s, and replacing it atomically would update only this name. "):format(link_err)
        .. "Remove the other links, or use :saveas to write somewhere else."
  end

  -- `wx` refuses to reuse an existing name, so the name must not repeat: one built
  -- from the pid alone comes back after a crash once that pid is reused, and every
  -- write of this vault then fails with EEXIST for the life of the process. Same
  -- pid-and-hrtime pair the staged password and the terraform plans use.
  local tmp = ("%s.ansible-vault.nvim.%d.%d.tmp"):format(target, vim.uv.os_getpid(), vim.uv.hrtime())

  local fd, open_err = vim.uv.fs_open(tmp, "wx", tonumber("600", 8))
  if not fd then
    return false, ("could not create %s: %s"):format(tmp, open_err or "unknown error")
  end

  ---Adds the temporary file to a failure the caller is already reporting, when it
  ---could not be taken away with it.
  ---@param message string
  ---@return string
  local function with_leftover(message)
    local removed, unlink_err = fs.unlink_checked(tmp)
    if removed then
      return message
    end

    return ("%s.\nThe temporary copy could not be removed either (%s). It holds ciphertext, "):format(
      message,
      unlink_err
    ) .. ("not plaintext, and can be deleted:\n%s"):format(tmp)
  end

  local function fail(message)
    vim.uv.fs_close(fd)
    return false, with_leftover(message)
  end

  local written, write_err = vim.uv.fs_write(fd, contents)
  if not written then
    return fail(write_err or "write failed")
  end
  if written < #contents then
    return fail(("short write: %d of %d bytes"):format(written, #contents))
  end

  -- Or the rename can land before the data, leaving an empty file where a vault was.
  local synced, sync_err = vim.uv.fs_fsync(fd)
  if synced == nil then
    return fail(sync_err or "fsync failed")
  end

  local closed, close_err = vim.uv.fs_close(fd)
  if not closed then
    return false, with_leftover(close_err or "close failed")
  end

  local renamed, rename_err = vim.uv.fs_rename(tmp, target)
  if not renamed then
    return false, with_leftover(rename_err or "rename failed")
  end

  -- The rename is atomic, but the directory entry it changed is not on the disk
  -- until the directory itself is synced: a power cut in between can leave the
  -- old name. Said out loud rather than returned as a failure — the vault is in
  -- place, there is nothing to undo, and "could not write" would be false.
  local durable, durability_err = sync_directory(vim.fs.dirname(target))
  if not durable then
    vim.notify(
      ("Wrote %s, but the change could not be confirmed as on-disk (%s).\n"):format(
        vim.fn.fnamemodify(target, ":t"),
        durability_err
      ) .. "The file is in place; a crash or power cut before the filesystem flushes could still lose it.",
      vim.log.levels.WARN
    )
  end

  return true
end

--- Keeps what attaches to a plaintext buffer out of the way of the write hook's group.
local tools_group = vim.api.nvim_create_augroup("ansible_vault_tools", { clear = true })

--- Stops a file buffer persisting its contents, whether it currently holds plaintext
--- or the ciphertext it was just converted into. 'backup' and 'writebackup' are global
--- options and cannot be set here; M.attach_writer is what takes their place.
---@param buf integer
local function harden_sensitive_buffer(buf)
  vim.bo[buf].undofile = false
  vim.bo[buf].swapfile = false
  vim.bo[buf].modeline = false
end

--- Language servers that attached to a buffer now holding plaintext are stopped
--- for it. A decrypted vault looks like ordinary YAML once its filetype is
--- detected, and a server is handed the whole buffer on didOpen — see
--- :help devops-nvim-vault-tools for what this does and does not close.
---@param buf integer
local function detach_language_servers(buf)
  for _, client in ipairs(vim.lsp.get_clients({ bufnr = buf })) do
    pcall(vim.lsp.buf_detach_client, buf, client.id)
  end
end

--- Detaches gitsigns, which stages buffer contents into `.git/index` and a blob
--- object rather than into the working tree — past everything guarding the file.
---@param buf integer
local function detach_gitsigns(buf)
  local ok, gitsigns = pcall(require, "gitsigns")
  if ok then
    pcall(gitsigns.detach, buf)
  end
end

--- Keeps the tools that would copy a buffer elsewhere off it for as long as it
--- holds plaintext. Setting the filetype is what invites language servers, so
--- this has to survive that and anything later that tries again.
---@param buf integer
local function keep_language_servers_off(buf)
  detach_language_servers(buf)
  detach_gitsigns(buf)

  pcall(vim.api.nvim_clear_autocmds, { group = tools_group, event = "LspAttach", buffer = buf })
  vim.api.nvim_create_autocmd("LspAttach", {
    group = tools_group,
    buffer = buf,
    callback = function(ev)
      if not vim.b[ev.buf].ansible_vault_plain then
        return
      end
      pcall(vim.lsp.buf_detach_client, ev.buf, ev.data.client_id)
    end,
  })
end

--- Removes the undo file for a path. Turning 'undofile' off stops new ones appearing;
--- it does not remove one already holding every earlier state of the buffer.
---@param path string
---@return boolean ok, string|nil err
local function remove_persistent_undo(path)
  local undo = vim.fn.undofile(path)
  if undo == "" or not vim.uv.fs_stat(undo) then
    return true
  end

  local ok, err = vim.uv.fs_unlink(undo)
  if not ok then
    return false, err or "could not remove the persistent undo file"
  end

  return true
end

---Converts a plaintext buffer into a vault, in place.
---
---Ordered so no step leaves the buffer half-converted: encryption first, because
---everything after it is destructive; then hardening, the undo file, the remembered
---state and the writer; only then the buffer itself. See
---:help devops-nvim-vault-conversion.
function M.encrypt_file()
  local buf = vim.api.nvim_get_current_buf()

  if is_encrypted(buf) then
    vim.notify("Buffer is already encrypted", vim.log.levels.WARN)
    return
  end

  local auth, err = auth_for(buf)
  if not auth then
    if err ~= "cancelled" then
      vim.notify(err, vim.log.levels.ERROR)
    end
    return
  end

  local identity, proceed = encrypt_identity_for(auth)
  if not proceed then
    return
  end

  local ciphertext, encrypt_err = cli.encrypt_document(buffer_text(buf), {
    auth = auth,
    cwd = auth.cwd,
    encrypt_identity = identity,
  })
  if not ciphertext then
    vim.notify(encrypt_err, vim.log.levels.ERROR)
    return
  end

  -- Nothing above has changed anything; everything below completes or leaves the
  -- buffer as it was.
  local path = vim.api.nvim_buf_get_name(buf)

  harden_sensitive_buffer(buf)

  if path ~= "" then
    local removed, undo_err = remove_persistent_undo(path)
    if not removed then
      vim.notify(
        ("Conversion aborted: the existing persistent undo file could not be removed: %s\n"):format(undo_err)
          .. "It holds this file's plaintext. Persistent undo stays disabled for this buffer.",
        vim.log.levels.ERROR
      )
      return
    end

    remember_file_state(buf)

    -- Ciphertext with no safe way to write it is worse than a buffer never converted.
    local attached, writer_err = pcall(M.attach_writer, buf)
    if not attached then
      vim.notify(
        ("Conversion aborted: the safe writer could not be installed: %s"):format(writer_err),
        vim.log.levels.ERROR
      )
      return
    end
  end

  -- An unnamed buffer has no file to guard; hardening above is what still applies.
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(ciphertext:gsub("\n$", ""), "\n"))
  vim.b[buf].ansible_vault_plain = nil
  vim.notify("Encrypted buffer — write it to persist", vim.log.levels.INFO)
end

---Decrypts the whole current buffer in place, leaving it unsaved.
---
---Ordered so the plaintext is the last thing to appear: hardening, then the
---writer, and only then the contents it protects. See
---:help devops-nvim-vault-transparent.
function M.decrypt_file()
  local buf = vim.api.nvim_get_current_buf()

  if not is_encrypted(buf) then
    vim.notify("Buffer is not vault-encrypted", vim.log.levels.WARN)
    return
  end

  harden_sensitive_buffer(buf)

  local auth, err = auth_for(buf)
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

  remember_file_state(buf)

  -- Not optional: without the writer, `:w` replaces the vault with its cleartext.
  local attached, writer_err = pcall(M.attach_writer, buf)
  if not attached then
    vim.notify(
      ("Refusing to decrypt: the safe writer could not be installed: %s"):format(writer_err),
      vim.log.levels.ERROR
    )
    return
  end

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(plaintext:gsub("\n$", ""), "\n"))
  vim.b[buf].ansible_vault_plain = true
  keep_language_servers_off(buf)

  vim.notify("Decrypted buffer — it will be re-encrypted on write", vim.log.levels.INFO)
end

---Opens an encrypted file's contents read-only, without altering the buffer.
function M.view_file()
  local buf = vim.api.nvim_get_current_buf()

  if not is_encrypted(buf) then
    vim.notify("Buffer is not vault-encrypted", vim.log.levels.WARN)
    return
  end

  local auth, err = auth_for(buf)
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

---Which configured identity to rekey into. `--new-vault-id` needs the whole
---`label@source` entry; a bare label is read as a password file path.
---@param ids string[] entries from vault_identity_list
---@param current string|nil the label the file currently uses
---@return string|nil entry, string|nil label
local function choose_new_identity(ids, current)
  local labels = {}
  for i, id in ipairs(ids) do
    local label = id:match("^([^@]+)") or id
    table.insert(labels, ("%d. %s%s"):format(i, label, label == current and "  (current)" or ""))
  end

  local choice = vim.fn.inputlist(vim.list_extend({ "Rekey to which vault id?" }, labels))
  if choice < 1 or choice > #ids then
    return nil, nil
  end

  return ids[choice], ids[choice]:match("^([^@]+)") or ids[choice]
end

---Re-encrypts the current file under a different configured vault id.
---
---The new password must outlive this command: rekeying to one typed once leaves a
---file ansible cannot open again. See :help devops-nvim-vault-rekey.
function M.rekey_file()
  local buf = vim.api.nvim_get_current_buf()
  local path = vim.api.nvim_buf_get_name(buf)

  if path == "" then
    vim.notify("Rekey works on a saved file — this buffer has no name", vim.log.levels.WARN)
    return
  end

  if vim.bo[buf].modified then
    vim.notify("Save the buffer first — rekey works on the file", vim.log.levels.WARN)
    return
  end

  -- The file, not the buffer: under transparent editing the buffer holds plaintext.
  if not file_is_vault(path) then
    vim.notify("The file on disk is not vault-encrypted", vim.log.levels.WARN)
    return
  end

  -- Before anything else, including the prompt: ansible-vault shreds the inode before
  -- unlinking it, so through a hard link the other name is destroyed, not just stale.
  local _, link_err = check_hardlinks(path)
  if link_err then
    vim.notify(
      ("Refusing to rekey: %s. ansible-vault overwrites a file's contents before replacing it, "):format(link_err)
        .. "which would destroy what the other names hold rather than leave them stale. "
        .. "Remove the other links first.",
      vim.log.levels.ERROR
    )
    return
  end

  local auth, err = auth_for(buf)
  if not auth then
    if err ~= "cancelled" then
      vim.notify(err, vim.log.levels.ERROR)
    end
    return
  end

  local ids = auth.configured_identities or {}
  if #ids == 0 then
    vim.notify(
      "Rekey needs a new password that outlives this command.\n"
        .. "Configure vault_identity_list in ansible.cfg and choose the new id here — "
        .. "rekeying to a password typed once would leave this file unopenable.",
      vim.log.levels.ERROR
    )
    return
  end

  local entry, label = choose_new_identity(ids, vault_label(path))
  if not entry then
    return
  end

  local ok, rekey_err = cli.rekey(path, {
    auth = auth,
    cwd = auth.cwd,
    new_identity = entry,
  })

  if not ok then
    vim.notify(rekey_err, vim.log.levels.ERROR)
    return
  end

  -- The ciphertext changed, so the buffer is stale whichever mode it is in.
  vim.cmd.edit({ bang = true })
  vim.notify(("Rekeyed %s to vault id %s"):format(vim.fn.fnamemodify(path, ":t"), label), vim.log.levels.INFO)
end

--- The one way this plugin writes a file: conflict check, atomic replacement,
--- bookkeeping. A second path that skipped all three is why this exists.
---@param buf integer
---@param contents string
---@return boolean ok, string|nil err
local function persist(buf, contents)
  local path = vim.api.nvim_buf_get_name(buf)
  if path == "" then
    return false, "buffer has no file name"
  end

  local changed = file_changed_since_read(buf)
  if changed then
    return false,
      ("%s. Another editor or process has touched it since this buffer was read. "):format(changed)
        .. "Use :edit! to discard your changes and reload, or :saveas to keep them elsewhere."
  end

  local ok, err = write_atomically(path, contents)
  if not ok then
    -- Left modified on purpose: the work is still only in memory.
    return false, err
  end

  vim.bo[buf].modified = false
  -- Our own write moved mtime and size, so the fingerprint moves with it.
  remember_file_state(buf)
  return true
end

--- Separate from the transparent-editing group: a writer must survive `transparent = false`.
local writer_group = vim.api.nvim_create_augroup("ansible_vault_writer", { clear = true })

--- Attaches the write hook to one buffer. A BufWriteCmd is a takeover of `:write`, so
--- it has no business on buffers this plugin does not own.
---@param buf integer
function M.attach_writer(buf)
  -- Cleared first: every `:edit!` decrypts again, and each attach would otherwise stack.
  for _, event in ipairs({ "BufWriteCmd", "FileWriteCmd", "FileAppendCmd" }) do
    pcall(vim.api.nvim_clear_autocmds, {
      group = writer_group,
      event = event,
      buffer = buf,
    })
  end

  -- `:write` is not one command. Writing part of a buffer, or appending, is
  -- FileWriteCmd and FileAppendCmd, and a BufWriteCmd does not cover either — so
  -- taking over `:w` and stopping there leaves `:1,10w elsewhere` to Neovim's own
  -- writer, with whatever the buffer holds. Refused rather than implemented: a
  -- decrypted vault has no partial form, and vaulting a fragment is not what
  -- anyone typing that meant.
  for _, event in ipairs({ "FileWriteCmd", "FileAppendCmd" }) do
    vim.api.nvim_create_autocmd(event, {
      group = writer_group,
      buffer = buf,
      callback = function(ev)
        if not vim.b[ev.buf].ansible_vault_plain then
          -- Ciphertext is public, so writing part of it is ordinary editing. `'[` and
          -- `']` are the range Neovim set for this command.
          local lines = vim.api.nvim_buf_get_lines(ev.buf, vim.fn.line("'[") - 1, vim.fn.line("']"), false)
          if vim.fn.writefile(lines, ev.file, event == "FileAppendCmd" and "a" or "") ~= 0 then
            vim.notify(("Could not write %s"):format(ev.file), vim.log.levels.ERROR)
          end
          return
        end

        vim.notify(
          "Refusing to write part of a decrypted vault to another file: it would be plaintext on disk.\n"
            .. "Write the vault itself, or use :VaultEncryptFile on a buffer of its own.",
          vim.log.levels.ERROR
        )
      end,
    })
  end

  -- The file this buffer may be written back to, fixed now. `:saveas` renames the
  -- buffer before the write runs, so its own name cannot answer that question later.
  vim.b[buf].ansible_vault_path = vim.api.nvim_buf_get_name(buf)

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = writer_group,
    buffer = buf,
    callback = function(ev)
      local name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(ev.buf), ":t")

      -- `:w elsewhere` arrives here with ev.file naming the target rather than this
      -- buffer, and `:saveas elsewhere` renames the buffer before the write, so by
      -- now both it and ev.file are the new name. The vault this buffer was opened
      -- from is the only file it can be written back to; anything else would either
      -- put plaintext there or make a second vault nothing is tracking.
      local vault = vim.b[ev.buf].ansible_vault_path
      local target = ev.file ~= "" and ev.file or vim.api.nvim_buf_get_name(ev.buf)
      if vault and vim.fs.normalize(target) ~= vim.fs.normalize(vault) then
        vim.notify(
          ("Refusing to write %s to %s.\n"):format(vim.fn.fnamemodify(vault, ":t"), vim.fn.fnamemodify(target, ":t"))
            .. "A decrypted vault is written by re-encrypting it into the file it came from, and nothing else.",
          vim.log.levels.ERROR
        )
        return
      end

      -- `:edit!` reloads the ciphertext but keeps buffer variables, and ansible-vault
      -- refuses input that is already encrypted: measured, every `:w` then failed.
      if vim.b[ev.buf].ansible_vault_plain and is_encrypted(ev.buf) then
        vim.b[ev.buf].ansible_vault_plain = nil
      end

      if not vim.b[ev.buf].ansible_vault_plain then
        -- Holds ciphertext already, as after :VaultEncryptFile: written verbatim,
        -- but through the same guarded path.
        local ok, err = persist(ev.buf, buffer_text(ev.buf))
        if not ok then
          vim.notify(("Could not write %s: %s"):format(name, err), vim.log.levels.ERROR)
        end
        return
      end

      local auth, err = auth_for(ev.buf)
      if not auth then
        vim.notify(err or "cancelled", vim.log.levels.ERROR)
        return
      end

      -- Dismissing the list stops the write: the buffer keeps its plaintext and stays
      -- modified, which is the same place `:w` leaves it when anything else refuses.
      local identity, proceed = encrypt_identity_for(auth)
      if not proceed then
        vim.notify(("Not written: no vault id was chosen for %s"):format(name), vim.log.levels.WARN)
        return
      end

      local ciphertext, encrypt_err = cli.encrypt_document(buffer_text(ev.buf), {
        auth = auth,
        cwd = auth.cwd,
        encrypt_identity = identity,
      })
      if not ciphertext then
        vim.notify(encrypt_err, vim.log.levels.ERROR)
        return
      end

      local ok, write_err = persist(ev.buf, ciphertext)
      if not ok then
        vim.notify(("Could not write %s: %s"):format(name, write_err), vim.log.levels.ERROR)
        return
      end

      vim.notify(("Encrypted and wrote %s"):format(name), vim.log.levels.INFO)
    end,
  })
end

---Decrypts vault files as they are opened and re-encrypts them on write.
local function enable_transparent_editing()
  local group = vim.api.nvim_create_augroup("ansible_vault_transparent", { clear = true })

  vim.api.nvim_create_autocmd("BufReadPost", {
    group = group,
    callback = function(ev)
      -- On what the buffer holds, not on a flag: `:edit!` reloads ciphertext with the
      -- flag still set, which used to leave the user staring at base64.
      if not is_encrypted(ev.buf) then
        return
      end

      -- This buffer holds ciphertext right now, whatever an earlier decrypt of it left
      -- set: `:edit!` reloads the file without clearing buffer variables.
      vim.b[ev.buf].ansible_vault_plain = nil

      -- Hardened before the plaintext exists, not after.
      harden_sensitive_buffer(ev.buf)

      local auth, err = auth_for(ev.buf)
      if not auth then
        if err ~= "cancelled" then
          vim.notify(err, vim.log.levels.ERROR)
        end
        return
      end

      local plaintext, decrypt_err = cli.decrypt_document(buffer_text(ev.buf), { auth = auth, cwd = auth.cwd })
      if not plaintext then
        vim.notify(decrypt_err, vim.log.levels.ERROR)
        return
      end

      remember_file_state(ev.buf)

      local attached, writer_err = pcall(M.attach_writer, ev.buf)
      if not attached then
        vim.notify(
          ("Refusing to decrypt %s: the safe writer could not be installed: %s"):format(
            vim.fn.fnamemodify(vim.api.nvim_buf_get_name(ev.buf), ":t"),
            writer_err
          ),
          vim.log.levels.ERROR
        )
        return
      end

      vim.api.nvim_buf_set_lines(ev.buf, 0, -1, false, vim.split(plaintext:gsub("\n$", ""), "\n"))
      vim.b[ev.buf].ansible_vault_plain = true
      vim.bo[ev.buf].modified = false

      -- Filetype was detected against ciphertext; worth another look now.
      -- `filetype detect` acts on the current buffer, and this handler is careful
      -- to say ev.buf everywhere else — but measured: Neovim makes the buffer it
      -- is reading current for the duration of BufReadPost, including a hidden
      -- one loaded by `bufload()`. So the two are the same buffer here.
      vim.cmd("filetype detect")

      -- After the filetype, not before: setting it is what invites a language
      -- server to attach, so detaching first would be undone a line later.
      keep_language_servers_off(ev.buf)
    end,
  })
end

--- Internals exposed for the test suite only.
M._test = {
  remember_file_state = remember_file_state,
  file_changed_since_read = file_changed_since_read,
  file_fingerprint = file_fingerprint,
  write_atomically = write_atomically,
  block_at = block_at,
  is_encrypted = is_encrypted,
  context_dir = context_dir,
}

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
    -- Not "with a new password": the command only offers configured vault ids, and
    -- refuses outright when there are none.
    desc = "Re-encrypt this file under another configured vault id",
  })

  -- Both branches act: without the else, `transparent = false` left the first call's
  -- autocmds in place and the option looked respected.
  if M.options.transparent then
    enable_transparent_editing()
  else
    pcall(vim.api.nvim_del_augroup_by_name, "ansible_vault_transparent")
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
