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

--- The directory whose ansible.cfg applies to a buffer.
---
--- Neovim's working directory is not it. Open a playbook from another project
--- — through a picker, a session, or `nvim path/to/other/repo/vars.yml` — and
--- getcwd() still points at the first project, so ansible would be asked about
--- the wrong ansible.cfg and hand back the wrong password file entirely.
---@param buf integer|nil
---@return string
local function context_dir(buf)
  local name = vim.api.nvim_buf_get_name(buf or 0)
  if name == "" then
    return vim.fn.getcwd()
  end

  local start = vim.fs.dirname(name)
  -- The nearest ansible.cfg above the file wins, matching how ansible itself
  -- resolves configuration relative to where it runs.
  local found = vim.fs.find("ansible.cfg", { path = start, upward = true, type = "file" })[1]
  return found and vim.fs.dirname(found) or start
end

--- Takes a BUFFER, not a directory.
---
--- It used to take a directory, and when the callers were changed to pass a
--- buffer the signature was not. Every call then handed a buffer number to
--- vim.system as its cwd, which fails with "cwd option must be string" — and
--- since the failure surfaced as a notification rather than an exception, it
--- looked like an ansible problem rather than a wrong argument. Typed and named
--- so the mistake cannot repeat silently.
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
      -- Deliberately NOT `identities`: cli.auth_args turns that field into
      -- --vault-id arguments, which is exactly what the paragraph above says
      -- must not happen. Named differently so the two cannot be confused
      -- again — it exists only so encrypt_identity_for can offer a choice.
      configured_identities = resolved.identities,
      encrypt_identity = resolved.encrypt_identity,
    }
  end

  -- Nothing configured: ask. inputsecret keeps the password off the screen and
  -- out of the command-line history.
  local password = vim.fn.inputsecret("Vault password: ")
  if password == "" then
    return nil, "cancelled"
  end

  -- `cwd` matters just as much on this branch as on the one above, and it was
  -- missing here. Every caller passes `auth.cwd` to vim.system, so a nil left
  -- ansible running in Neovim's working directory instead of the project the
  -- buffer belongs to — the exact confusion context_dir exists to prevent. Open
  -- a vault from another repository and the wrong ansible.cfg applies: another
  -- vault_identity_list, other relative password file paths, another set of
  -- secrets ansible will try.
  return { password = password, cwd = cwd }
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

  local ids = auth.configured_identities or {}
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

---True when the FILE ON DISK is a vault, whatever the buffer is showing.
---
---Asking the buffer is wrong for anything that operates on the file. With
---transparent editing — the default — an encrypted file is decrypted into the
---buffer on open, so a content check sees plaintext and concludes the file is
---not encrypted. Rekey used that check and therefore refused to run on
---precisely the files it exists for.
---@param path string
---@return boolean
local function file_is_vault(path)
  local first = first_line(path)
  return first ~= nil and first:match("^%$ANSIBLE_VAULT") ~= nil
end

---The vault id a file is encrypted under, when the header records one.
---
---Format 1.2 appends the label: `$ANSIBLE_VAULT;1.2;AES256;prod`. Format 1.1
---has no label field, so this returns nil for it. Confirmed against ansible
---core 2.21 by encrypting with --encrypt-vault-id and reading the result.
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

