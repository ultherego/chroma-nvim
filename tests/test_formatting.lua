-- Tests for the formatting layer.

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

---The keymap callback a spec binds to `lhs`.
---@param lhs string
---@return function
local function keymap(lhs)
  local spec = require("plugins.formatting")[1]
  for _, key in ipairs(spec.keys or {}) do
    if key[1] == lhs then
      return key[2]
    end
  end
  error(("no keymap for %s in the formatting spec"):format(lhs))
end

---The options the spec produces. `opts` is a function because which formatters
---exist depends on the enabled components, which is a runtime question.
---@return table
local function opts()
  return require("plugins.formatting")[1].opts()
end

local saved = {}

local T = new_set({
  hooks = {
    pre_case = function()
      saved.notify = vim.notify
      vim.notify = function() end

      -- The formatter set follows the selection, so these cases would otherwise
      -- depend on whoever runs them: a machine with Terraform switched off has
      -- no terraform formatter to test. An empty config directory means no
      -- selection, which means every component — the same answer everywhere.
      saved.xdg = vim.env.XDG_CONFIG_HOME
      vim.env.XDG_CONFIG_HOME = vim.fn.tempname()
      require("chroma.state").forget()

      -- :FormatEnable and :FormatDisable come from the configuration, not from
      -- a plugin, so requiring this is enough to make them real.
      require("config.commands")

      vim.g.disable_autoformat = nil
      vim.b.disable_autoformat = nil
    end,
    post_case = function()
      vim.notify = saved.notify
      vim.env.XDG_CONFIG_HOME = saved.xdg
      require("chroma.state").forget()
      vim.g.disable_autoformat = nil
      vim.b.disable_autoformat = nil
    end,
  },
})

-- ---------------------------------------------------------------------------
-- The global toggle owns the global flag, and only it

T["global toggle"] = new_set()

T["global toggle"]["disables when nothing is set"] = function()
  keymap("<leader>xF")()

  eq(vim.g.disable_autoformat, true)
  eq(vim.b.disable_autoformat, nil)
end

T["global toggle"]["enables when the global flag is set"] = function()
  vim.g.disable_autoformat = true

  keymap("<leader>xF")()

  eq(vim.g.disable_autoformat, nil)
  eq(vim.b.disable_autoformat, nil)
end

-- Regression: the toggle read the buffer-local flag but ran a global command, so
-- with formatting off here and nothing set globally it cleared an already-clear flag.
T["global toggle"]["disables globally even when this buffer is already off"] = function()
  vim.b.disable_autoformat = true

  keymap("<leader>xF")()

  eq(vim.g.disable_autoformat, true)
  -- Untouched: the buffer's own flag is the other mapping's business.
  eq(vim.b.disable_autoformat, true)
end

-- The same confusion the other way: `false` is not `nil`, so a buffer explicitly
-- enabled made the old code disable globally instead of enabling.
T["global toggle"]["enables globally even when this buffer is explicitly on"] = function()
  vim.g.disable_autoformat = true
  vim.b.disable_autoformat = false

  keymap("<leader>xF")()

  eq(vim.g.disable_autoformat, nil)
  eq(vim.b.disable_autoformat, false)
end

-- ---------------------------------------------------------------------------
-- Which Terraform formatter gets picked

T["terraform formatter"] = new_set({
  hooks = {
    post_case = function()
      package.loaded.conform = nil
    end,
  },
})

---Replaces conform with one that reports exactly these formatters as available.
---@param available string[]
local function conform_with(available)
  local set = {}
  for _, name in ipairs(available) do
    set[name] = true
  end

  package.loaded.conform = {
    get_formatter_info = function(name)
      return { available = set[name] == true }
    end,
  }
end

---@return function
local function chooser()
  return opts().formatters_by_ft.terraform
end

T["terraform formatter"]["prefers terraform_fmt when both are installed"] = function()
  conform_with({ "terraform_fmt", "tofu_fmt" })
  eq(chooser()(0), { "terraform_fmt" })
end

T["terraform formatter"]["uses terraform_fmt when it is the only one"] = function()
  conform_with({ "terraform_fmt" })
  eq(chooser()(0), { "terraform_fmt" })
end

-- The case this exists for: health has always accepted `tofu` alone as meaning
-- ".tf files can be formatted", which until now was true only of terraform.
T["terraform formatter"]["falls back to tofu_fmt when terraform is missing"] = function()
  conform_with({ "tofu_fmt" })
  eq(chooser()(0), { "tofu_fmt" })
end

T["terraform formatter"]["formats with nothing when neither is installed"] = function()
  conform_with({})
  eq(chooser()(0), {})
end

