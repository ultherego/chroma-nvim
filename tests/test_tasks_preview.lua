-- What the preview says, and what the confirmation accepts.
--
-- Both halves are load-bearing. The preview is the only description somebody
-- reads before agreeing, so anything it shows that is not what will run is a
-- lie told at the worst moment; and the confirmation is the last gate before a
-- process that may apply infrastructure, so everything that is not a yes has
-- to be a no.

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local preview = require("chroma.tasks.preview")

local saved = {}

---@param overrides table|nil
---@return table task, string directory, table prepared
local function plan(overrides)
  overrides = overrides or {}
  local task = {
    id = "beta",
    name = overrides.name or "Run beta",
    group = overrides.group,
    cwd = { mode = "project" },
    argv = overrides.declared or { "ansible-playbook", "-K" },
    env = overrides.env,
  }
  local prepared = {
    argv = overrides.argv or { "/usr/bin/ansible-playbook", "-K" },
    env = overrides.env or {},
  }
  return task, overrides.directory or "/home/user/infra/plays", prepared
end

---The rendered preview as one string, for asking whether something appears.
---@param ... any
---@return string
local function rendered(...)
  return table.concat(preview.render(...), "\n")
end

---The line holding `needle`, or "".
---@param lines string[]
---@param needle string
---@return string
local function line_with(lines, needle)
  for _, line in ipairs(lines) do
    if line:find(needle, 1, true) then
      return line
    end
  end
  return ""
end

local T = new_set({
  hooks = {
    pre_case = function()
      saved.confirm = vim.fn.confirm
    end,
    post_case = function()
      vim.fn.confirm = saved.confirm
    end,
  },
})

-- ---------------------------------------------------------------------------
-- What it shows

T["the preview"] = new_set()

T["the preview"]["shows the resolved executable, not the name the task wrote"] = function()
  -- The task said `ansible-playbook`; what will start is the absolute path the
  -- resolver found, and the preview and the executor read the same array.
  local task, directory, prepared = plan({
    declared = { "ansible-playbook", "-K" },
    argv = { "/usr/bin/ansible-playbook", "-K" },
  })

  local lines = preview.render(task, directory, prepared)

  eq(line_with(lines, "argv[0]"), "argv[0]  /usr/bin/ansible-playbook")
  eq(line_with(lines, "argv[1]"), "argv[1]  -K")
end

T["the preview"]["shows the working directory and what the task is called"] = function()
  local task, directory, prepared = plan({ group = "ansible", name = "Run beta" })

  local text = rendered(task, directory, prepared)

  eq(text:find("ansible / Run beta", 1, true) ~= nil, true)
  eq(text:find("/home/user/infra/plays", 1, true) ~= nil, true)
end

T["the preview"]["shows the overrides and not the inherited environment"] = function()
  -- What the task changes, not what the process will have. The editor's
  -- environment is inherited by every task and listing it would bury the one
  -- line that matters — and put whatever is in it on screen.
  vim.env.CHROMA_INHERITED_SENTINEL = "secret"
  local task, directory, prepared = plan({ env = { AWS_PROFILE = "beta" } })

  local text = rendered(task, directory, prepared)
  vim.env.CHROMA_INHERITED_SENTINEL = nil

  eq(text:find("AWS_PROFILE=beta", 1, true) ~= nil, true)
  eq(text:find("CHROMA_INHERITED_SENTINEL", 1, true), nil)
  eq(text:find("secret", 1, true), nil)
end

T["the preview"]["lists overrides in the same order every time"] = function()
  local task, directory, prepared = plan({
    env = { ZONE = "eu", AWS_PROFILE = "beta", KUBECONFIG = "/tmp/kube" },
  })

  local first = rendered(task, directory, prepared)
  local second = rendered(task, directory, prepared)

  eq(first, second)
  eq(first:find("AWS_PROFILE=beta", 1, true) < first:find("KUBECONFIG=", 1, true), true)
  eq(first:find("KUBECONFIG=", 1, true) < first:find("ZONE=eu", 1, true), true)
end

T["the preview"]["says nothing about environment when the task overrides none"] = function()
  local task, directory, prepared = plan()

  eq(rendered(task, directory, prepared):find("Environment", 1, true), nil)
end

-- ---------------------------------------------------------------------------
-- What it refuses to pretend

T["representation"] = new_set()

T["representation"]["keeps every argument its own entry"] = function()
  -- No line joins these into something that looks like a command. A rendering
  -- with spaces would read as five arguments where there are four, and it is
  -- the line somebody would copy into a shell.
  local task, directory, prepared = plan({
    argv = { "/usr/bin/ansible-playbook", "message=hello world", "foo;bar", "*.tf", 'quote"here' },
  })

  local lines = preview.render(task, directory, prepared)

  eq(line_with(lines, "argv[1]"), "argv[1]  message=hello world")
  eq(line_with(lines, "argv[2]"), "argv[2]  foo;bar")
  eq(line_with(lines, "argv[3]"), "argv[3]  *.tf")
  eq(line_with(lines, "argv[4]"), 'argv[4]  quote"here')

  for _, line in ipairs(lines) do
    if line:find("ansible-playbook message=hello world", 1, true) then
      error(("the preview rendered a shell command line: %q"):format(line))
    end
  end
end

T["representation"]["one argument stays one line"] = function()
  -- A newline inside an argument would otherwise draw a second line that reads
  -- exactly like the next argument. The schema allows any string, so this can
  -- reach the preview from a task file.
  local task, directory, prepared = plan({
    argv = { "/bin/echo", "first\nsecond", "tab\there" },
  })

  local lines = preview.render(task, directory, prepared)

  eq(line_with(lines, "argv[1]"), "argv[1]  first\\nsecond")
  eq(line_with(lines, "argv[2]"), "argv[2]  tab\\there")
  eq(#lines, #preview.render(task, directory, { argv = { "/bin/echo", "a", "b" }, env = {} }))
end

T["representation"]["a literal backslash cannot be mistaken for an escape"] = function()
  local task, directory, prepared = plan({ argv = { "/bin/echo", "first\\nsecond" } })

  eq(line_with(preview.render(task, directory, prepared), "argv[1]"), "argv[1]  first\\\\nsecond")
end

-- ---------------------------------------------------------------------------
-- The question

T["confirmation"] = new_set()

T["confirmation"]["runs only on an explicit yes"] = function()
  local answers = { [0] = false, [1] = false, [2] = true, [3] = false }

  for answer, expected in pairs(answers) do
    vim.fn.confirm = function()
      return answer
    end
    eq({ answer, preview.confirm({ "Task" }) }, { answer, expected })
  end
end

T["confirmation"]["defaults to not running"] = function()
  -- Not only the handling of the answer: if Enter on the dialog chose Yes,
  -- every invariant above would be decorative.
  local asked = {}
  vim.fn.confirm = function(question, choices, default)
    asked = { question = question, choices = choices, default = default }
    return 0
  end

  preview.confirm({ "Task", "Ansible / Run beta" })

  eq(asked.choices, "&No\n&Yes")
  eq(asked.default, 1)
  eq(asked.question:find("Ansible / Run beta", 1, true) ~= nil, true)
end

T["confirmation"]["shows what the preview said"] = function()
  local seen
  vim.fn.confirm = function(question)
    seen = question
    return 0
  end

  local task, directory, prepared = plan({ argv = { "/usr/bin/terraform", "plan" } })
  preview.confirm(preview.render(task, directory, prepared))

  eq(seen:find("argv[0]  /usr/bin/terraform", 1, true) ~= nil, true)
end

return T
