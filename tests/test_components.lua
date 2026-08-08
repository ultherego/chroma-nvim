-- The component contract: the one interface the Lua configuration and the Go
-- CLI share. These cases guard both the files this repository ships and the
-- reader that both sides model.

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local components = require("chroma.components")

local T = new_set()

-- ---------------------------------------------------------------------------
-- What this repository actually ships

T["shipped"] = new_set()

T["shipped"]["every file is valid and unique"] = function()
  local loaded, problems = components.load()
  eq(problems, {})
  -- A contract with nothing in it would satisfy every other case here.
  eq(vim.tbl_count(loaded) > 0, true)
  eq(loaded.core ~= nil, true)
end

T["shipped"]["resolves: no unknown dependency, no cycle"] = function()
  local loaded = components.load()
  eq(components.resolve_problems(loaded), {})
end

-- The installer's plan is built from this: a component whose Neovim side names
-- a module that does not exist would install something that cannot load.
T["shipped"]["names modules that exist"] = function()
  local loaded = components.load()
  local missing = {}

  for id, component in pairs(loaded) do
    for _, module in ipairs(component.nvim.modules or {}) do
      if not pcall(require, module) then
        table.insert(missing, ("%s: %s"):format(id, module))
      end
    end
    for _, plugin in ipairs(component.nvim.plugins or {}) do
      if not pcall(require, plugin) then
        table.insert(missing, ("%s: %s"):format(id, plugin))
      end
    end
  end

  eq(missing, {})
end

-- Every tool is a name the installer will look for, so a typo is a tool that
-- can never be satisfied and a component that can never be complete.
T["shipped"]["every tool names something to look for"] = function()
  local loaded = components.load()
  local broken = {}

  for id, component in pairs(loaded) do
    for _, level in ipairs({ "required", "recommended", "optional" }) do
      for _, tool in ipairs(component.tools[level]) do
        local names = tool.any or (tool.id and { tool.id })
        if not names or #names == 0 then
          table.insert(broken, ("%s: a %s tool has neither id nor any"):format(id, level))
        elseif not tool.reason or tool.reason == "" then
          table.insert(broken, ("%s: %s has no reason"):format(id, table.concat(names, "|")))
        end
      end
    end
  end

  eq(broken, {})
end

-- ---------------------------------------------------------------------------
-- The reader, against contracts this repository does not ship

T["reader"] = new_set()

---Runs `fn` with `components/` pointed at a throwaway directory holding `files`.
---@param files table<string, string>
---@param fn function
local function with_contract(files, fn)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(vim.fs.joinpath(dir, "components"), "p")
  for name, contents in pairs(files) do
    vim.fn.writefile(vim.split(contents, "\n"), vim.fs.joinpath(dir, "components", name))
  end

  -- The module resolves its directory from its own path, so a copy of it in the
  -- throwaway tree reads that tree's components.
  vim.fn.mkdir(vim.fs.joinpath(dir, "lua", "chroma"), "p")
  local source =
    vim.fn.fnamemodify(vim.fn.resolve(vim.api.nvim_get_runtime_file("lua/chroma/components.lua", false)[1]), ":p")
  vim.fn.writefile(vim.fn.readfile(source), vim.fs.joinpath(dir, "lua", "chroma", "components.lua"))

  local loaded = loadfile(vim.fs.joinpath(dir, "lua", "chroma", "components.lua"))()
  local ok, err = pcall(fn, loaded)
  vim.fn.delete(dir, "rf")
  assert(ok, err)
end

