-- Chroma Neovim — entry point.
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

-- Not deferred: these only register commands, mappings and the vault's write
-- hook, which must exist before any vault file is opened. Which of them run
-- comes from the components rather than from a list here.
require("chroma.modules").setup({ keymaps = true })
