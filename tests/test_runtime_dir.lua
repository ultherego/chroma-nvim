-- The XDG runtime directory check, in both of the places it lives.

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local COPIES = {
  { label = "ansible-vault", module = "ansible-vault.runtime", subdirectory = "ansible-vault.nvim" },
  { label = "terraform", module = "terraform.runtime", subdirectory = "terraform.nvim" },
}

local OWNER_ONLY = tonumber("700", 8)

local saved_runtime_dir
local sandbox

local T = new_set({
  hooks = {
    pre_case = function()
      saved_runtime_dir = vim.env.XDG_RUNTIME_DIR
      sandbox = vim.fn.tempname()
      vim.fn.mkdir(sandbox, "p")
    end,
    post_case = function()
      vim.env.XDG_RUNTIME_DIR = saved_runtime_dir
      vim.fn.delete(sandbox, "rf")
    end,
  },
})

---Runs both copies against one value of XDG_RUNTIME_DIR.
---@param value string|nil
---@return table results keyed by label, each { path, err }
local function ask_both(value)
  local results = {}
  for _, copy in ipairs(COPIES) do
    vim.env.XDG_RUNTIME_DIR = value
    local path, err = require(copy.module).secure_dir(copy.subdirectory)
    results[copy.label] = { path = path, err = err }
  end
  return results
end

---Both copies must refuse, for the same stated reason.
---@param value string|nil
---@param pattern string
local function both_refuse(value, pattern)
  local results = ask_both(value)
  for _, copy in ipairs(COPIES) do
    local result = results[copy.label]
    eq({ copy.label, result.path }, { copy.label, nil })
    eq({ copy.label, result.err ~= nil and result.err:match(pattern) ~= nil }, { copy.label, true })
  end
end

---A directory created with the mode a real runtime directory has.
---@param name string
---@param permissions string
---@return string
local function directory(name, permissions)
  local path = sandbox .. "/" .. name
  vim.fn.mkdir(path, "p")
  vim.fn.setfperm(path, permissions)
  return path
end

T["refuses an unset variable"] = function()
  both_refuse(nil, "not set")
end

T["refuses an empty variable"] = function()
  both_refuse("", "not set")
end

T["refuses a relative path"] = function()
  both_refuse("some/relative/dir", "absolute")
end

-- isabsolutepath() answers 1 for a tilde path, which is not absolute until
-- something expands it, and nothing here does.
T["refuses a tilde path"] = function()
  both_refuse("~/runtime", "absolute")
end

T["refuses a directory that does not exist"] = function()
  both_refuse(sandbox .. "/nowhere", "does not exist")
end

T["refuses a file"] = function()
  local path = sandbox .. "/a-file"
  vim.fn.writefile({ "x" }, path)
  both_refuse(path, "not a directory")
end

-- The old check was "set, and stat succeeds", which accepted both of these.
T["refuses a group- and world-readable directory"] = function()
  both_refuse(directory("loose", "rwxr-xr-x"), "expected 0700")
end

T["refuses a world-writable directory"] = function()
  both_refuse(directory("wide", "rwxrwxrwx"), "expected 0700")
end

T["accepts a private directory and creates a private subdirectory"] = function()
  local root = directory("good", "rwx------")
  local results = ask_both(root)

  for _, copy in ipairs(COPIES) do
    local result = results[copy.label]
    eq({ copy.label, result.err }, { copy.label, nil })
    eq({ copy.label, result.path }, { copy.label, root .. "/" .. copy.subdirectory })

    local stat = vim.uv.fs_stat(result.path)
    eq({ copy.label, stat ~= nil }, { copy.label, true })
    eq({ copy.label, stat.type }, { copy.label, "directory" })
    eq({ copy.label, stat.mode % tonumber("1000", 8) }, { copy.label, OWNER_ONLY })
  end
end

T["is repeatable once the subdirectory exists"] = function()
  local root = directory("twice", "rwx------")
  ask_both(root)
  local results = ask_both(root)

  for _, copy in ipairs(COPIES) do
    eq({ copy.label, results[copy.label].err }, { copy.label, nil })
  end
end

-- A subdirectory that is already there proves nothing on its own; it is checked
-- whether this call created it or not.
T["refuses a subdirectory that was loosened after creation"] = function()
  local root = directory("tampered", "rwx------")
  for _, copy in ipairs(COPIES) do
    local sub = root .. "/" .. copy.subdirectory
    vim.fn.mkdir(sub, "p")
    vim.fn.setfperm(sub, "rwxrwxrwx")
  end
  both_refuse(root, "expected 0700")
end

-- ---------------------------------------------------------------------------
-- The callers refuse rather than falling back

T["callers"] = new_set()

T["callers"]["terraform will not write a plan to an unsafe directory"] = function()
  vim.env.XDG_RUNTIME_DIR = directory("unsafe-plan", "rwxr-xr-x")

  local notices = {}
  local notify = vim.notify
  vim.notify = function(message, _)
    table.insert(notices, tostring(message))
  end

  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  vim.fn.writefile({ 'resource "null_resource" "x" {}' }, dir .. "/main.tf")
  require("terraform").setup({})
  vim.cmd.edit({ args = { dir .. "/main.tf" } })
  require("terraform").plan()

  vim.notify = notify
  vim.cmd("silent! %bwipeout!")

  local said = table.concat(notices, " "):gsub("\n", " ")
  eq(said:match("expected 0700") ~= nil, true)
  eq(said:match("sensitive values") ~= nil, true)
end

T["callers"]["vault will not stage a password in an unsafe directory"] = function()
  vim.env.XDG_RUNTIME_DIR = directory("unsafe-password", "rwxr-xr-x")

  -- The staging path is reached through the CLI wrapper whenever a password is
  -- carried rather than read from ansible.cfg.
  local _, err = require("ansible-vault.cli").encrypt_document("plain\n", { auth = { password = "secret" } })

  eq(type(err), "string")
  eq(err:match("expected 0700") ~= nil, true)
  eq(err:match("vault_password_file") ~= nil, true)
end

return T