T["terraform formatter"]["applies to terraform-vars as well"] = function()
  local by_ft = opts().formatters_by_ft
  eq(by_ft["terraform-vars"], by_ft.terraform)
end

-- The names above are strings, and a typo in one would make this whole layer
-- quietly format nothing while every case with a stubbed conform still passed.
T["terraform formatter"]["names formatters conform actually ships"] = function()
  local root = vim.fs.joinpath(vim.fn.stdpath("data"), "lazy", "conform.nvim")
  if not vim.uv.fs_stat(root) then
    MiniTest.skip("conform.nvim is not installed")
  end

  for _, name in ipairs({ "terraform_fmt", "tofu_fmt" }) do
    eq(vim.uv.fs_stat(vim.fs.joinpath(root, "lua", "conform", "formatters", name .. ".lua")) ~= nil, true)
  end
end

-- ---------------------------------------------------------------------------
-- The buffer toggle owns the buffer's flag, and only it

T["buffer toggle"] = new_set()

T["buffer toggle"]["disables this buffer without touching the global flag"] = function()
  keymap("<leader>xb")()

  eq(vim.b.disable_autoformat, true)
  eq(vim.g.disable_autoformat, nil)
end

T["buffer toggle"]["enables this buffer without touching the global flag"] = function()
  vim.g.disable_autoformat = true
  vim.b.disable_autoformat = true

  keymap("<leader>xb")()

  eq(vim.b.disable_autoformat, nil)
  eq(vim.g.disable_autoformat, true)
end

-- ---------------------------------------------------------------------------
-- Decrypted vaults are not handed to subprocesses

T["vault buffers"] = new_set()

T["vault buffers"]["are not formatted on save"] = function()
  local buf = vim.api.nvim_create_buf(true, false)
  vim.b[buf].ansible_vault_plain = true
  eq(opts().format_on_save(buf), nil)
end

-- The manual mapping is a second entry point to the same subprocesses, and it
-- had no rule of its own.
T["vault buffers"]["are not formatted on demand either"] = function()
  local buf = vim.api.nvim_create_buf(true, false)
  vim.b[buf].ansible_vault_plain = true
  vim.api.nvim_set_current_buf(buf)

  local called, real = false, package.loaded.conform
  package.loaded.conform = {
    format = function()
      called = true
    end,
  }

  keymap("<leader>xf")()

  package.loaded.conform = real
  eq(called, false)
end

-- ---------------------------------------------------------------------------
-- The synchronous budget

local notices = {}

T["large files"] = new_set({
  hooks = {
    pre_case = function()
      notices = {}
      vim.notify = function(message, _)
        table.insert(notices, tostring(message))
      end
    end,
    post_case = function()
      vim.cmd("silent! %bwipeout!")
    end,
  },
})

---The format_on_save decision the spec configures.
---@return function
local function on_save()
  return opts().format_on_save
end

---@param pattern string
---@return boolean
local function said(pattern)
  for _, message in ipairs(notices) do
    if message:match(pattern) then
      return true
    end
  end
  return false
end

---Fills a buffer with `count` KiB of text.
---@param buf integer
---@param count integer
local function fill(buf, count)
  local lines = {}
  for _ = 1, count do
    table.insert(lines, string.rep("x", 1023))
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
end

-- Regression: the size came from fs_stat of the file, and this runs before the
-- write — so it described the previous version. A buffer that grew past the
-- budget was formatted synchronously anyway, which is what the budget exists to
-- prevent.
T["large files"]["measures the buffer rather than the file on disk"] = function()
  local path = vim.fn.tempname()
  vim.fn.writefile({ "small: yes" }, path)
  vim.cmd.edit({ args = { path } })

  local buf = vim.api.nvim_get_current_buf()
  fill(buf, 600)

  eq(on_save()(buf), nil)
  eq(said("exceeds the synchronous budget"), true)
end

-- The same measurement, where fs_stat had nothing at all to report.
T["large files"]["a buffer that has never been saved is measured too"] = function()
  local buf = vim.api.nvim_create_buf(true, false)
  fill(buf, 600)

  eq(on_save()(buf), nil)
  eq(said("exceeds the synchronous budget"), true)
end

-- And the other direction: what is about to be written is small, whatever the
-- file it replaces weighs.
T["large files"]["a small buffer over a large file is still formatted"] = function()
  local path = vim.fn.tempname()
  local big = {}
  for _ = 1, 600 do
    table.insert(big, string.rep("x", 1023))
  end
  vim.fn.writefile(big, path)
  vim.cmd.edit({ args = { path } })

  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "small: yes" })

  eq(type(on_save()(buf)), "table")
  eq(said("exceeds"), false)
end

return T
