-- Turning decisions into an exact argument vector.
--
-- Every case here is about something that must **not** appear: an inherited
-- option that emitted a default, `-l all` where no limit was asked for, a
-- prompting flag on a subprocess with no terminal, a playbook among the flags.
-- An argv builder is easy to test for what it produces and only useful if it is
-- tested for what it leaves out.
--
-- The worked example in `doc/chroma-ansible-design.md` §15 is reproduced
-- exactly, so that the document and the code cannot drift into two answers
-- about the same run.

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local argv = require("chroma-ansible.argv")

---A plan with nothing chosen: every option inherited, one playbook, no
---inventory. Overridden per case.
---@param overrides table|nil
---@return chroma_ansible.Plan
local function plan(overrides)
  return vim.tbl_extend("force", {
    executable = "/usr/bin/ansible-playbook",
    playbooks = { "plays/site_upgrade.yml" },
    inventory = {},
    limit = nil,
    tags = {},
    remote_user = nil,
    become = false,
    ask_become_pass = false,
    vault = {},
    check = false,
    diff = false,
  }, overrides or {})
end

---The built vector, asserted to have been built.
---@param overrides table|nil
---@return string[]
local function built(overrides)
  local out, problem = argv.execution(plan(overrides))
  eq(problem, nil)
  return out
end

---Whether a word appears anywhere in a vector.
---@param list string[]
---@param word string
---@return boolean
local function has(list, word)
  return vim.tbl_contains(list, word)
end

local T = new_set()

-- ---------------------------------------------------------------------------
-- The example the design carries

T["the worked example"] = new_set()

T["the worked example"]["is built exactly as §15 prints it"] = function()
  eq(
    built({
      remote_user = "deploy",
      ask_become_pass = true,
      become = true,
      inventory = { "../inventories/dev/hosts.yml" },
      limit = "webservers",
    }),
    {
      "/usr/bin/ansible-playbook",
      "-u",
      "deploy",
      "-K",
      "-b",
      "-i",
      "../inventories/dev/hosts.yml",
      "-l",
      "webservers",
      "plays/site_upgrade.yml",
    }
  )
end

-- ---------------------------------------------------------------------------
-- What inheriting emits

T["inherit"] = new_set()

T["inherit"]["a plan with nothing chosen is the program and the playbook"] = function()
  -- The whole of §10 in one case: inherit is not a default to emit, it is
  -- silence. Anything extra here is Chroma making a claim about the run.
  eq(built(), { "/usr/bin/ansible-playbook", "plays/site_upgrade.yml" })
end

T["inherit"]["no limit is no -l, not -l all"] = function()
  local out = built({ limit = nil })

  eq(has(out, "-l"), false)
  eq(has(out, "all"), false)
end

T["inherit"]["no inventory is no -i"] = function()
  eq(has(built({ inventory = {} }), "-i"), false)
end

-- ---------------------------------------------------------------------------
-- Order

T["order"] = new_set()

