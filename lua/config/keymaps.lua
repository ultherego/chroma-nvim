-- Keymaps that need no plugin.

local map = vim.keymap.set

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
