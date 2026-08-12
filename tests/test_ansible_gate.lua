-- The consent that stands between a picker and an Ansible process.
--
-- Two things are being checked here and they pull in opposite directions: the
-- gate must not ask twice for the same thing, and it must ask again the moment
-- anything it named has changed. A gate that only satisfies the first is an
-- annoyance removed; a gate that only satisfies the second is consent obtained
-- for one execution context and spent on another.
--
-- `doc/chroma-ansible-design.md`, section 6.

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local gate = require("chroma-ansible.gate")

local asked, answer, questions

local T = new_set({
  hooks = {
    pre_case = function()
      asked, answer, questions = 0, true, {}
      gate.confirm = function(question)
        asked = asked + 1
        table.insert(questions, question)
        return answer
      end
    end,
    post_case = function()
      -- The seam is a module field, so a case that left it replaced would
      -- decide the answer for every case after it.
      package.loaded["chroma-ansible.gate"] = nil
      gate = require("chroma-ansible.gate")
    end,
  },
})

---@param overrides table|nil
---@return chroma_ansible.Subject
local function subject(overrides)
  return vim.tbl_extend("force", {
    directory = "/work/operations",
    playbooks = { "plays/site_upgrade.yml" },
    inventory = { "../inventories/dev/hosts.yml" },
  }, overrides or {})
end

-- ---------------------------------------------------------------------------
-- Asking

T["asking"] = new_set()

T["asking"]["asks before the first subprocess"] = function()
  local g = gate.new()

  eq(gate.allow(g, subject()), true)
  eq(asked, 1)
end

T["asking"]["does not ask twice for the same three values"] = function()
  local g = gate.new()

  gate.allow(g, subject())
  eq(gate.allow(g, subject()), true)
  eq(asked, 1)
end

T["asking"]["a fresh gate has agreed to nothing"] = function()
  -- Nothing is cached globally, per directory or between runs. Cancelling the
  -- planner and starting again is a new question even for the same values.
  gate.allow(gate.new(), subject())
  gate.allow(gate.new(), subject())

  eq(asked, 2)
end

-- ---------------------------------------------------------------------------
-- What invalidates it

T["invalidated by"] = new_set()

---Grants a consent, then asks again with `changed` and answers how many times
---the operator was asked in total.
---@param changed table
---@return integer
local function after_changing(changed)
  local g = gate.new()
  gate.allow(g, subject())
  gate.allow(g, subject(changed))
  return asked
end

T["invalidated by"]["a different working directory"] = function()
  eq(after_changing({ directory = "/work/other" }), 2)
end

T["invalidated by"]["a different playbook"] = function()
  eq(after_changing({ playbooks = { "plays/other.yml" } }), 2)
end

T["invalidated by"]["one more playbook"] = function()
  eq(after_changing({ playbooks = { "plays/site_upgrade.yml", "plays/second.yml" } }), 2)
end

T["invalidated by"]["a different inventory source"] = function()
  eq(after_changing({ inventory = { "../inventories/prod/hosts.yml" } }), 2)
end

T["invalidated by"]["dropping to no inventory at all"] = function()
  eq(after_changing({ inventory = {} }), 2)
end

T["invalidated by"]["the same sources in a different order"] = function()
  local g = gate.new()
  gate.allow(g, subject({ inventory = { "common", "prod" } }))
  gate.allow(g, subject({ inventory = { "prod", "common" } }))

  -- Order matters to Ansible: it decides which definition of a host wins, so
  -- the two are different things to have agreed to.
  eq(asked, 2)
end

T["invalidated by"]["editing the list the consent was taken over"] = function()
  -- The planner owns these lists and edits them in place as the operator
  -- changes their mind. A consent holding a reference would quietly follow the
  -- very change it exists to catch.
  local live = subject()
  local g = gate.new()

  gate.allow(g, live)
  table.insert(live.inventory, "../inventories/prod/hosts.yml")
  gate.allow(g, live)

  eq(asked, 2)
end

-- ---------------------------------------------------------------------------
-- Declining

T["declining"] = new_set()

T["declining"]["answers no and grants nothing"] = function()
  answer = false
  local g = gate.new()

  eq(gate.allow(g, subject()), false)
  eq(g.granted, nil)
end

T["declining"]["asks again next time"] = function()
  answer = false
  local g = gate.new()
  gate.allow(g, subject())

  answer = true
  eq(gate.allow(g, subject()), true)
  eq(asked, 2)
end

T["declining"]["revokes a consent taken for something else"] = function()
  -- Granted for one context, then declined for another. What must not survive
  -- is the first one: going back to it would otherwise run with no question.
  local g = gate.new()
  gate.allow(g, subject())

  answer = false
  eq(gate.allow(g, subject({ directory = "/work/other" })), false)
  eq(g.granted, nil)

  answer = true
  eq(gate.allow(g, subject()), true)
  eq(asked, 3)
end

-- ---------------------------------------------------------------------------
-- What the question says

T["the question"] = new_set()

T["the question"]["names the three values it is about"] = function()
  gate.allow(gate.new(), subject())
  local question = questions[1]

  eq(question:find("/work/operations", 1, true) ~= nil, true)
  eq(question:find("plays/site_upgrade.yml", 1, true) ~= nil, true)
  eq(question:find("../inventories/dev/hosts.yml", 1, true) ~= nil, true)
end

T["the question"]["says that inspection may run code and reach out"] = function()
  gate.allow(gate.new(), subject())

  eq(questions[1]:find("execute inventory scripts", 1, true) ~= nil, true)
  eq(questions[1]:find("external systems", 1, true) ~= nil, true)
end

T["the question"]["is asked even when no -i will be passed"] = function()
  -- §5.3: with no explicit source, what gets contacted is decided by
  -- configuration the operator has not been shown. That is a stronger reason
  -- for the gate, not a reason to skip it.
  local g = gate.new()

  eq(gate.allow(g, subject({ inventory = {} })), true)
  eq(asked, 1)
  eq(questions[1]:find("not shown", 1, true) ~= nil, true)
end

T["the question"]["lists every playbook and every source"] = function()
  gate.allow(
    gate.new(),
    subject({
      playbooks = { "a.yml", "b.yml" },
      inventory = { "common", "prod" },
    })
  )

  for _, value in ipairs({ "a.yml", "b.yml", "common", "prod" }) do
    eq({ value, questions[1]:find(value, 1, true) ~= nil }, { value, true })
  end
end

-- ---------------------------------------------------------------------------
-- The default

T["the default"] = new_set()

T["the default"]["is No, and a dismissed dialog is No"] = function()
  -- The seam is replaced in every other case, so this one runs the real
  -- implementation against a replaced `vim.fn.confirm` — otherwise the default
  -- being No would never be executed by anything.
  package.loaded["chroma-ansible.gate"] = nil
  local real = require("chroma-ansible.gate")

  local saw
  local confirm = vim.fn.confirm
  vim.fn.confirm = function(_, choices, default)
    saw = { choices = choices, default = default }
    -- What `confirm` answers when the dialog is dismissed rather than answered.
    return 0
  end

  local allowed = real.allow(real.new(), subject())
  vim.fn.confirm = confirm

  eq(allowed, false)
  eq(saw.choices, "&No\n&Yes")
  eq(saw.default, 1)
end

return T
