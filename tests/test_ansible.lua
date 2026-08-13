-- The Ansible component, and the runner that may not come back.
--
-- `nvim-ansible` can run a playbook by inferring the command from the buffer,
-- and that is the path Chroma retired. The planner does not undo it: it asks,
-- shows the exact array and waits for a yes. So these cases still guard that the
-- plugin cannot reach its own runner and that no spec binds a key to it.

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

T["the runner"]["has no keymap in any plugin spec"] = function()
  -- `<leader>ar` exists again and belongs to `chroma-ansible`, which asks for
  -- everything it runs. A plugin spec binding it would be the buffer-inferred
  -- runner back under a key that now means something else entirely.
  --
  -- Comments are skipped, as in the case above: this repository's comments
  -- explain the decisions, and the heading gate has to be able to name the two
  -- keys that earned it.
  for name, source in pairs(specs()) do
    for number, line in ipairs(vim.split(source, "\n", { plain = true })) do
      if not line:match("^%s*%-%-") and line:find("<leader>ar", 1, true) then
        error(("%s:%d binds <leader>ar, which is the planner's key"):format(name, number))
      end
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

T["the component"]["requires both tools the planner promises"] = function()
  -- The required `ansible` was dropped when the buffer-driven runner went,
  -- because a required tool whose justification has gone is a preflight failure
  -- nobody can act on. The justification is back and it is a different one:
  -- `<leader>ar` runs playbooks and lists inventories, so a machine without
  -- either binary cannot do what the component says it does.
  --
  -- Both are required rather than one required and one recommended: both ship
  -- in ansible-core, so requiring both costs nobody an extra installation and
  -- stops a partial install from looking healthy.
  local required = components.load().ansible.tools.required

  eq(#required, 2)
  eq({ required[1].id, required[2].id }, { "ansible-playbook", "ansible-inventory" })
  for _, tool in ipairs(required) do
    eq({ tool.id, tool.reason ~= nil and tool.reason ~= "" }, { tool.id, true })
  end
  eq(components.load().ansible.tools.recommended, {})
end

T["the component"]["brings the planner up"] = function()
  eq(components.load().ansible.nvim.modules, { "chroma-ansible" })
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
