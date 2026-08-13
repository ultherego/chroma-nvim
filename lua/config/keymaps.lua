-- Keymaps that need no plugin.

local map = vim.keymap.set

-- Left on the command line rather than executed: the point is the typing that
-- follows, with Tab completing the path. See :FindFile in commands.lua.
map("n", "<leader>fp", ":FindFile ", { desc = "Find path" })

-- What a task is belongs to `.chroma/tasks.json`; nothing here knows.
map("n", "<leader>xr", function()
  require("chroma.tasks").run()
end, { desc = "Run task" })

map("n", "<leader>bd", "<cmd>bdelete<cr>", { desc = "Delete buffer" })
map("n", "<leader>bD", "<cmd>bdelete!<cr>", { desc = "Delete buffer (force)" })
map("n", "<leader>bb", "<cmd>buffer #<cr>", { desc = "Previous buffer" })

map("n", "<leader>ws", "<C-w>s", { desc = "Split horizontally" })
map("n", "<leader>wv", "<C-w>v", { desc = "Split vertically" })
map("n", "<leader>wc", "<C-w>c", { desc = "Close window" })
map("n", "<leader>wo", "<C-w>o", { desc = "Close other windows" })
map("n", "<leader>w=", "<C-w>=", { desc = "Equalise window sizes" })

-- Pastes over a selection without losing what was yanked.
map("x", "<leader>p", [["_dP]], { desc = "Paste without yanking" })

map("x", "J", ":move '>+1<cr>gv=gv", { desc = "Move selection down" })
map("x", "K", ":move '<-2<cr>gv=gv", { desc = "Move selection up" })

-- Stay in visual mode after shifting, so indentation can be repeated.
map("x", "<", "<gv", { desc = "Shift left, keep selection" })
map("x", ">", ">gv", { desc = "Shift right, keep selection" })
