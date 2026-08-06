-- DevOps nVim — entry point.
--
-- Leader keys are set here, before lazy.nvim is loaded. Plugins may register
-- keymaps while loading, and those bind against whatever <leader> resolves to
-- at that moment — setting it later silently produces the wrong mappings.
vim.g.mapleader = " "
vim.g.maplocalleader = "\\"

require("config.options")
require("config.keymaps")
require("config.commands")
require("config.lazy")

-- ansible-vault.nvim lives in lua/ansible-vault/ and depends on nothing in this
-- configuration, so it can be lifted into its own repository unchanged. setup()
-- only registers four user commands and three mappings, so there is nothing to
-- gain from deferring it.
require("ansible-vault").setup({ keymaps = true })
require("terraform").setup({ keymaps = true })
require("aws").setup({ keymaps = true })
