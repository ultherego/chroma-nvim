-- Core editor options.
--
-- Only options that actually differ from Neovim 0.12 defaults are set here.
-- Defaults were read from the running instance, not assumed. Anything Neovim
-- already does correctly is left alone, and the reason is noted where the
-- omission is deliberate.

local o = vim.o

-- Indentation: two spaces, everywhere, no tabs.
-- This is the single most important setting in a DevOps config. YAML has no
-- tabs — a literal tab character is a parse error in Ansible playbooks,
-- Kubernetes manifests, Helm charts and GitHub Actions workflows alike.
o.expandtab = true
o.shiftwidth = 2
o.tabstop = 2
o.softtabstop = 2

-- 'smartindent' is deliberately NOT enabled. It is a pre-treesitter heuristic
-- that forces lines starting with '#' to column 0, which mangles comments in
-- exactly the languages used here. Indentation is left to the filetype plugins
-- and to treesitter.

-- Line numbers, relative for motion counts.
o.number = true
o.relativenumber = true

-- Long lines are truncated rather than wrapped. Wrapped YAML hides structure.
o.wrap = false

-- Case-insensitive search until an uppercase letter is typed.
o.ignorecase = true
o.smartcase = true

-- Always reserve the sign column so the buffer does not shift sideways every
-- time a git sign or a diagnostic appears.
o.signcolumn = "yes"

-- Persistent undo across sessions, under stdpath("state").
o.undofile = true

-- New splits open where the eye already is.
o.splitright = true
o.splitbelow = true

-- Keep context around the cursor instead of hitting the window edge.
o.scrolloff = 8

-- Default is 4000ms. Lower makes CursorHold-driven UI (git signs, diagnostic
-- hovers) feel immediate without meaningfully costing anything.
o.updatetime = 250

o.cursorline = true

-- Prompt to save instead of failing the command outright.
o.confirm = true

-- Show trailing whitespace and tabs. In YAML both are real bugs, not style.
o.list = true
vim.opt.listchars = {
  tab = "» ",
  trail = "·",
  nbsp = "␣",
}

-- Folding is driven by treesitter (see plugins/treesitter.lua), but a file
-- should open fully expanded. Without these, every buffer with a parser opens
-- collapsed to its top-level nodes.
o.foldlevel = 99
o.foldlevelstart = 99

-- Global default border for every floating window, so plugins look consistent
-- without configuring each one separately. Option added in Neovim 0.11.
o.winborder = "rounded"

-- Share the system clipboard. Neovim ships OSC 52 support, so this keeps
-- working over SSH inside Kitty.
o.clipboard = "unnamedplus"

-- 'termguicolors' is deliberately NOT set: Neovim detects 24-bit colour
-- support and enables it on its own unless explicitly disabled
-- (see :help 'termguicolors').