T["reader"]["reports a file that is not JSON"] = function()
  with_contract({ ["broken.json"] = "{ not json" }, function(module)
    local loaded, problems = module.load()
    eq(loaded, {})
    eq(#problems, 1)
    eq(problems[1]:find("is not valid JSON") ~= nil, true)
  end)
end

-- The version exists to make a mismatch loud. Reading a newer component as
-- though the difference did not matter is the failure it is there to prevent.
T["reader"]["refuses a contract version it does not understand"] = function()
  with_contract({
    ["future.json"] = '{ "contract": 99, "id": "future", "requires": [] }',
  }, function(module)
    local loaded, problems = module.load()
    eq(loaded, {})
    eq(#problems, 1)
    eq(problems[1]:find("declares contract 99") ~= nil, true)
  end)
end

-- `require` for `requires` decodes cleanly and leaves the component with no
-- dependencies at all. A contract that decides what gets installed cannot have
-- a typo that means "install less than asked".
T["reader"]["refuses a field it does not know"] = function()
  with_contract({
    ["typo.json"] = '{ "contract": 2, "id": "typo", "require": ["core"] }',
  }, function(module)
    local loaded, problems = module.load()
    eq(loaded, {})
    eq(#problems, 1)
    eq(problems[1]:find("unknown field") ~= nil, true)
  end)
end

T["reader"]["refuses an unknown field inside a tool"] = function()
  with_contract({
    ["deep.json"] = '{ "contract": 2, "id": "deep", "tools": { "required": [ { "id": "x", "reason": "y", "min": "1.0" } ] } }',
  }, function(module)
    local _, problems = module.load()
    eq(#problems, 1)
    eq(problems[1]:find("unknown field") ~= nil, true)
  end)
end

-- With both set the reader picks one and drops the other in silence.
T["reader"]["refuses a tool with both id and any"] = function()
  with_contract({
    ["both.json"] = '{ "contract": 2, "id": "both", "tools": { "required": [ { "id": "x", "any": ["y"], "reason": "z" } ] } }',
  }, function(module)
    local _, problems = module.load()
    eq(#problems, 1)
    eq(problems[1]:find("both id and any") ~= nil, true)
  end)
end

T["reader"]["refuses a tool with neither, and one with no reason"] = function()
  with_contract({
    ["neither.json"] = '{ "contract": 2, "id": "neither", "tools": { "required": [ { "reason": "z" } ] } }',
  }, function(module)
    local _, problems = module.load()
    eq(#problems, 1)
    eq(problems[1]:find("neither id nor any") ~= nil, true)
  end)

  with_contract({
    ["silent.json"] = '{ "contract": 2, "id": "silent", "tools": { "required": [ { "id": "x" } ] } }',
  }, function(module)
    local _, problems = module.load()
    eq(#problems, 1)
    eq(problems[1]:find("no reason") ~= nil, true)
  end)
end

-- Contract 1 had no version field; a file that carries one is describing a
-- schema this does not know, whatever else it says.
T["reader"]["refuses a version under contract 1"] = function()
  with_contract({
    ["old.json"] = '{ "contract": 1, "id": "old", "tools": { "required": [ { "id": "x", "reason": "y", "version": { "min": "1.0" } } ] } }',
  }, function(module)
    local _, problems = module.load()
    eq(#problems, 1)
    eq(problems[1]:find("declares contract 1") ~= nil, true)
  end)
end

T["reader"]["refuses a version that says two things or nothing"] = function()
  local cases = {
    { json = '{ "exact": "1.2", "min": "1.0" }', expect = "exact together with min or max" },
    { json = "{}", expect = "says nothing" },
    { json = '{ "min": "2.0", "max": "1.0" }', expect = "above max" },
    { json = '{ "min": "latest" }', expect = "not a version" },
    { json = '{ "minimum": "1.0" }', expect = "unknown field" },
  }

  for _, case in ipairs(cases) do
    with_contract({
      ["v.json"] = ('{ "contract": 2, "id": "v", "tools": { "required": [ { "id": "x", "reason": "y", "version": %s } ] } }'):format(
        case.json
      ),
    }, function(module)
      local _, problems = module.load()
      eq({ case.json, #problems }, { case.json, 1 })
      eq({ case.json, problems[1]:find(case.expect, 1, true) ~= nil }, { case.json, true })
    end)
  end
end

T["reader"]["compares versions the way the Go reader does"] = function()
  local c = require("chroma.components")
  eq(c.compare_versions("1.2.3", "1.2.3"), 0)
  eq(c.compare_versions("1.2", "1.2.0"), 0)
  eq(c.compare_versions("v2.19", "2.19"), 0)
  eq(c.compare_versions("0.26.1", "0.26.9"), -1)
  eq(c.compare_versions("1.10", "1.9"), 1)
  eq(c.compare_versions("2.0.0-rc1", "2.0.0"), 0)

  eq(c.looks_like_version("0.26.1"), true)
  eq(c.looks_like_version("v1.14.3"), true)
  eq(c.looks_like_version("latest"), false)
  eq(c.looks_like_version(""), false)
end

T["reader"]["reports two components claiming one id"] = function()
  local one = '{ "contract": 2, "id": "same", "requires": [] }'
  with_contract({ ["a.json"] = one, ["b.json"] = one }, function(module)
    local loaded, problems = module.load()
    eq(vim.tbl_count(loaded), 1)
    eq(#problems, 1)
    eq(problems[1]:find("already declared") ~= nil, true)
  end)
end

T["reader"]["reports a dependency that is not declared"] = function()
  with_contract({
    ["orphan.json"] = '{ "contract": 2, "id": "orphan", "requires": ["nothing"] }',
  }, function(module)
    local problems = module.resolve_problems(module.load())
    eq(#problems, 1)
    eq(problems[1]:find('requires "nothing"') ~= nil, true)
  end)
end

-- A cycle is an installation plan with no first step, and nothing else in the
-- resolver would notice: every dependency in one exists.
T["reader"]["reports a dependency cycle"] = function()
  with_contract({
    ["a.json"] = '{ "contract": 2, "id": "a", "requires": ["b"] }',
    ["b.json"] = '{ "contract": 2, "id": "b", "requires": ["a"] }',
  }, function(module)
    local problems = module.resolve_problems(module.load())
    eq(#problems > 0, true)
    eq(problems[1]:find("cycle") ~= nil, true)
  end)
end

T["reader"]["accepts a component that reaches core through another"] = function()
  with_contract({
    ["core.json"] = '{ "contract": 2, "id": "core", "requires": [] }',
    ["mid.json"] = '{ "contract": 2, "id": "mid", "requires": ["core"] }',
    ["leaf.json"] = '{ "contract": 2, "id": "leaf", "requires": ["mid", "core"] }',
  }, function(module)
    -- A diamond is not a cycle, and a resolver that cannot tell them apart
    -- refuses perfectly ordinary contracts.
    eq(module.resolve_problems(module.load()), {})
  end)
end

-- ---------------------------------------------------------------------------
-- Tools

T["tools"] = new_set()

T["tools"]["flattens the levels in order"] = function()
  local loaded = components.load()
  local tools = components.tools(loaded.core)
  eq(#tools > 0, true)
  eq(tools[1].level, "required")

  local seen = {}
  for _, tool in ipairs(tools) do
    seen[tool.level] = true
  end
  eq(seen.required, true)
end

T["tools"]["an alternative is satisfied by either name"] = function()
  eq(components.satisfied({ names = { "definitely-not-a-real-binary", "sh" } }), true)
  eq(components.satisfied({ names = { "definitely-not-a-real-binary" } }), false)
end

return T
