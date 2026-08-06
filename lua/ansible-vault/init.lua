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
---@field keymaps boolean|nil  create the default <leader>a mappings
local defaults = {
  keymaps = false,
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
    return { cwd = cwd }
  end

  -- Nothing configured: ask. inputsecret keeps the password off the screen and
  -- out of the command-line history.
  local password = vim.fn.inputsecret("Vault password: ")
  if password == "" then
    return nil, "cancelled"
  end

  return { password = password }
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

  if M.options.keymaps then
    vim.keymap.set("n", "<leader>av", M.reveal, { desc = "Reveal vault value" })
    vim.keymap.set("x", "<leader>av", ":VaultEncrypt<cr>", { desc = "Encrypt selection" })
    vim.keymap.set("n", "<leader>aV", "<cmd>VaultStatus<cr>", { desc = "Vault password source" })
  end
end

return M
