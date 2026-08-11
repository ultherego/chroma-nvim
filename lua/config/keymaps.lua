-- Keymaps that need no plugin.

local map = vim.keymap.set

-- Find ---------------------------------------------------------------------
-- Left on the command line rather than executed: the point of this one is the
-- typing that follows it, with Tab completing the path. Everything else under
-- <leader>f is the fuzzy finder, and this does not replace any of it — see
-- :FindFile in config/commands.lua for why they are two different questions.
map("n", "<leader>fp", ":FindFile ", { desc = "Find path" })

-- Tools --------------------------------------------------------------------
-- Run Task. Core rather than a plugin, and reached the same way in every
-- project: what a task is belongs to `.chroma/tasks.json`, and nothing here
-- knows what any of them do.
map("n", "<leader>xr", function()
  require("chroma.tasks").run()
end, { desc = "Run task" })

-- Buffers ------------------------------------------------------------------
map("n", "<leader>bd", "<cmd>bdelete<cr>", { desc = "Delete buffer" })
map("n", "<leader>bD", "<cmd>bdelete!<cr>", { desc = "Delete buffer (force)" })
map("n", "<leader>bb", "<cmd>buffer #<cr>", { desc = "Previous buffer" })

-- Windows ------------------------------------------------------------------
map("n", "<leader>ws", "<C-w>s", { desc = "Split horizontally" })
map("n", "<leader>wv", "<C-w>v", { desc = "Split vertically" })
map("n", "<leader>wc", "<C-w>c", { desc = "Close window" })
map("n", "<leader>wo", "<C-w>o", { desc = "Close other windows" })
map("n", "<leader>w=", "<C-w>=", { desc = "Equalise window sizes" })

-- Editing ------------------------------------------------------------------
-- Pastes over a selection without losing what was yanked.
map("x", "<leader>p", [["_dP]], { desc = "Paste without yanking" })

-- Move the selection up and down, reindenting as it goes.
map("x", "J", ":move '>+1<cr>gv=gv", { desc = "Move selection down" })
map("x", "K", ":move '<-2<cr>gv=gv", { desc = "Move selection up" })

-- Stay in visual mode after shifting, so indentation can be repeated.
map("x", "<", "<gv", { desc = "Shift left, keep selection" })
map("x", ">", ">gv", { desc = "Shift right, keep selection" })