T["order"]["playbooks come last, after every option"] = function()
  local out = built({
    playbooks = { "a.yml", "b.yml" },
    inventory = { "inv" },
    tags = { "common" },
    check = true,
  })

  eq(out[#out - 1], "a.yml")
  eq(out[#out], "b.yml")
  eq(out[1], "/usr/bin/ansible-playbook")
end

T["order"]["several inventory sources keep the order they were given"] = function()
  local out = built({ inventory = { "common", "prod" } })

  -- Never sorted: Ansible merges sources in the order it receives them, and
  -- sorting would change which definition of a host wins.
  eq(out, { "/usr/bin/ansible-playbook", "-i", "common", "-i", "prod", "plays/site_upgrade.yml" })
end

T["order"]["several tags become several flags"] = function()
  local out = built({ tags = { "common", "security" } })

  -- Measured, §20.2: `--tags` accumulates. Joining with a comma would be this
  -- module inventing a syntax Ansible already has.
  eq(out, {
    "/usr/bin/ansible-playbook",
    "--tags",
    "common",
    "--tags",
    "security",
    "plays/site_upgrade.yml",
  })
end

-- ---------------------------------------------------------------------------
-- Pass-through

T["pass-through"] = new_set()

T["pass-through"]["a host pattern reaches argv byte for byte"] = function()
  for _, pattern in ipairs({ "webservers:&production", "all:!maintenance", "host01,host02" }) do
    local out = built({ limit = pattern })
    eq(out[#out - 1], pattern)
  end
end

T["pass-through"]["a pattern is never quoted, escaped or split"] = function()
  -- There is no shell in this module, so a space in a pattern is one argument.
  local out = built({ limit = "a b" })

  eq(has(out, "a b"), true)
  eq(has(out, "a"), false)
end

-- ---------------------------------------------------------------------------
-- Listings

T["listing"] = new_set()

T["listing"]["carries the same context as the run"] = function()
  local out = argv.listing(plan({ inventory = { "inv" }, limit = "prod", remote_user = "deploy" }), "hosts")

  eq(has(out, "-i"), true)
  eq(has(out, "inv"), true)
  eq(has(out, "-l"), true)
  eq(has(out, "prod"), true)
  eq(has(out, "-u"), true)
  eq(has(out, "--list-hosts"), true)
  eq(out[#out], "plays/site_upgrade.yml")
end

T["listing"]["drops the flags that would ask for a password"] = function()
  -- Measured on 2.21.2, §3.5: `--list-tags --ask-vault-pass` stops at
  -- `Vault password:` and dies on EOF, because a subprocess started by
  -- `vim.system` has no terminal to be asked on. `-K` does not prompt today and
  -- is dropped anyway: it cannot change what a listing reports.
  local out = argv.listing(plan({ ask_become_pass = true, vault = { "--ask-vault-pass" } }), "tags")

  eq(has(out, "-K"), false)
  eq(has(out, "--ask-vault-pass"), false)
  eq(has(out, "--list-tags"), true)
end

T["listing"]["keeps those flags for the run"] = function()
  -- The other half. Dropping them everywhere would be a planner that cannot ask
  -- for a password at all.
  local out = built({ ask_become_pass = true, vault = { "--ask-vault-pass" } })

  eq(has(out, "-K"), true)
  eq(has(out, "--ask-vault-pass"), true)
end

T["listing"]["refuses a mode this planner does not run"] = function()
  local out, problem = argv.listing(plan(), "everything")

  eq(out, nil)
  eq(type(problem), "string")
end

-- ---------------------------------------------------------------------------
-- The graph

T["graph"] = new_set()

T["graph"]["asks ansible-inventory for the sources and nothing else"] = function()
  local out = argv.graph(
    plan({ inventory = { "common", "prod" }, limit = "prod", tags = { "x" }, remote_user = "u" }),
    "/usr/bin/ansible-inventory"
  )

  eq(out, { "/usr/bin/ansible-inventory", "-i", "common", "-i", "prod", "--graph" })
end

T["graph"]["never passes --vars"] = function()
  -- The flag that puts host and group variables into the output in plaintext.
  eq(has(argv.graph(plan({ inventory = { "inv" } }), "/usr/bin/ansible-inventory"), "--vars"), false)
end

T["graph"]["never passes -l, which --graph ignores"] = function()
  -- Measured, §20.6. An argument that looks like it filters and does not is
  -- worse than no argument at all.
  eq(has(argv.graph(plan({ limit = "prod" }), "/usr/bin/ansible-inventory"), "-l"), false)
end

-- ---------------------------------------------------------------------------
-- Refusals

T["refuses"] = new_set()

---@param overrides table
---@return string|nil
local function refusal(overrides)
  local out, problem = argv.execution(plan(overrides))
  if out then
    return nil
  end
  return problem
end

T["refuses"]["a relative executable"] = function()
  -- §15.2: the preview shows `argv[0]`, and it can only be the program that
  -- starts if it is the resolved absolute path.
  eq(refusal({ executable = "ansible-playbook" }) ~= nil, true)
  eq(refusal({ executable = "./ansible-playbook" }) ~= nil, true)
end

T["refuses"]["a plan with no playbook"] = function()
  eq(refusal({ playbooks = {} }) ~= nil, true)
end

T["refuses"]["an empty string where a value belongs"] = function()
  -- An empty limit would emit `-l` with an empty argument, which asks Ansible a
  -- different question. `No limit` is nil, and only nil.
  eq(refusal({ limit = "" }) ~= nil, true)
  eq(refusal({ remote_user = "" }) ~= nil, true)
  eq(refusal({ tags = { "" } }) ~= nil, true)
  eq(refusal({ inventory = { "" } }) ~= nil, true)
end

T["refuses"]["a list that is not a list"] = function()
  eq(refusal({ tags = "common" }) ~= nil, true)
  eq(refusal({ inventory = { key = "value" } }) ~= nil, true)
end

T["refuses"]["and answers with no vector at all"] = function()
  local out, problem = argv.execution(plan({ playbooks = {} }))

  eq(out, nil)
  eq(type(problem), "string")
end

return T
