-- The Ansible component after its runner was retired.
--
-- `nvim-ansible` can run a playbook by inferring the command from the buffer,
-- and Chroma no longer offers that: how a repository runs Ansible is what its
-- own task file says. The plugin stays for what only it does — the
-- `yaml.ansible` filetype, `K` through `ansible-doc`, `gf` into a role.
--
-- What is worth testing is not the deletion. It is that the runner cannot come
-- back through a side door: another spec, another keymap, a command somewhere
-- else. So this reads the plugin specs as text as well as as data.

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local components = require("chroma.components")

---Every plugin spec file, as source.
---@return table<string, string>
local function specs()
  local here = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h:h")
  local directory = vim.fs.joinpath(here, "lua", "plugins")

  local sources = {}
  for name, kind in vim.fs.dir(directory) do
    if kind == "file" and name:match("%.lua$") then
      sources[name] = table.concat(vim.fn.readfile(vim.fs.joinpath(directory, name)), "\n")
    end
  end
  return sources
end

local T = new_set()

-- ---------------------------------------------------------------------------
-- The runner is gone, and stays gone

T["the runner"] = new_set()

T["the runner"]["is not called from any plugin spec"] = function()
  for name, source in pairs(specs()) do
    -- Comments are text too, and this repository's comments explain the
    -- decision, so only a call counts.
    if source:find('require("ansible")%s*%.%s*run') or source:find('require("ansible")%s*%(') then
      error(("%s reaches nvim-ansible's own runner"):format(name))
    end
  end
end

T["the runner"]["has no keymap anywhere"] = function()
  for name, source in pairs(specs()) do
    if source:find("<leader>ar", 1, true) then
      error(("%s binds <leader>ar, which was the inferred runner"):format(name))
    end
  end
end

T["the runner"]["leaves the plugin itself in place"] = function()
  -- The deletion is of one execution path, not of Ansible support: without
  -- this plugin there is no `yaml.ansible`, and without that filetype there is
  -- no ansible-lint and no language server.
  local found = false
  for _, spec in ipairs(require("plugins.devops")) do
    if spec[1] == "mfussenegger/nvim-ansible" then
      found = true
      eq(spec.keys, nil)
    end
  end
  eq(found, true)
end

-- ---------------------------------------------------------------------------
-- What the component asks of the machine

T["the component"] = new_set()

T["the component"]["requires no executable at all"] = function()
  -- The required `ansible` existed for one stated reason — running a playbook
  -- from the buffer — and that reason has gone. A required tool whose
  -- justification no longer exists is a preflight failure nobody can act on.
  local ansible = components.load().ansible

  eq(ansible.tools.required, {})
  eq(ansible.tools.recommended, {})
end

T["the component"]["asks for ansible-doc, optionally"] = function()
  local optional = components.load().ansible.tools.optional

  eq(#optional, 1)
  eq(optional[1].id, "ansible-doc")
  eq(optional[1].reason ~= nil and optional[1].reason ~= "", true)
end

T["the component"]["still contributes what only the plugin can"] = function()
  local ansible = components.load().ansible

  eq(vim.tbl_contains(ansible.nvim.plugins, "nvim-ansible"), true)
  eq(vim.tbl_contains(ansible.nvim.servers, "ansiblels"), true)
  eq(vim.tbl_contains(ansible.nvim.linters, "ansible_lint"), true)
end

return T
