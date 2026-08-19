-- The colourscheme, from this configuration's side.
--
-- Driven by tests/fixtures/theme-choice, the same corpus the Go reader uses:
-- "Go accepts, Lua rejects" should be a failing test rather than a machine
-- behaving differently from the editor running on it.

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local theme = require("chroma.theme")

local T = new_set({
  hooks = {
    pre_case = function()
      theme.forget()
    end,
    post_case = function()
      theme.forget()
      package.loaded["plugins.ui"] = nil
    end,
  },
})

---The root of this tree, resolved from this file so it is found from any
---working directory.
---@return string
local function root()
  local here = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h:h")
  return here
end

---@param ... string path under tests/fixtures/theme-choice
---@return string
local function fixtures(...)
  return vim.fs.joinpath(root(), "tests", "fixtures", "theme-choice", ...)
end

---@param ... string
---@return string[] paths
local function corpus(...)
  local dir = fixtures(...)
  local paths = {}
  for name, filetype in vim.fs.dir(dir) do
    if filetype == "file" then
      table.insert(paths, vim.fs.joinpath(dir, name))
    end
  end
  table.sort(paths)
  return paths
end

---The catalogue every choice fixture is checked against, which is a fixture too.
---@return table
local function against()
  local catalogue, found, err = theme.load_catalogue(fixtures("catalogue.json"))
  eq({ err, found }, { nil, true })
  return catalogue
end

T["corpus"] = new_set()

