-- Execution lifecycle tests for terraform.nvim.
--
-- These drive the module against fake `terraform` and `aws` executables rather
-- than the real ones. That is deliberate and not a compromise: every property
-- worth protecting here is about what this plugin does around the subprocess —
-- which binary it picks, whether a second apply can start, which plan file
-- survives a race, what happens when the review window cannot open. A real
-- terraform would add minutes, require credentials and infrastructure, and
-- test none of it.
--
-- The fakes log what they were invoked as, so assertions are made on the
-- command that actually ran rather than on what the module said it would do.

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local terraform = require("terraform")

--- Everything one case needs: a project, fake binaries, a runtime directory.
---@return table
local function harness()
  local root = vim.fn.tempname()
  local bin = root .. "/bin"
  local work = root .. "/work"
  local runtime = root .. "/run"
  for _, dir in ipairs({ bin, work, runtime }) do
    vim.fn.mkdir(dir, "p")
  end

  -- The runtime directory is validated as 0700 before anything is written to
  -- it, and mkdir under the ambient umask does not produce that.
  vim.fn.setfperm(runtime, "rwx------")

  vim.fn.writefile({ 'resource "null_resource" "x" {}' }, work .. "/main.tf")

  local h = {
    root = root,
    bin = bin,
    work = work,
    runtime = runtime,
    log = root .. "/invocations",
    counter = root .. "/counter",
    sts = root .. "/sts",
  }

  ---Writes a fake executable that records how it was called.
  ---@param name string
  ---@param body string[] shell lines run after logging
  function h.fake(name, body)
    local path = bin .. "/" .. name
    local lines = {
      "#!/bin/sh",
      ('printf "%%s %%s\\n" "$0" "$*" >> %s'):format(vim.fn.shellescape(h.log)),
    }
    vim.list_extend(lines, body)
    vim.fn.writefile(lines, path)
    vim.fn.setfperm(path, "rwxr-xr-x")
    return path
  end

  ---Every line the fakes logged.
  ---@return string[]
  function h.invocations()
    if not vim.uv.fs_stat(h.log) then
      return {}
    end
    return vim.fn.readfile(h.log)
  end

  ---Invocations whose argument list starts with `verb`.
  ---@param verb string
  ---@return string[]
  function h.calls(verb)
    return vim.tbl_filter(function(line)
      local args = line:match("^%S+%s+(.*)$")
      return args ~= nil and (args == verb or args:sub(1, #verb + 1) == verb .. " ")
    end, h.invocations())
  end

  ---Plan files currently in the runtime directory.
  ---@return string[]
  function h.plan_files()
    return vim.fn.glob(runtime .. "/terraform.nvim/*.tfplan", false, true)
  end

  return h
end

--- The standard fake: plan writes the -out file and reports changes, apply
--- succeeds. `extra` is spliced in before that, for cases that need delays.
---@param h table
---@param extra string[]|nil
local function fake_terraform(h, extra)
  local body = extra and vim.deepcopy(extra) or {}
  vim.list_extend(body, {
    'if [ "$1" = "plan" ]; then',
    '  for a in "$@"; do case "$a" in -out=*) echo "${MARKER:-plan}" > "${a#-out=}";; esac; done',
    "  exit 2",
    "fi",
    "exit 0",
  })
  return h.fake("terraform", body)
end

--- A fake `aws` whose STS answer is read from a control file, so a case can
--- change identity between plan and apply.
---@param h table
---@param extra string[]|nil
local function fake_aws(h, extra)
  local body = extra and vim.deepcopy(extra) or {}
  vim.list_extend(body, {
    ("mode=$(cat %s 2>/dev/null)"):format(vim.fn.shellescape(h.sts)),
    'if [ "$mode" = "fail" ]; then echo "Unable to locate credentials" >&2; exit 255; fi',
    'case "$mode" in',
    '  a) echo \'{"Account":"111111111111","Arn":"arn:aws:sts::111111111111:assumed-role/dev/u"}\';;',
    '  b) echo \'{"Account":"222222222222","Arn":"arn:aws:sts::222222222222:assumed-role/dev/u"}\';;',
    '  role) echo \'{"Account":"111111111111","Arn":"arn:aws:sts::111111111111:assumed-role/admin/u"}\';;',
    "esac",
    "exit 0",
  })
  return h.fake("aws", body)
end

local saved = {}
local notices = {}

---Everything the module told the user during this case.
---@return string
local function transcript()
  return table.concat(notices, " | "):gsub("\n", " ")
end

---@param pattern string
---@return boolean
local function said(pattern)
  for _, message in ipairs(notices) do
    if message:match(pattern) then
      return true
    end
  end
  return false
end

---Waits until the module has reported one of the given outcomes.
---@param ... string
local function settle(...)
  local patterns = { ... }
  vim.wait(15000, function()
    for _, pattern in ipairs(patterns) do
      if said(pattern) then
        return true
      end
    end
    return false
  end, 20)
end

local T = new_set({
  hooks = {
    pre_case = function()
      saved.path = vim.env.PATH
      saved.runtime_dir = vim.env.XDG_RUNTIME_DIR
      saved.profile = vim.env.AWS_PROFILE
      saved.region = vim.env.AWS_REGION
      saved.notify = vim.notify
      saved.input = vim.fn.input
      saved.winheight = vim.o.winheight
      saved.winminheight = vim.o.winminheight

      notices = {}
      vim.notify = function(message, _)
        table.insert(notices, tostring(message))
      end
      -- Applying prompts for confirmation; every case that applies means to.
      vim.fn.input = function()
        return "yes"
      end
      -- A destroy plan is never confirmed by these tests.
      vim.env.AWS_PROFILE = nil
      vim.env.AWS_REGION = nil
    end,
    post_case = function()
      terraform.setup({})
      terraform.discard()
      vim.env.PATH = saved.path
      vim.env.XDG_RUNTIME_DIR = saved.runtime_dir
      vim.env.AWS_PROFILE = saved.profile
      vim.env.AWS_REGION = saved.region
      vim.notify = saved.notify
      vim.fn.input = saved.input
      vim.o.winminheight = saved.winminheight
      vim.o.winheight = saved.winheight
      vim.cmd("silent! only")
      vim.cmd("silent! %bwipeout!")
    end,
  },
})

---Sets up a case: fakes on PATH, runtime directory, plugin configured, buffer
---open on the project's main.tf.
---@param h table
---@param opts table|nil
local function start(h, opts)
  vim.env.PATH = h.bin .. ":" .. vim.env.PATH
  vim.env.XDG_RUNTIME_DIR = h.runtime
  terraform.setup(opts or {})
  vim.cmd.edit({ args = { h.work .. "/main.tf" } })
  notices = {}
end

-- ---------------------------------------------------------------------------
-- Which executable runs
-- ---------------------------------------------------------------------------

T["executable"] = new_set()

-- Regression: the plan recorded the binary it was made with and nothing read
-- it, so apply re-resolved from PATH and could hand a terraform plan to tofu.
T["executable"]["apply runs the binary the plan was made with"] = function()
  local h = harness()
  fake_terraform(h)
  -- A tofu that would be picked if apply resolved the name again.
  h.fake("tofu", { "exit 0" })
  start(h)

  terraform.plan()
  settle("Plan saved", "Plan failed")
  eq(said("Plan saved"), true)

  -- Remove terraform, leaving tofu as the only candidate for a fresh lookup.
  vim.fn.delete(h.bin .. "/terraform")
  notices = {}
  terraform.apply()
  settle("Refusing", "no longer available", "Applied", "Apply failed")

  eq(said("no longer available"), true)
  eq(#h.calls("apply"), 0)
end

T["executable"]["a plan whose binary is still present applies with it"] = function()
  local h = harness()
  fake_terraform(h)
  start(h)

  terraform.plan()
  settle("Plan saved")
  notices = {}
  terraform.apply()
  settle("Applied", "Apply failed")

  eq(said("Applied"), true)
  local applies = h.calls("apply")
  eq(#applies, 1)
  eq(applies[1]:match("^%S+/terraform ") ~= nil, true)
end

-- ---------------------------------------------------------------------------
-- Serialised apply
-- ---------------------------------------------------------------------------

T["serialisation"] = new_set()

T["serialisation"]["a second apply is refused while one runs"] = function()
  local h = harness()
  fake_terraform(h, { 'if [ "$1" = "apply" ]; then sleep 1; exit 0; fi' })
  start(h)

  terraform.plan()
  settle("Plan saved")
  notices = {}

  terraform.apply()
  vim.wait(300, function()
    return false
  end)
  terraform.apply()

  eq(said("already running"), true)
  settle("Applied", "Apply failed")
  eq(#h.calls("apply"), 1)
end

T["serialisation"]["planning during an apply is refused"] = function()
  local h = harness()
  fake_terraform(h, { 'if [ "$1" = "apply" ]; then sleep 1; exit 0; fi' })
  start(h)

  terraform.plan()
  settle("Plan saved")
  notices = {}

  terraform.apply()
  vim.wait(300, function()
    return false
  end)
  terraform.plan()

  eq(said("would delete the plan it is applying"), true)
  settle("Applied", "Apply failed")
end

T["serialisation"]["the lock is released when the apply finishes"] = function()
  local h = harness()
  fake_terraform(h, { 'if [ "$1" = "apply" ]; then sleep 1; exit 0; fi' })
  start(h)

  terraform.plan()
  settle("Plan saved")
  notices = {}
  terraform.apply()
  settle("Applied", "Apply failed")
  eq(said("Applied"), true)

  notices = {}
  terraform.plan()
  settle("Plan saved", "would delete")
  eq(said("Plan saved"), true)
end

-- ---------------------------------------------------------------------------
-- Ordering between concurrent plans
-- ---------------------------------------------------------------------------

T["ordering"] = new_set()

-- The first invocation is slow, the second fast, so the callbacks arrive in
-- the opposite order to the requests. The older one must not become the plan.
T["ordering"]["a slower earlier plan does not overwrite a newer one"] = function()
  local h = harness()
  fake_terraform(h, {
    ("n=$(cat %s 2>/dev/null || echo 0); n=$((n+1)); echo $n > %s"):format(
      vim.fn.shellescape(h.counter),
      vim.fn.shellescape(h.counter)
    ),
    'if [ "$1" = "plan" ] && [ "$n" = "1" ]; then MARKER=first; sleep 1; else MARKER=second; fi',
    "export MARKER",
  })
  start(h)

  terraform.plan()
  vim.wait(150, function()
    return false
  end)
  terraform.plan()

  vim.wait(15000, function()
    return #h.calls("plan") >= 2 and said("Plan saved")
  end, 20)
  -- Let the slower first callback arrive as well.
  vim.wait(1500, function()
    return false
  end)

  local files = h.plan_files()
  eq(#files, 1)
  eq(vim.fn.readfile(files[1])[1], "second")
end

-- ---------------------------------------------------------------------------
-- Strict AWS identity
-- ---------------------------------------------------------------------------

T["strict identity"] = new_set()

T["strict identity"]["is off by default and does not call STS"] = function()
  local h = harness()
  fake_terraform(h)
  fake_aws(h)
  vim.fn.writefile({ "a" }, h.sts)
  start(h)

  terraform.plan()
  settle("Plan saved")
  eq(said("Plan saved"), true)
  eq(#h.calls("sts"), 0)
end

T["strict identity"]["records the identity and applies under the same one"] = function()
  local h = harness()
  fake_terraform(h)
  fake_aws(h)
  vim.fn.writefile({ "a" }, h.sts)
  start(h, { strict_aws_identity = true })

  terraform.plan()
  settle("Plan saved")
  eq(said("Plan saved as arn:aws:sts::111111111111"), true)

  notices = {}
  terraform.apply()
  settle("Applied", "Apply failed", "Refusing")
  eq(said("Applied"), true)
end

T["strict identity"]["refuses an apply from a different account"] = function()
  local h = harness()
  fake_terraform(h)
  fake_aws(h)
  vim.fn.writefile({ "a" }, h.sts)
  start(h, { strict_aws_identity = true })

  terraform.plan()
  settle("Plan saved")
  vim.fn.writefile({ "b" }, h.sts)
  notices = {}
  terraform.apply()
  settle("Refusing", "Applied", "Apply failed")

  eq(said("AWS account changed"), true)
  eq(#h.calls("apply"), 0)
end

T["strict identity"]["refuses a different principal in the same account"] = function()
  local h = harness()
  fake_terraform(h)
  fake_aws(h)
  vim.fn.writefile({ "a" }, h.sts)
  start(h, { strict_aws_identity = true })

  terraform.plan()
  settle("Plan saved")
  vim.fn.writefile({ "role" }, h.sts)
  notices = {}
  terraform.apply()
  settle("Refusing", "Applied", "Apply failed")

  eq(said("AWS identity changed"), true)
  eq(#h.calls("apply"), 0)
end

T["strict identity"]["refuses when STS stops answering after a bound plan"] = function()
  local h = harness()
  fake_terraform(h)
  fake_aws(h)
  vim.fn.writefile({ "a" }, h.sts)
  start(h, { strict_aws_identity = true })

  terraform.plan()
  settle("Plan saved")
  vim.fn.writefile({ "fail" }, h.sts)
  notices = {}
  terraform.apply()
  settle("Refusing", "Applied", "Apply failed")

  eq(said("Refusing to apply"), true)
  eq(#h.calls("apply"), 0)
end

T["strict identity"]["treats a missing aws CLI as a quiet skip"] = function()
  local h = harness()
  fake_terraform(h)
  -- No fake aws, and a PATH that contains nothing else.
  vim.env.PATH = h.bin
  vim.env.XDG_RUNTIME_DIR = h.runtime
  terraform.setup({ strict_aws_identity = true })
  vim.cmd.edit({ args = { h.work .. "/main.tf" } })
  notices = {}

  eq(vim.fn.executable("aws"), 0)
  terraform.plan()
  settle("Plan saved", "Plan failed")

  eq(said("Plan saved"), true)
  eq(said("Could not determine"), false)
end

-- The identity lookup is an await between the "already running" guard and the
-- start of the process. Without the directory claimed across it, two applies
-- both walk through to the same plan file.
T["strict identity"]["a second apply during the lookup is refused"] = function()
  local h = harness()
  fake_terraform(h)
  fake_aws(h, { "sleep 1" })
  vim.fn.writefile({ "a" }, h.sts)
  start(h, { strict_aws_identity = true })

  terraform.plan()
  settle("Plan saved")
  notices = {}

  terraform.apply()
  vim.wait(300, function()
    return false
  end)
  terraform.apply()

  eq(said("already running"), true)
  settle("Applied", "Apply failed")
  eq(#h.calls("apply"), 1)
end

-- Claiming the generation after the lookup would order plans by how quickly
-- STS answered rather than by when they were requested, and the older plan
-- would win. The newer one must, and the older must not even start terraform.
T["strict identity"]["the lookup does not invert plan ordering"] = function()
  local h = harness()
  fake_terraform(h)
  fake_aws(h, {
    ("n=$(cat %s 2>/dev/null || echo 0); n=$((n+1)); echo $n > %s"):format(
      vim.fn.shellescape(h.counter),
      vim.fn.shellescape(h.counter)
    ),
    'if [ "$n" = "1" ]; then sleep 1; fi',
  })
  vim.fn.writefile({ "a" }, h.sts)
  start(h, { strict_aws_identity = true })

  terraform.plan()
  vim.wait(150, function()
    return false
  end)
  terraform.plan()

  settle("Plan saved", "Plan failed")
  -- Let the slower first lookup return.
  vim.wait(1500, function()
    return false
  end)

  -- The superseded plan returns before starting anything, so terraform ran once.
  eq(#h.calls("plan"), 1)
  eq(#h.plan_files(), 1)
end

-- ---------------------------------------------------------------------------
-- Review rendering
-- ---------------------------------------------------------------------------

T["review"] = new_set()

---Leaves no room for the output split, so show() raises E36.
local function fill_the_screen()
  vim.cmd("silent! only")
  vim.o.winheight = 20
  vim.o.winminheight = 20
end

local function free_the_screen()
  vim.o.winminheight = 1
  vim.o.winheight = 1
  vim.cmd("silent! only")
end

T["review"]["a plan that cannot be shown is discarded"] = function()
  local h = harness()
  fake_terraform(h)
  start(h)
  fill_the_screen()

  terraform.plan()
  settle("could not be shown", "Plan saved", "Plan failed")

  eq(said("could not be shown"), true)
  eq(said("Plan saved"), false)
  eq(#h.plan_files(), 0)
end

T["review"]["and cannot afterwards be applied"] = function()
  local h = harness()
  fake_terraform(h)
  start(h)
  fill_the_screen()

  terraform.plan()
  settle("could not be shown")
  free_the_screen()

  notices = {}
  terraform.apply()
  settle("No reviewed plan", "Applied", "Apply failed")

  eq(said("No reviewed plan"), true)
  eq(#h.calls("apply"), 0)
end

-- A new plan was asked for, which supersedes the old one. Leaving it would let
-- apply run something the user had not just reviewed.
T["review"]["a failed review discards the previously reviewed plan too"] = function()
  local h = harness()
  fake_terraform(h)
  start(h)
  free_the_screen()

  terraform.plan()
  settle("Plan saved")
  eq(#h.plan_files(), 1)

  fill_the_screen()
  notices = {}
  terraform.plan()
  settle("could not be shown")

  eq(#h.plan_files(), 0)

  free_the_screen()
  notices = {}
  terraform.apply()
  settle("No reviewed plan", "Applied")
  eq(said("No reviewed plan"), true)
end

T["review"]["the state is released, so planning works again"] = function()
  local h = harness()
  fake_terraform(h)
  start(h)
  fill_the_screen()

  terraform.plan()
  settle("could not be shown")

  free_the_screen()
  notices = {}
  terraform.plan()
  settle("Plan saved", "could not be shown")
  eq(said("Plan saved"), true)

  notices = {}
  terraform.apply()
  settle("Applied", "Apply failed")
  eq(said("Applied"), true)
end

-- The exception used to escape the async callback and take the outcome
-- notification with it, leaving an operation that changed infrastructure
-- reporting nothing at all.
T["review"]["a failed window still reports the outcome"] = function()
  local h = harness()
  fake_terraform(h)
  start(h)
  fill_the_screen()

  terraform.init()
  settle("Initialised", "Init failed")

  eq(said("Initialised"), true)
  eq(said("Could not open the output window"), true)
end

return T
