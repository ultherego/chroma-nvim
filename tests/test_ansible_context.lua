-- Which directory Ansible runs in, and which file it is handed.
--
-- Everything here is built on a real temporary tree rather than on stubbed
-- filesystem calls, because every rule in this module is a question about the
-- filesystem: is it a directory, may this user read it, does an `ansible.cfg`
-- sit in it, does the path still lead where it led a moment ago. A stub would
-- test the stub.
--
-- `doc/chroma-ansible-design.md`, sections 3 and 4.

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local context = require("chroma-ansible.context")

local tree

---Builds the tree each case starts from, and answers with its canonical root.
---
---`realpath` on the root, because a temporary directory is very often reached
---through a symlink — `/tmp` is one on plenty of systems — and every path this
---module returns is canonical. Comparing against the uncanonical root would
---fail for a reason that has nothing to do with the code.
---@return string
local function build()
  local root = vim.uv.fs_realpath(vim.fn.tempname()) or vim.fn.tempname()
  vim.fn.mkdir(root, "p")
  root = vim.uv.fs_realpath(root)

  vim.fn.mkdir(vim.fs.joinpath(root, "work", "operations", "plays"), "p")
  vim.fn.writefile({ "[defaults]" }, vim.fs.joinpath(root, "work", "operations", "ansible.cfg"))
  vim.fn.writefile({ "- hosts: all" }, vim.fs.joinpath(root, "work", "operations", "plays", "site_upgrade.yml"))
  vim.fn.writefile({ "- hosts: all" }, vim.fs.joinpath(root, "work", "operations", "plays", "other.YAML"))
  vim.fn.writefile({ "notes" }, vim.fs.joinpath(root, "work", "operations", "plays", "readme.txt"))

  -- Beside the playbook's tree rather than inside it, which is the layout the
  -- inventory cases below are about: `work/operations` runs the playbook and the
  -- sources live one level up.
  vim.fn.mkdir(vim.fs.joinpath(root, "work", "inventories", "beta"), "p")
  vim.fn.writefile({ "all:" }, vim.fs.joinpath(root, "work", "inventories", "beta", "hosts.yml"))

  return root
end

---A path inside the tree.
---@param ... string
---@return string
local function at(...)
  return vim.fs.joinpath(tree, ...)
end

local T = new_set({
  hooks = {
    pre_case = function()
      tree = build()
    end,
    post_case = function()
      vim.fn.delete(tree, "rf")
    end,
  },
})

-- ---------------------------------------------------------------------------
-- The buffer suggestion

T["suggestion"] = new_set()

T["suggestion"]["offers a readable .yml file behind the buffer"] = function()
  eq(
    context.suggestion(at("work", "operations", "plays", "site_upgrade.yml")),
    at("work", "operations", "plays", "site_upgrade.yml")
  )
end

T["suggestion"]["accepts .yaml, and does not care about case"] = function()
  eq(context.suggestion(at("work", "operations", "plays", "other.YAML")) ~= nil, true)
end

T["suggestion"]["offers nothing for a buffer with no file"] = function()
  -- A dashboard, a terminal, an unnamed buffer. Not a failure, and not
  -- reported as one: there is simply nothing to suggest.
  eq(context.suggestion(""), nil)
  eq(context.suggestion(nil), nil)
end

T["suggestion"]["offers nothing for a name that only looks like a path"] = function()
  -- oil and other plugins name buffers with URIs. The suffix test alone would
  -- accept this one; resolving it is what refuses it.
  eq(context.suggestion("oil://" .. at("work", "operations", "plays", "site_upgrade.yml")), nil)
end

T["suggestion"]["offers nothing for the wrong suffix"] = function()
  eq(context.suggestion(at("work", "operations", "plays", "readme.txt")), nil)
end

T["suggestion"]["offers nothing for a directory named like a playbook"] = function()
  vim.fn.mkdir(at("looks.yml"), "p")
  eq(context.suggestion(at("looks.yml")), nil)
end

T["suggestion"]["never reads the file"] = function()
  -- The whole test is name and stat. A file whose contents are nothing like a
  -- playbook is still offered, because deciding that is Ansible's job and being
  -- wrong in either direction is worse than asking.
  local path = at("work", "operations", "plays", "empty.yml")
  vim.fn.writefile({}, path)

  eq(context.suggestion(path), path)
end

-- ---------------------------------------------------------------------------
-- Accepting a playbook

T["playbook"] = new_set()

T["playbook"]["accepts a symlink to a readable file"] = function()
  local link = at("link.yml")
  vim.uv.fs_symlink(at("work", "operations", "plays", "site_upgrade.yml"), link)

  local resolved, problem = context.playbook(link)

  eq(problem, nil)
  eq(resolved, at("work", "operations", "plays", "site_upgrade.yml"))
end

T["playbook"]["accepts a suffix it would not have suggested"] = function()
  -- The suffix rule decides what to *offer*, never what to accept. Somebody who
  -- types a path meant it.
  local path = at("work", "operations", "plays", "readme.txt")
  local resolved = context.playbook(path)

  eq(resolved, path)
