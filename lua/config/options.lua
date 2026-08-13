-- Core editor options.

local o = vim.o

o.expandtab = true
o.shiftwidth = 2
o.tabstop = 2
o.softtabstop = 2

-- 'smartindent' is NOT enabled: it forces lines starting with '#' to column 0,
-- which mangles comments in YAML and Dockerfiles.

o.number = true
o.relativenumber = true

-- Wrapped YAML hides structure.
o.wrap = false

o.ignorecase = true
o.smartcase = true

-- Always reserved, so the buffer does not shift sideways when a sign appears.
o.signcolumn = "yes"

o.undofile = true

o.splitright = true
o.splitbelow = true

o.scrolloff = 8

-- Default is 4000ms, which makes CursorHold-driven UI feel sluggish.
o.updatetime = 250

o.cursorline = true

-- Prompt to save instead of failing the command outright.
o.confirm = true

-- In YAML, trailing whitespace and tabs are bugs rather than style.
o.list = true
vim.opt.listchars = {
  tab = "» ",
  trail = "·",
  nbsp = "␣",
}

-- Treesitter drives folding; these keep a file from opening folded shut.
o.foldlevel = 99
o.foldlevelstart = 99

o.winborder = "rounded"

-- Neovim ships OSC 52, so this keeps working over SSH inside Kitty.
o.clipboard = "unnamedplus"

-- 'termguicolors' is NOT set: Neovim detects 24-bit colour on its own.
