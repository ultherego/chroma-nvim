-- Keymaps that need no plugin.
--
-- Deliberately short. Two things keep it that way:
--
-- 1. Neovim 0.12 already ships defaults for most of what configs traditionally
--    map by hand (see :help default-mappings): gc/gcc for comments, ]d/[d for
--    diagnostics, ]b/[b for buffers, ]q/[q for quickfix, <C-L> for nohlsearch,
--    and the LSP set K / grn / gra / grr / gri / grt. None of that is repeated
--    here.
--
-- 2. Everything else lives under <leader>, in the groups fixed by the contract.
--    Plugin keymaps are defined in the plugin's own spec, not here.
--
-- Control-key combinations are avoided on purpose: Zellij captures
-- Ctrl g/q/h/o/b/s/t/p/n before Neovim ever sees them. Window movement uses
-- the built-in <C-w> prefix, which Zellij leaves alone.

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
-- Keep the register when pasting over a selection, so the yanked text is not
-- replaced by whatever it overwrote.
map("x", "<leader>p", [["_dP]], { desc = "Paste without yanking" })

-- Move the selection up and down, reindenting as it goes.
map("x", "J", ":move '>+1<cr>gv=gv", { desc = "Move selection down" })
map("x", "K", ":move '<-2<cr>gv=gv", { desc = "Move selection up" })

-- Stay in visual mode after shifting, so indentation can be repeated.
map("x", "<", "<gv", { desc = "Shift left, keep selection" })
map("x", ">", ">gv", { desc = "Shift right, keep selection" })