end

T["playbook"]["refuses a directory, by name"] = function()
  local resolved, problem = context.playbook(at("work", "operations"))

  eq(resolved, nil)
  eq(problem:find("directory", 1, true) ~= nil, true)
end

T["playbook"]["refuses something that is not there"] = function()
  eq(select(2, context.playbook(at("nowhere.yml"))) ~= nil, true)
  eq(select(2, context.playbook("")) ~= nil, true)
end

T["playbook"]["refuses a broken symlink rather than stepping over it"] = function()
  local link = at("broken.yml")
  vim.uv.fs_symlink(at("gone.yml"), link)

  eq(select(2, context.playbook(link)) ~= nil, true)
end

-- ---------------------------------------------------------------------------
-- Inventory sources

T["inventory"] = new_set()

T["inventory"]["resolves a relative source against the frozen directory"] = function()
  -- The whole point of resolving here. `../inventories/dev/hosts.yml` typed
  -- while the run happens in `work/operations` means one file, and it is not the
  -- one the same text means anywhere else.
  local resolved, problem = context.inventory(at("work", "operations"), "../inventories/dev/hosts.yml")

  eq(problem, nil)
  eq(resolved, at("work", "inventories", "beta", "hosts.yml"))
end

T["inventory"]["refuses a source that is not under the frozen directory, naming where it looked"] = function()
  -- The failure this exists for: the path is real relative to `work`, which is
  -- where the completion was typed, and absent relative to `work/operations`,
  -- which is where the process starts. Ansible answers that with a warning and
  -- `rc=0`, so nothing downstream would have called it a problem.
  local resolved, problem = context.inventory(at("work", "operations"), "inventories/dev/hosts.yml")

  eq(resolved, nil)
  eq(problem:find(at("work", "operations", "inventories", "beta", "hosts.yml"), 1, true) ~= nil, true)
  -- And says which of the refusals it is. A path that is not there and a path
  -- that cannot be read are two different mistakes with two different fixes,
  -- and this is the one somebody reads while looking at a doubled prefix.
  eq(problem:find("does not exist", 1, true) ~= nil, true)
end

T["inventory"]["accepts a directory of sources"] = function()
  -- §5.2: a source is a file *or* a directory, and Ansible merges a directory's
  -- contents itself.
  local resolved, problem = context.inventory(at("work", "operations"), "../inventories/dev")

  eq(problem, nil)
  eq(resolved, at("work", "inventories", "beta"))
end

T["inventory"]["takes an absolute source from wherever it is given"] = function()
  local absolute = at("work", "inventories", "beta", "hosts.yml")

  eq(context.inventory(at("work", "operations"), absolute), absolute)
  eq(context.inventory(at("work", "operations", "plays"), absolute), absolute)
end

T["inventory"]["answers with the canonical path, not the one that was typed"] = function()
  -- Stored resolved, so the preview shows the file that will be opened rather
  -- than a path somebody has to compose in their head.
  local resolved = context.inventory(at("work", "operations"), "../inventories/../inventories/dev/hosts.yml")

  eq(resolved, at("work", "inventories", "beta", "hosts.yml"))
end

T["inventory"]["refuses an empty answer"] = function()
  eq(select(2, context.inventory(at("work", "operations"), "")) ~= nil, true)
end

T["inventory"]["refuses a broken symlink rather than stepping over it"] = function()
  local link = at("work", "operations", "inventory-link")
  vim.uv.fs_symlink(at("work", "gone.yml"), link)

  eq(select(2, context.inventory(at("work", "operations"), "inventory-link")) ~= nil, true)
end

T["inventory"]["refuses something that is neither a file nor a directory, by name"] = function()
  -- A socket is the reachable case: `-i` pointed at one fails inside Ansible
  -- with a message about parsing an inventory, which describes the wrong thing.
  local path = at("work", "operations", "inventory.sock")
  local pipe = vim.uv.new_pipe(false)
  eq(pipe:bind(path), 0)

  local resolved, problem = context.inventory(at("work", "operations"), "inventory.sock")
  pipe:close()

  eq(resolved, nil)
  eq(problem:find("socket", 1, true) ~= nil, true)
  eq(problem:find("not a file or a directory", 1, true) ~= nil, true)
end

T["inventory"]["refuses a file it may not read"] = function()
  -- Injected rather than produced with chmod, so the case says the same thing
  -- when the suite runs as root.
  local target = at("work", "inventories", "beta", "hosts.yml")
  local real = vim.uv.fs_access
  vim.uv.fs_access = function(path, mode)
    if path == target then
      return false
    end
    return real(path, mode)
  end
  local ok, resolved, problem = pcall(context.inventory, at("work", "operations"), "../inventories/dev/hosts.yml")
  vim.uv.fs_access = real

  eq(ok, true)
  eq(resolved, nil)
  eq(problem:find("cannot be read", 1, true) ~= nil, true)
end