---Finds the `!vault` block the cursor is in: its `key: !vault |` marker line or
---any line of the indented body below it. Anywhere else returns nil.
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

  -- The cursor has to be in the block that was found.
  --
  -- The upward scan stops at a non-indented line, but only for lines above the
  -- cursor: `i < lnum`. That exception exists so the `key: !vault |` line the
  -- cursor sits on does not stop the search before it starts — and it also let
  -- any other top-level line through. On the first line after a block, the scan
  -- walked past it and returned the block above, so :VaultReveal showed the
  -- previous secret instead of saying there was none under the cursor.
  -- Verified: with a block on lines 1..3, line 4 resolved to it and line 5 did
  -- not, which is the giveaway.
  --
  -- `lnum < start` cannot happen, since the scan begins at the cursor and moves
  -- up. It is written out anyway: the condition this returns on is "the cursor
  -- is inside first..last", and stating half of it would leave the next reader
  -- working out why.
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
---
---@param opts table|nil the user-command options; requires a range
function M.encrypt_selection(opts)
  local buf = vim.api.nvim_get_current_buf()

  -- The range comes from the command, NOT from the '< and '> marks.
  --
  -- Those marks outlive the selection that set them. Reading them meant that
  -- invoking this from normal mode encrypted whatever had last been selected,
  -- wherever the cursor happened to be — silently encrypting the wrong lines,
  -- which in a secrets tool leaves the value you meant to protect in the clear
  -- and hides an unrelated one. Verified: cursor on line 4, an old selection on
  -- line 2, and line 2 was the one encrypted.
  --
  -- Pressing `:` in visual mode inserts the range, so the visual-mode mapping
  -- still works exactly as before.
  if not opts or (opts.range or 0) == 0 then
    vim.notify("VaultEncrypt needs a range — select the lines first, or use :N,MVaultEncrypt", vim.log.levels.WARN)
    return
  end

  local first = opts.line1
  local last = opts.line2

  local lines = vim.api.nvim_buf_get_lines(buf, first - 1, last, false)
  local plaintext = table.concat(lines, "\n")

  -- A `key: value` selection is encrypted as that key, so the result drops
  -- straight back in place.
  local key, value = plaintext:match("^%s*([%w_%-%.]+)%s*:%s*(.*)$")
  local indent = lines[1]:match("^(%s*)") or ""

  local auth, err = auth_for(buf)
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

--- Remembers what the file looked like when we read it.
---
--- Vault buffers have 'noswapfile', so Neovim's "found a swap file" warning is
--- gone, and taking over the write with BufWriteCmd also bypasses its "file has
--- changed since editing started" check. Both protections against two editors
--- clobbering each other were therefore absent — verified by having a second
--- writer land between read and write: its change vanished with no warning.
---
--- Recording a fingerprint at read, and comparing before write, restores that
--- protection without a swap file full of plaintext.
---
--- Whole seconds and size were not enough. A second writer that lands within
--- the same second and produces a file of the same length — a password
--- rotated in place, a value edited to the same width, an automated
--- rewrite — left both fields identical and the change went through
--- unannounced. Measured on this repository's own filesystem: two writes in
--- the same second with equal size compare equal on (sec, size) and differ on
--- mtime.nsec.
---
--- So the fingerprint also carries nanoseconds, inode and device. The inode
--- catches the case nanoseconds cannot: another process replacing the file
--- atomically, which is what careful writers do, gives a new inode and can
--- otherwise carry any timestamp it likes.
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
  vim.b[buf].ansible_vault_stat = file_fingerprint(vim.api.nvim_buf_get_name(buf))
end

---@param buf integer
---@return string|nil description of the change
local function file_changed_since_read(buf)
  local remembered = vim.b[buf].ansible_vault_stat
  if not remembered then
    return nil
  end

  local current = file_fingerprint(vim.api.nvim_buf_get_name(buf))
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

--- Resolves a path and refuses it when another name points at the same inode.
---
--- Every operation in this plugin that replaces a vault has to ask this,
--- because every one of them breaks the other names — differently, and one of
--- them destructively. Keeping the question in one place is what makes the
--- guarantee in README a property of the plugin rather than of whichever code
--- path happened to remember it; rekey did not, and rekey is the destructive
--- one.
---
--- Symlinks are resolved rather than refused: replacing what the link points at
--- is what the user meant, and both callers handle it correctly once the link
--- is followed.
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

