-- The keymaps are written down in two documents, and neither may drift from
-- the code.
--
-- `doc/chroma-nvim.txt` is the reference, with the reasoning attached, and
-- `doc/KEYMAPS.md` is the cheat sheet, browsable outside the editor. Two lists
-- of the same facts is a liability unless something checks that they agree,
-- which is the arrangement the duplicated `runtime.lua` already lives under:
-- the duplication is allowed because a test runs every case against both.
--
-- A mapping that exists and is documented nowhere is the failure this mostly
-- exists for. A document naming a mapping that no longer exists is the other
-- direction, and is worse — it is a promise the editor does not keep.

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local root = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h:h")

---Reads a file whole. `vim.fn.readfile` rather than `io.open`, which selene
---forbids and which would be the wrong tool anyway.
---@param parts string[] path components below the repository root
---@return string[] lines
local function lines_of(parts)
  return vim.fn.readfile(vim.fs.joinpath(root, unpack(parts)))
end

---Every `<leader>` mapping the configuration defines.
---
---Read out of the source rather than out of a running editor on purpose: most
---of these are lazy.nvim `keys` specs and component-gated module setups, so
---the set an editor has depends on which components are enabled, and the
---question here is what the repository defines at all.
---
---Comment lines are skipped. A comment that mentions a keymap is prose about
---it, not a definition of it, and this file would otherwise demand that every
---aside in a header block be documented as a mapping.
---@return table<string, boolean>
local function defined()
  local found = {}

  for _, path in ipairs(vim.fn.globpath(vim.fs.joinpath(root, "lua"), "**/*.lua", false, true)) do
    for _, line in ipairs(vim.fn.readfile(path)) do
      if not line:match("^%s*%-%-") then
        -- A mapping is written as a string literal wherever it is defined:
        -- `map("n", "<leader>bd", …)`, `{ "<leader>ff", … }`, and the
        -- which-key spec's group prefixes.
        for lhs in line:gmatch('"(<leader>[^"]*)"') do
          found[lhs] = true
        end
      end
    end
  end

  return found
end

---Every `<leader>` mapping a document names.
---@param lines string[]
---@return table<string, boolean>
local function documented(lines)
  local found = {}

  for _, line in ipairs(lines) do
    for lhs in line:gmatch("(<leader>[%w?=]*)") do
      found[lhs] = true
    end
  end

  return found
end

---The keys of `wanted` that `have` does not carry, sorted so a failure reads
---the same way twice.
---@param wanted table<string, boolean>
---@param have table<string, boolean>
---@return string[]
local function missing_from(wanted, have)
  local gaps = {}

  for lhs in pairs(wanted) do
    if not have[lhs] then
      table.insert(gaps, lhs)
    end
  end

  table.sort(gaps)
  return gaps
end

local T = new_set()

local DOCUMENTS = {
  ["doc/KEYMAPS.md"] = { "doc", "KEYMAPS.md" },
  ["doc/chroma-nvim.txt"] = { "doc", "chroma-nvim.txt" },
}

-- ---------------------------------------------------------------------------
-- Nothing the configuration defines is undocumented

T["documented"] = new_set()

for name, parts in pairs(DOCUMENTS) do
  T["documented"]["every mapping appears in " .. name] = function()
    eq(missing_from(defined(), documented(lines_of(parts))), {})
  end
end

T["documented"]["there is something to check"] = function()
  -- Both directions above are satisfied by a configuration that maps nothing
  -- and documents nothing, and the pattern going wrong would produce exactly
  -- that. The number is a floor rather than a count: adding a mapping must not
  -- fail this, and losing most of them must.
  eq(vim.tbl_count(defined()) > 80, true)
end

-- ---------------------------------------------------------------------------
-- Nothing documented has stopped existing

T["real"] = new_set()

for name, parts in pairs(DOCUMENTS) do
  T["real"]["every mapping " .. name .. " names still exists"] = function()
    eq(missing_from(documented(lines_of(parts)), defined()), {})
  end
end

return T