T["inventory"]["refuses a directory it may not enter"] = function()
  local target = at("work", "inventories", "beta")
  local real = vim.uv.fs_access
  vim.uv.fs_access = function(path, mode)
    if path == target and mode == "X" then
      return false
    end
    return real(path, mode)
  end
  local ok, resolved, problem = pcall(context.inventory, at("work", "operations"), "../inventories/dev")
  vim.uv.fs_access = real

  eq(ok, true)
  eq(resolved, nil)
  eq(problem:find("not a directory you can read", 1, true) ~= nil, true)
end

-- ---------------------------------------------------------------------------
-- Candidate working directories

T["candidates"] = new_set()

T["candidates"]["offers Neovim's directory first, then the playbook's"] = function()
  local found = context.candidates(at("work", "operations", "plays", "site_upgrade.yml"), at("work"))

  eq(found[1].path, at("work"))
  eq(found[1].why, "Neovim's directory")
  eq(found[2].path, at("work", "operations", "plays"))
  eq(found[2].why, "playbook directory")
end

T["candidates"]["reports an ansible.cfg as a fact about the filesystem"] = function()
  local found = context.candidates(at("work", "operations", "plays", "site_upgrade.yml"), at("work", "operations"))

  eq(found[1].path, at("work", "operations"))
  eq(found[1].config, true)
  eq(found[2].config, false)
end

T["candidates"]["offers an ancestor that holds an ansible.cfg"] = function()
  local found = context.candidates(at("work", "operations", "plays", "site_upgrade.yml"), at("work"))

  local hardening
  for _, candidate in ipairs(found) do
    if candidate.path == at("work", "operations") then
      hardening = candidate
    end
  end

  eq(hardening ~= nil, true)
  eq(hardening.why, "ancestor with ansible.cfg")
  eq(hardening.config, true)
end

---The paths a candidate list holds, in order.
---@param found chroma_ansible.Candidate[]
---@return string[]
local function paths(found)
  return vim.tbl_map(function(candidate)
    return candidate.path
  end, found)
end

T["candidates"]["does not offer an ancestor without one"] = function()
  -- `work` holds no ansible.cfg. With Neovim sitting in `hardening` it has no
  -- other reason to appear, so it must not — and neither must the temporary
  -- root above it.
  local found =
    paths(context.candidates(at("work", "operations", "plays", "site_upgrade.yml"), at("work", "operations")))

  eq(vim.tbl_contains(found, at("work")), false)
  eq(vim.tbl_contains(found, tree), false)
  eq(found, { at("work", "operations"), at("work", "operations", "plays") })
end

T["candidates"]["offers one directory once, with the first reason it appeared"] = function()
  local playbook = at("work", "operations", "plays", "site_upgrade.yml")
  local found = context.candidates(playbook, at("work", "operations", "plays"))

  local count = 0
  for _, candidate in ipairs(found) do
    if candidate.path == at("work", "operations", "plays") then
      count = count + 1
      eq(candidate.why, "Neovim's directory")
    end
  end

  eq(count, 1)
end

T["candidates"]["skips a directory that is not there"] = function()
  local found = context.candidates(at("work", "operations", "plays", "site_upgrade.yml"), at("gone"))

  for _, candidate in ipairs(found) do
    eq(candidate.path == at("gone"), false)
  end
end

-- ---------------------------------------------------------------------------
-- Freezing

T["freeze"] = new_set()

T["freeze"]["answers with the canonical path"] = function()
  local link = at("shortcut")
  vim.uv.fs_symlink(at("work", "operations"), link)

  local frozen, problem = context.freeze(link)

  eq(problem, nil)
  eq(frozen, at("work", "operations"))
end

T["freeze"]["refuses a file"] = function()
  eq(select(2, context.freeze(at("work", "operations", "ansible.cfg"))) ~= nil, true)
end

T["freeze"]["refuses what is not there"] = function()
  eq(select(2, context.freeze(at("nowhere"))) ~= nil, true)
  eq(select(2, context.freeze("")) ~= nil, true)
end

T["still usable"] = new_set()

T["still usable"]["says nothing while the directory is still there"] = function()
  eq(context.still_usable(at("work", "operations")), nil)
end

T["still usable"]["notices the directory has gone"] = function()
  local frozen = context.freeze(at("work", "operations", "plays"))
  vim.fn.delete(frozen, "rf")

  eq(context.still_usable(frozen) ~= nil, true)
end

T["still usable"]["notices the directory became a file"] = function()
  local frozen = context.freeze(at("work", "operations", "plays"))
  vim.fn.delete(frozen, "rf")
  vim.fn.writefile({ "not a directory" }, frozen)

  eq(context.still_usable(frozen) ~= nil, true)
end

T["still usable"]["refuses a path that now leads somewhere else"] = function()
  -- The frozen value is canonical, so this can only happen if a component of it
  -- was swapped. Running would then run somewhere the operator never saw.
  eq(context.still_usable(at("work", "operations") .. "/../operations") ~= nil, true)
end

return T
