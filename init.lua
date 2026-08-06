-- DevOps nVim — entry point.
--
-- Leader keys are set here, before lazy.nvim is loaded. Plugins may register
-- keymaps while loading, and those bind against whatever <leader> resolves to
-- at that moment — setting it later silently produces the wrong mappings.
vim.g.mapleader = " "
vim.g.maplocalleader = "\\"

require("config.options")
require("config.keymaps")
require("config.lazy")