T["corpus"]["every valid choice loads"] = function()
  local catalogue = against()
  local paths = corpus("valid")
  -- An empty corpus would make this pass for nothing.
  eq(#paths > 0, true)

  for _, path in ipairs(paths) do
    local choice, found, err = theme.load(path, catalogue)
    eq({ path, err }, { path, nil })
    eq({ path, found }, { path, true })
    eq({ path, choice.schema }, { path, theme.SCHEMA })
    eq({ path, theme.get(catalogue, choice.theme) ~= nil }, { path, true })
  end
end

T["corpus"]["every invalid choice is refused"] = function()
  local catalogue = against()
  local paths = corpus("invalid")
  eq(#paths > 0, true)

  for _, path in ipairs(paths) do
    local choice, found, err = theme.load(path, catalogue)
    eq({ path, choice }, { path, nil })
    eq({ path, type(err) }, { path, "string" })
    -- The file is there, so this is a problem to report rather than somebody
    -- who never chose.
    eq({ path, found }, { path, true })
  end
end

T["corpus"]["every valid catalogue loads"] = function()
  local paths = corpus("catalogues", "valid")
  eq(#paths > 0, true)

  for _, path in ipairs(paths) do
    local catalogue, found, err = theme.load_catalogue(path)
    eq({ path, err }, { path, nil })
    eq({ path, found }, { path, true })
    eq({ path, theme.get(catalogue, catalogue.default) ~= nil }, { path, true })
  end
end

T["corpus"]["every invalid catalogue is refused"] = function()
  local paths = corpus("catalogues", "invalid")
  eq(#paths > 0, true)

  for _, path in ipairs(paths) do
    local catalogue, _, err = theme.load_catalogue(path)
    eq({ path, catalogue }, { path, nil })
    eq({ path, type(err) }, { path, "string" })
  end
end

T["absence"] = new_set()

T["absence"]["no choice is not a problem"] = function()
  local choice, found, err = theme.load(vim.fs.joinpath(vim.fn.tempname(), "theme.json"), against())
  eq({ choice, found, err }, { nil, false, nil })
end

T["absence"]["no catalogue is not a problem"] = function()
  local catalogue, found, err = theme.load_catalogue(vim.fs.joinpath(vim.fn.tempname(), "themes.json"))
  eq({ catalogue, found, err }, { nil, false, nil })
end

-- A dangling symlink is a choice somebody made pointing at nothing, and it must
-- not read as a choice nobody made — that would silently swap their
-- colourscheme for the default. Must match cli/internal/theme/theme.go.
T["absence"]["a dangling link is a problem, not an absence"] = function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local path = vim.fs.joinpath(dir, "theme.json")
  vim.uv.fs_symlink(vim.fs.joinpath(dir, "gone.json"), path)

  local choice, found, err = theme.load(path, against())
  eq(choice, nil)
  eq(found, true)
  eq(type(err), "string")

  vim.fn.delete(dir, "rf")
end

-- Nothing to check against is not the same as failing the check: a choice made
-- where no catalogue can be read is still that person's choice.
T["absence"]["a choice is not refused for want of a catalogue"] = function()
  local choice, _, err = theme.load(fixtures("valid", "the-other-one.json"), nil)
  eq(err, nil)
  eq(choice.theme, "everforest")
end

T["release"] = new_set()

T["release"]["the shipped catalogue loads"] = function()
  local catalogue, found, err = theme.load_catalogue()
  eq({ err, found }, { nil, true })
  eq(#catalogue.themes > 1, true)
end

-- The last resort in theme.lua names a colourscheme, which is the one thing
-- this file is not supposed to do. It is allowed to, on the condition held
-- here: the release must actually offer it.
T["release"]["the fallback is a theme this release offers"] = function()
  local catalogue = theme.load_catalogue()
  eq(theme.get(catalogue, theme.FALLBACK) ~= nil, true)
end

---The colourscheme specs in plugins.ui: loaded before anything else can render
---against the default, and gated on a choice. snacks.nvim is loaded first too
---and is not one of these, which is why the gate is part of the description
---rather than the priority alone.
---@return table[]
local function colourscheme_specs()
  local specs = {}
  for _, spec in ipairs(require("plugins.ui")) do
    if spec.priority == 1000 and type(spec.enabled) == "function" then
      table.insert(specs, spec)
    end
  end
  return specs
end

---Runs `fn` with one theme chosen.
---@param id string
---@param fn function
local function choosing(id, fn)
  local home = vim.fn.tempname()
  vim.fn.mkdir(vim.fs.joinpath(home, "chroma"), "p")
  vim.fn.writefile(
    { vim.json.encode({ schema = theme.SCHEMA, theme = id }) },
    vim.fs.joinpath(home, "chroma", "theme.json")
  )

  local saved = vim.env.XDG_CONFIG_HOME
  vim.env.XDG_CONFIG_HOME = home
  theme.forget()
  package.loaded["plugins.ui"] = nil

  local ok, err = pcall(fn)

  vim.env.XDG_CONFIG_HOME = saved
  theme.forget()
  package.loaded["plugins.ui"] = nil
  vim.fn.delete(home, "rf")
  assert(ok, err)
end

-- Every theme the catalogue offers has to have a spec that draws it, and no
-- choice may leave two of them enabled. A name the catalogue offers with no
-- spec behind it is an editor that comes up in no colourscheme at all; two at
-- once is a colourscheme decided by load order.
T["release"]["every theme offered is drawn by exactly one spec"] = function()
  local catalogue = theme.load_catalogue()

  for _, one in ipairs(catalogue.themes) do
    choosing(one.id, function()
      eq({ one.id, theme.chosen() }, { one.id, one.id })
      eq({ one.id, theme.colorscheme() }, { one.id, one.colorscheme })

      local drawing = {}
      for _, spec in ipairs(colourscheme_specs()) do
        if spec.enabled() then
          table.insert(drawing, spec.name)
        end
      end
      eq({ one.id, drawing }, { one.id, { one.id } })
    end)
  end
end

-- And every colourscheme spec is one the catalogue offers, which is the other
-- direction: a spec gated on a name no release offers never loads, silently.
T["release"]["every spec is a theme the catalogue offers"] = function()
  local catalogue = theme.load_catalogue()
  local specs = colourscheme_specs()

  -- No specs at all would make this pass for nothing, and would mean the search
  -- above found none either.
  eq(#specs, #catalogue.themes)

  for _, spec in ipairs(specs) do
    eq({ spec.name, theme.get(catalogue, spec.name) ~= nil }, { spec.name, true })
  end
end

return T
