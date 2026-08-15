-- What a failed inspection shows, and why it is a window rather than a prompt.
--
-- §16 promises Ansible's own output, whole: not summarised, not rewritten, not
-- truncated. That promise was handed to `vim.ui.select` as the prompt of the
-- menu offering the way onwards, which is true only of Neovim's built-in
-- implementation. Measured on the pinned set: `vim.ui.select` here is fzf-lua's,
-- it maps the prompt onto fzf's `--prompt`, and a prompt is one line — so the
-- operator saw `Tag inspection failed` and four choices, and never learned what
-- Ansible had said.
--
-- The same measurement gave the second reason. fzf-lua passes that prompt in the
-- **argv of the fzf process**, where anyone on the machine can read it, so
-- pushing more of a subprocess's output through it would put paths and host
-- names into the process table (§7.4 wants the opposite).
--
-- So output never travels through a picker again. It is shown in a scratch
-- buffer of Neovim's own, which no plugin has to be configured to render and
-- which nothing outside the editor can read; `vim.ui.select` is left for what it
-- is good at, which is a short question with short answers.

local M = {}

--- What the border says the two keys do. In the border rather than the buffer,
--- so every line inside it is a line Ansible wrote.
local KEYS = " Enter: choose what to do   Esc/q: cancel "

---Opens the view and answers with a handle that closes it.
---
---Two doors, as `progress.lua` has: `close` is this run being taken down and is
---not an answer, while everything the operator can do is one. Only `on_proceed`
---leads to the menu, and it is reached from exactly one key.
---
---A variable, so a test can answer for one without a window.
---@type fun(headline: string, detail: string, on_proceed: fun(), on_cancel: fun()): { close: fun() }
M.open = function(headline, detail, on_proceed, on_cancel)
  local lines = { headline }
  if detail ~= "" then
    table.insert(lines, "")
    -- Split and never joined, cut or wrapped: what Ansible printed on four
    -- lines is four lines here. `nvim_buf_set_lines` refuses a string holding a
    -- newline, which is the only reason this is a split at all.
    vim.list_extend(lines, vim.split(detail, "\n", { plain = true }))
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false

  local widest = 0
  for _, line in ipairs(lines) do
    widest = math.max(widest, vim.fn.strdisplaywidth(line))
  end

  -- Bounded by the editor and never by the content: a window that does not fit
  -- is one the operator scrolls, which is not the same as output that was cut.
  local width = math.min(math.max(widest, #KEYS), math.max(vim.o.columns - 4, 20))
  local height = math.min(#lines, math.max(vim.o.lines - 6, 3))

  local window = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.max(math.floor((vim.o.lines - height) / 2) - 1, 0),
    col = math.max(math.floor((vim.o.columns - width) / 2), 0),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    footer = KEYS,
    footer_pos = "center",
    noautocmd = true,
    zindex = 200,
  })

  local handle = { done = false }

  local function shut()
    if vim.api.nvim_win_is_valid(window) then
      pcall(vim.api.nvim_win_close, window, true)
    end
  end

  function handle.close()
    if handle.done then
      return
    end
    handle.done = true
    shut()
  end

  ---One of the operator's two answers. `done` is set before the window goes, so
  ---the autocmds the closing fires find the answer already given.
  ---@param answered fun()
  local function answer(answered)
    if handle.done then
      return
    end
    handle.done = true
    shut()
    answered()
  end

  vim.keymap.set("n", "<CR>", function()
    answer(on_proceed)
  end, { buffer = buf, nowait = true, desc = "Choose how to carry on" })

  for _, key in ipairs({ "<Esc>", "q" }) do
    vim.keymap.set("n", key, function()
      answer(on_cancel)
    end, { buffer = buf, nowait = true, desc = "Cancel the Ansible run" })
  end

  -- §13.4, as everywhere else: a window that goes away is the operator saying
  -- no, however they made it go. `WinClosed` matches on the window id and
  -- `BufWipeout` is what `bufhidden = "wipe"` produces, and either can be the
  -- one that happens first.
  local function gone()
    answer(on_cancel)
  end

  vim.api.nvim_create_autocmd("WinClosed", { pattern = tostring(window), once = true, callback = gone })
  vim.api.nvim_create_autocmd("BufWipeout", { buffer = buf, once = true, callback = gone })

  return handle
end

return M
