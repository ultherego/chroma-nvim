-- What the operator sees while an inspection runs, and the way out of it.
--
-- There is no timeout: dynamic inventory takes as long as the system it asks
-- takes, and cancelling is the operator's (§13.4). That is only a design while
-- they can see it running and can stop it — before this the editor did nothing
-- at all between two pickers, for however long Ansible took, with no way to
-- say no.
--
-- A window rather than a notification, because a notification cannot be
-- answered. It does not take focus: an inspection is something the editor is
-- doing, not something it is asking.

local M = {}

--- Said the same way for every inspection, so the line the operator learns to
--- read does not move.
local ELLIPSIS = "…"
local HINT = "  [Cancel]  :AnsibleCancel"

---Opens the window and answers with a handle that closes it.
---
---`close` is how an inspection that finished takes its own window away, and it
---must never be mistaken for the operator saying no — the two happen through
---different doors and only one of them calls `on_cancel`.
---
---A variable so a test can answer for one without a window, and so this module
---is one seam rather than several.
---@type fun(label: string, on_cancel: fun()): { close: fun() }
M.open = function(label, on_cancel)
  local line = (" %s%s%s "):format(label, ELLIPSIS, HINT)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { line })
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"

  local window = vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    anchor = "SE",
    row = math.max(vim.o.lines - 2, 1),
    col = vim.o.columns,
    width = math.min(#line, math.max(vim.o.columns - 2, 20)),
    height = 1,
    style = "minimal",
    border = "rounded",
    -- Enterable, so the keys below are reachable, but not entered.
    focusable = true,
    noautocmd = true,
    zindex = 200,
  })

  -- One of the two doors, whichever is used first: closing twice is not two
  -- events, and cancelling after the answer arrived is not an event at all.
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

  ---The operator's no, from any of the ways they can give it.
  local function cancel()
    if handle.done then
      return
    end
    handle.done = true
    -- Before the window goes: what ends is the run, and the window is the part
    -- of it somebody can see. `on_cancel` reaches back here through the run's
    -- teardown, which `done` has already made a no-op.
    on_cancel()
    shut()
  end

  for _, key in ipairs({ "<Esc>", "q", "<CR>" }) do
    vim.keymap.set("n", key, cancel, { buffer = buf, nowait = true, desc = "Cancel the Ansible inspection" })
  end

  -- §13.4: a window that goes away is the operator saying no, however they made
  -- it go. Anything else would leave an inspection nobody can see or stop.
  --
  -- Both events, because they are matched differently and either can be the one
  -- that happens: `WinClosed` carries the window id as its pattern, and
  -- `BufWipeout` is what `bufhidden = "wipe"` produces on the way out.
  vim.api.nvim_create_autocmd("WinClosed", { pattern = tostring(window), once = true, callback = cancel })
  vim.api.nvim_create_autocmd("BufWipeout", { buffer = buf, once = true, callback = cancel })

  return handle
end

return M
