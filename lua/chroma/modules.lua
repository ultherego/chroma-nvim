-- The modules an enabled selection brings up.
--
-- This is three lines that could have stayed in init.lua, and did. They are
-- here because init.lua is the one file a test cannot load — it starts
-- lazy.nvim — so while the decision lived there, "Terraform selected sets up
-- the Terraform module and not the others" could only ever be checked by asking
-- the resolver the same question the code asked, which proves the resolver and
-- nothing else. Moving the decision one file down makes it something a test can
-- run and a mutation can break.

local M = {}

---Sets up every module the enabled components contribute, in name order.
---
---Sorted rather than in the order the components declare it, because
---`contributions` sorts: these modules only register commands, mappings and
---autocmds, none of them looks at another, and a deterministic order is worth
---more here than an order that would mean something if they did. If one ever
---does depend on another, that dependency belongs in `requires` and this loop
---has to walk the graph rather than a sorted list.
---
---Which modules those are is `components/*.json`'s to say. Nothing here maps a
---component to a module: the loop asks what is switched on and sets up what it
---brings, so adding a component with a module of its own needs no change here.
---@param opts table|nil passed to each module's setup
---@return string[] names the modules that were set up
function M.setup(opts)
  local names = require("chroma.components").contributions("modules", (require("chroma.state").enabled_ids()))

  for _, name in ipairs(names) do
    require(name).setup(opts)
  end

  return names
end

return M