--- Replaces a file's contents without ever leaving it truncated.
---
--- Opening the target with "w" truncates it before the first byte is written,
--- so a crash, a full disk or a killed process between those two moments
--- destroys the vault. Writing a sibling temporary file and renaming over the
--- target makes the replacement atomic: on any POSIX filesystem the target is
--- either the old contents or the new ones, never nothing.
---
--- Short writes and close failures are also checked. The previous version
--- ignored both return values and reported success regardless, which is how a
--- half-written vault would have been announced as saved.
---@param path string
---@param contents string
---@return boolean ok, string|nil err
local function write_atomically(path, contents)
  -- Both halves of what check_hardlinks does matter here, for the same reason:
  -- rename() replaces exactly the name it is given.
  --
  -- Handed a symlink it deletes the link and leaves a regular file in its
  -- place, while the file the link pointed at keeps its old contents — so the
  -- write appears to succeed and the real vault silently stays stale. Verified:
  -- a link to real/vars.yml became a regular file and real/vars.yml never saw
  -- the change. Resolving the link first is therefore the fix, not a nicety;
  -- shared secrets are routinely linked into group_vars.
  --
  -- Handed one of several hard links it updates that name alone. The others
  -- keep pointing at the old content, so `a` gets the new vault and `b`, which
  -- was the same file a moment ago, quietly keeps the old one. Verified: after
  -- replacing a linked file this way the second name still held the previous
  -- contents and had the previous inode.
  --
  -- Writing in place instead would preserve the links and give up the
  -- protection this whole function exists for — a truncated vault on a crash
  -- or a full disk. Between silently diverging copies and a refusal that says
  -- what to do, the refusal is the honest one.
  local target, link_err = check_hardlinks(path)
  if not target then
    return false,
      ("%s, and replacing it atomically would update only this name. "):format(link_err)
        .. "Remove the other links, or use :saveas to write somewhere else."
  end

  local tmp = ("%s.ansible-vault.nvim.%d.tmp"):format(target, vim.uv.os_getpid())

  local fd, open_err = vim.uv.fs_open(tmp, "wx", tonumber("600", 8))
  if not fd then
    return false, ("could not create %s: %s"):format(tmp, open_err or "unknown error")
  end

  local function fail(message)
    vim.uv.fs_close(fd)
    pcall(vim.uv.fs_unlink, tmp)
    return false, message
  end

  local written, write_err = vim.uv.fs_write(fd, contents)
  if not written then
    return fail(write_err or "write failed")
  end
  if written < #contents then
    return fail(("short write: %d of %d bytes"):format(written, #contents))
  end

  -- Without this the rename can land before the data does, leaving an empty
  -- file where a vault used to be.
  local synced, sync_err = vim.uv.fs_fsync(fd)
  if synced == nil then
    return fail(sync_err or "fsync failed")
  end

  local closed, close_err = vim.uv.fs_close(fd)
  if not closed then
    pcall(vim.uv.fs_unlink, tmp)
    return false, close_err or "close failed"
  end

  local renamed, rename_err = vim.uv.fs_rename(tmp, target)
  if not renamed then
    pcall(vim.uv.fs_unlink, tmp)
    return false, rename_err or "rename failed"
  end

  return true
end

--- Stops a buffer from persisting its contents anywhere Neovim would normally
--- put them. The buffer stays a real file buffer so `:w` still means what it
--- normally means; what changes is that nothing persists in clear.
---
--- Deliberately says nothing about what the buffer currently holds. It is
--- applied to a decrypted vault, where the plaintext is the thing to contain,
--- and to a buffer that has just been converted from plaintext to ciphertext,
--- where the plaintext is already in the undo history and must not be written
--- out with it.
---@param buf integer
local function harden_sensitive_buffer(buf)
  vim.bo[buf].undofile = false
  vim.bo[buf].swapfile = false
  vim.bo[buf].modeline = false

  -- 'backup' and 'writebackup' are NOT set here, and cannot be: both are
  -- global options. Re-verified — `vim.bo[buf].backup = false` raises "'buf'
  -- cannot be passed for global option 'backup'", and nvim_get_option_info2
  -- reports scope=global for both. Turning them off globally is not this
  -- plugin's business; it would change how every other file in the editor is
  -- written.
  --
  -- What replaces them is M.attach_writer. A BufWriteCmd takes the write over
  -- completely, so Neovim's backup machinery never runs for this buffer and no
  -- copy of the old file is made. That makes attaching the writer a security
  -- requirement rather than a convenience, and it is why every path that
  -- hardens a buffer with a file behind it attaches one in the same breath.
end

--- A buffer holding a decrypted vault: hardened, and marked so the writer
--- knows to re-encrypt it rather than write it out as it stands.
---@param buf integer
local function mark_plain_vault_buffer(buf)
  harden_sensitive_buffer(buf)
  vim.b[buf].ansible_vault_plain = true
end

--- Removes the persistent undo file for a path, if there is one.
---
--- 'undofile' is consulted when the undo file is written, so turning it off
--- stops new ones appearing — it does not remove one that already exists, and
--- the existing one holds every earlier state of the buffer.
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
---The order below is the whole of this function, and it is ordered so that no
---step can leave the buffer half-converted.
---
---Encryption comes first, because everything after it is destructive and there
---is no reason to destroy anything on behalf of an operation that then fails.
---Hardening comes next, and only then the existing undo file: 'undofile' being
---switched off stops new undo files appearing, but it does not remove the one
---already on disk, and that one holds every earlier state of this buffer —
---which is to say the secret, in the clear, in stdpath("state"), surviving
---reboots. Verified before this was written: `:VaultEncryptFile` followed by
---`:w` left the plaintext readable in the undo file.
---
---Removing it is deliberate data loss and the point of the command justifies
---it, but only fails closed: if the undo file cannot be removed the conversion
---does not happen, because completing it would mean announcing a vault while a
---plaintext copy of it stays behind.
---
---'undofile' stays off for the buffer even then. Once the intent to convert
---has been stated, letting Neovim resume writing plaintext undo files would be
---the worse of the two outcomes.
---
---The file state is remembered and the writer attached before the buffer
---changes, so the first `:w` after this goes through the same guarded path as
---every other vault write — conflict detection and atomic replacement — rather
---than through Neovim's ordinary write, which would also make a backup copy of
---the plaintext file it is replacing.
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

  local ciphertext, encrypt_err = cli.encrypt_document(buffer_text(buf), {
    auth = auth,
    cwd = auth.cwd,
    encrypt_identity = encrypt_identity_for(auth),
  })
  if not ciphertext then
    vim.notify(encrypt_err, vim.log.levels.ERROR)
    return
  end

  -- Nothing above this line has changed anything. Everything below it has to
  -- either complete or leave the buffer as it was.
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

    -- Guarded rather than assumed: a buffer holding ciphertext with no safe
    -- way to write it is a worse state than a plaintext buffer that was never
    -- converted.
    local attached, writer_err = pcall(M.attach_writer, buf)
    if not attached then
      vim.notify(
        ("Conversion aborted: the safe writer could not be installed: %s"):format(writer_err),
        vim.log.levels.ERROR
      )
      return
    end
  end

  -- An unnamed buffer has no file, so there is no undo file to remove, no file
  -- state to remember and nothing for the writer to take over. It is still
  -- hardened above, which is what matters: whatever name it is eventually
  -- saved under, the plaintext in its undo history is not written out with it.

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

  mark_plain_vault_buffer(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(plaintext:gsub("\n$", ""), "\n"))

  -- Not optional. Without this the buffer holds plaintext, `:w` performs an
  -- ordinary write, and the vault is replaced by its cleartext — while the
  -- message below promises the opposite. The writer is what makes that promise
  -- true, which is why it lives outside the transparent-editing option.
  remember_file_state(buf)
  M.attach_writer(buf)

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

---Which configured identity to rekey into.
---
---`--new-vault-id` needs the whole `label@source` entry. A bare label is
---treated as a path to a password file and fails with "The vault password file
---<label> was not found" — verified against ansible core 2.21, which is why
---the entries from vault_identity_list are passed through untouched.
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
---The new password has to be one that outlives this command. Rekeying to a
---password typed once leaves a file that nothing can open again: ansible
---resolves credentials from ansible.cfg, the typed password was staged in a
---temporary file and deleted, and the reload that follows then fails. Verified
---— a file rekeyed to a password ansible.cfg does not know comes back
---"Decryption failed (no vault secrets were found that could decrypt)".
---
---So the new password comes from vault_identity_list, and the rekey records
---its label in the file header, which is how ansible finds the right secret on
---the next open.
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

  -- The file, not the buffer: under transparent editing the buffer holds
  -- plaintext and a buffer check would refuse every file this command is for.
  if not file_is_vault(path) then
    vim.notify("The file on disk is not vault-encrypted", vim.log.levels.WARN)
    return
  end

  -- The same policy as every other write, and this is the path that needed it
  -- most. ansible-vault does not replace the file, it shreds it: the inode is
  -- overwritten in place before being unlinked. Through a hard link that
  -- destroys the data behind the other name rather than merely diverging from
  -- it. Measured against ansible-core 2.21.2 — after rekeying one of two names,
  -- the other was 4096 bytes of random data, `file` called it `data`, and
  -- `ansible-vault view` answered "Input is not vault encrypted data". There is
  -- nothing to recover from that, so the refusal comes before the command does
  -- anything at all, including asking which identity to rekey to.
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

  -- The ciphertext on disk is different now, so the buffer has to be reloaded
  -- whatever mode it is in: showing ciphertext, it is stale; holding plaintext,
  -- its remembered file state no longer matches and the next write would report
  -- a conflict. With transparent editing the BufReadPost hook decrypts again,
  -- and it can, because the new id is one ansible resolves for itself.
  vim.cmd.edit({ bang = true })
  vim.notify(("Rekeyed %s to vault id %s"):format(vim.fn.fnamemodify(path, ":t"), label), vim.log.levels.INFO)
end

--- The one way this plugin writes a file.
---
--- Every path that persists a buffer goes through here, so the conflict check,
--- the atomic replacement, the error handling and the bookkeeping cannot be
--- forgotten by one caller and remembered by another. They were: a second
--- branch in the writer called vim.fn.writefile directly, skipping the change
--- detection, the atomicity, the return value and the remembered state, and
--- marking the buffer saved regardless. That branch ran after
--- :VaultEncryptFile, which is exactly when the buffer holds a vault.
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
    -- The buffer stays modified on purpose: the work is still only in memory,
    -- and marking it saved would invite closing Neovim on it.
    return false, err
  end

  vim.bo[buf].modified = false
  -- Our own write changes mtime and size, so the remembered state moves with
  -- it. Without this the conflict check fires on the very next save and the
  -- buffer becomes unsaveable — a worse failure than the one it prevents.
  remember_file_state(buf)
  return true
end

--- The augroup for per-buffer write hooks. Separate from the transparent
--- editing group, because a writer must survive `transparent = false` — a
--- buffer decrypted by :VaultDecryptFile needs re-encrypting on write no
--- matter how the plugin was configured.
local writer_group = vim.api.nvim_create_augroup("ansible_vault_writer", { clear = true })

-- Registered per buffer, at the moment that buffer is decrypted.
--
-- An earlier version attached this to every buffer and fell back to an
-- ordinary write for the rest. That intercepts every `:write` in the editor,
-- and it broke immediately: writing a scratch buffer produced an error from
-- inside this plugin. A BufWriteCmd is a takeover of the write command; it
-- has no business existing on buffers this plugin does not own.
---@param buf integer
function M.attach_writer(buf)
  -- Cleared first. This is called on every decrypt, and a buffer is decrypted
  -- again on every `:edit!`, so without this each reload added another
  -- BufWriteCmd and a single `:write` ran the whole encrypt-and-persist
  -- sequence once per reload.
  pcall(vim.api.nvim_clear_autocmds, {
    group = writer_group,
    event = "BufWriteCmd",
    buffer = buf,
  })

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = writer_group,
    buffer = buf,
    callback = function(ev)
      local name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(ev.buf), ":t")

      if not vim.b[ev.buf].ansible_vault_plain then
        -- The buffer was decrypted once but currently holds ciphertext — after
        -- :VaultEncryptFile, for instance. It is written verbatim, but through
        -- the same guarded path as everything else.
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

      local ciphertext, encrypt_err = cli.encrypt_document(buffer_text(ev.buf), {
        auth = auth,
        cwd = auth.cwd,
        encrypt_identity = encrypt_identity_for(auth),
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
      mark_plain_vault_buffer(ev.buf)

      local auth, err = auth_for(ev.buf)
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
      remember_file_state(ev.buf)
      M.attach_writer(ev.buf)

      -- Filetype was detected against ciphertext, so it is worth another look
      -- now that the buffer holds YAML.
      vim.cmd("filetype detect")
    end,
  })
end

--- Internals exposed for the test suite only. Not part of the public API and
--- not covered by any compatibility promise.
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
    desc = "Re-encrypt this file with a new password",
  })

  -- Both branches act. Creating the augroup with clear = true only happens on
  -- the enabling path, so calling setup a second time with transparent = false
  -- used to leave the first call's autocmds in place: the option looked
  -- respected and was not. Found by asserting on the autocmd count rather than
  -- on the observed behaviour, which is what made the earlier "transparent is
  -- off" tests meaningless.
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
