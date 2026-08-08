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

-- These three live in lua/chroma-vault/, lua/chroma-terraform/ and lua/chroma-aws/, and
-- depend on nothing in this configuration, so each can be lifted into its own
-- repository unchanged.
--
-- Their setup() calls only register user commands, mappings and — for the
-- vault — a pair of autocmds, so there is nothing to gain from deferring them.
-- The vault's write hook in particular must exist before any vault file is
-- opened, which rules out lazy loading it.
require("chroma-vault").setup({ keymaps = true })
require("chroma-terraform").setup({ keymaps = true })
require("chroma-aws").setup({ keymaps = true })
