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

-- Copying goes to the system clipboard; deleting does not. `unnamedplus` sent
-- every unnamed-register operation there, and `dd`, `dw`, `cw` and `x` are
-- those too: deleting a line replaced whatever had been copied, here or in
-- another program. So 'clipboard' stays empty and a yank is passed on by hand.
-- `dd` then `p` still moves a line, because that never left the editor.
-- Neovim ships OSC 52, so `+` keeps working over SSH inside Kitty.
vim.api.nvim_create_autocmd("TextYankPost", {
  group = vim.api.nvim_create_augroup("chroma_yank_to_clipboard", { clear = true }),
  desc = "Send yanks, and only yanks, to the system clipboard",
  callback = function()
    local event = vim.v.event
    -- Only a plain `y`: a yank into a named register was aimed somewhere.
    if event.operator ~= "y" or event.regname ~= "" then
      return
    end
    -- A machine with no clipboard tool raises here, and a yank that worked
    -- inside the editor is not a failure worth interrupting somebody for.
    pcall(vim.fn.setreg, "+", event.regcontents, event.regtype)
  end,
})

-- 'termguicolors' is NOT set: Neovim detects 24-bit colour on its own.
