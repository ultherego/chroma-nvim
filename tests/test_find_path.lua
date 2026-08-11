-- Tests for finding a file by a path somebody already knows.
--
-- The pair `<leader>ff` / `<leader>fp` answers two different questions, and
-- the whole value of the second one is the completion on Tab. That is a
-- property of how the command is declared rather than of anything it runs, so
-- it is asserted here: a `:FindFile` that opens files and completes nothing is
-- a slower `:edit`.

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

---The declaration Neovim holds for a user command.
---@param name string
---@return table
local function command(name)
  local found = vim.api.nvim_get_commands({})[name]
  if not found then
    error(("there is no :%s"):format(name))
  end
  return found
end

local saved = {}

local T = new_set({
  hooks = {
    pre_case = function()
      saved.dir = vim.uv.cwd()

      -- :FindFile comes from the configuration rather than from a plugin, so
      -- requiring this is enough to make it real. The same is true of the
      -- keymap beside it.
      require("config.commands")
      require("config.keymaps")
    end,
    post_case = function()
      vim.cmd.cd(saved.dir)
      vim.cmd("silent! %bwipeout!")
    end,
  },
})

-- ---------------------------------------------------------------------------
-- What the command is declared to be

T["declaration"] = new_set()

T["declaration"]["completes paths the way Neovim does"] = function()
  -- The reason the command exists. Without this it is `:edit` with extra
  -- steps, and Tab in the middle of a long path does nothing.
  eq(command("FindFile").complete, "file")
end

T["declaration"]["takes the path as its one argument"] = function()
  eq(command("FindFile").nargs, "1")
end

-- ---------------------------------------------------------------------------
-- What it does with the path

T["opening"] = new_set()

T["opening"]["opens the file that was named"] = function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(vim.fs.joinpath(dir, "roles", "web"), "p")

  local file = vim.fs.joinpath(dir, "roles", "web", "main.yml")
  vim.fn.writefile({ "- hosts: all" }, file)

  vim.cmd.cd(dir)
  vim.cmd("FindFile roles/web/main.yml")

  eq(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t"), "main.yml")
  eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { "- hosts: all" })
end

T["opening"]["opens a path with a space in it"] = function()
  -- What completion inserts for a directory with a space in its name is
  -- `two\ words`, and what the command is handed is `two words` — the escaping
  -- belongs to the command line and is gone by the time this runs.
  local dir = vim.fn.tempname()
  vim.fn.mkdir(vim.fs.joinpath(dir, "two words"), "p")

  local file = vim.fs.joinpath(dir, "two words", "note.txt")
  vim.fn.writefile({ "here" }, file)

  vim.cmd.cd(dir)
  vim.cmd([[FindFile two\ words/note.txt]])

  eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { "here" })
end

-- ---------------------------------------------------------------------------
-- The keymap in front of it

T["keymap"] = new_set()

T["keymap"]["leaves the command line open to type a path into"] = function()
  -- No <cr>: the point of this mapping is the typing that follows it. A
  -- mapping that ran something would be a second fuzzy finder, which is what
  -- `<leader>ff` already is and what this deliberately is not.
  eq(vim.fn.maparg("<leader>fp", "n"), ":FindFile ")
end

return T
