-- Execution lifecycle tests for terraform.nvim.

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

---Configures the plugin without clearing what it said, which `start` does.
---@param opts table
local function configure(opts)
  terraform.setup(opts)
end

-- ---------------------------------------------------------------------------
-- Which executable runs

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

---Leaves nothing on PATH: no terraform, no tofu, nothing else either.
---@param h table
local function nothing_installed(h)
  vim.env.PATH = h.bin
  vim.fn.delete(h.bin .. "/terraform")
  vim.fn.delete(h.bin .. "/tofu")
end

-- With neither installed the name resolver answered "tofu", so the refusal named
-- one binary the user may never have chosen and said nothing about the other.
T["executable"]["a plan reports when neither terraform nor tofu is available"] = function()
  local h = harness()
  fake_terraform(h)
  start(h)
  nothing_installed(h)
  notices = {}

  terraform.plan()
  vim.wait(500, function()
    return said("PATH")
  end, 20)

  eq(said("Neither `terraform` nor `tofu` was found on PATH"), true)
  eq(#h.plan_files(), 0)
end

-- The other place the name is resolved is inside `run`, which init and validate
-- go through; T["init"]["the claim is released when the process cannot start"]
-- covers that one.

-- ---------------------------------------------------------------------------
-- Serialised apply

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
-- Superseded plans

-- `generation` orders two plans against each other, and says nothing about the
-- plan reviewed before either of them started.
T["superseding"] = new_set()

--- A fake whose `plan` behaviour is read from control files, so one case can
--- change what the next plan does. `apply` records the contents of the plan
---@param h table
local function fake_terraform_by_mode(h)
  h.mode = h.root .. "/mode"
  h.marker = h.root .. "/marker"

  return h.fake("terraform", {
    ("mode=$(cat %s 2>/dev/null)"):format(vim.fn.shellescape(h.mode)),
    ("marker=$(cat %s 2>/dev/null)"):format(vim.fn.shellescape(h.marker)),
    'if [ "$1" = "apply" ]; then',
    ('  for a in "$@"; do case "$a" in *.tfplan) printf "applied %%s\\n" "$(cat "$a")" >> %s;; esac; done'):format(
      vim.fn.shellescape(h.log)
    ),
    "  exit 0",
    "fi",
    'if [ "$1" = "init" ]; then',
    '  [ "$mode" = "slow-init" ] && sleep 2',
    '  if [ "$mode" = "init-fail" ]; then exit 1; fi',
    "  exit 0",
    "fi",
    'if [ "$1" = "plan" ]; then',
    '  [ "$mode" = "slow" ] && sleep 2',
    '  if [ "$mode" = "none" ]; then exit 0; fi',
    '  if [ "$mode" = "fail" ]; then exit 1; fi',
    '  for a in "$@"; do case "$a" in -out=*) echo "$marker" > "${a#-out=}";; esac; done',
    "  exit 2",
    "fi",
    "exit 0",
  })
end

---What the next `terraform plan` should do, and what it should write.
---@param h table
---@param mode string one of changes, none, fail, slow
---@param marker string|nil contents of the plan file it writes
local function next_plan(h, mode, marker)
  vim.fn.writefile({ mode }, h.mode)
  if marker then
    vim.fn.writefile({ marker }, h.marker)
  end
end

---Which plan file contents `apply` was handed, if it ran at all.
---@param h table
---@return string|nil
local function applied_marker(h)
  for _, line in ipairs(h.invocations()) do
    local marker = line:match("^applied (.*)$")
    if marker then
      return marker
    end
  end
  return nil
end

T["superseding"]["apply is refused while a newer plan is still running"] = function()
  local h = harness()
  fake_terraform_by_mode(h)
  start(h)

  next_plan(h, "changes", "first")
  terraform.plan()
  settle("Plan saved")
  notices = {}

  -- The replacement is slow, so the whole of it is a window in which the old
  -- plan used to still be reachable.
  next_plan(h, "slow", "second")
  terraform.plan()
  vim.wait(400, function()
    return false
  end)

  terraform.apply()
  eq(said("still running"), true)
  eq(applied_marker(h), nil)

  settle("Plan saved", "Plan failed")
end

T["superseding"]["a plan reporting no changes leaves nothing to apply"] = function()
  local h = harness()
  fake_terraform_by_mode(h)
  start(h)

  next_plan(h, "changes", "first")
  terraform.plan()
  settle("Plan saved")
  notices = {}

  -- The configuration was edited so that it now matches reality. The earlier
  -- plan describes changes the configuration no longer asks for.
  next_plan(h, "none")
  terraform.plan()
  settle("No changes")
  notices = {}

  terraform.apply()
  settle("No reviewed plan", "Applied", "Apply failed")

  eq(said("No reviewed plan"), true)
  eq(applied_marker(h), nil)
  -- And the superseded file is gone rather than left in the runtime directory.
  eq(#h.plan_files(), 0)
end

T["superseding"]["a failed plan leaves nothing to apply"] = function()
  local h = harness()
  fake_terraform_by_mode(h)
  start(h)

  next_plan(h, "changes", "first")
  terraform.plan()
  settle("Plan saved")
  notices = {}

  next_plan(h, "fail")
  terraform.plan()
  settle("Plan failed")
  notices = {}

  terraform.apply()
  settle("No reviewed plan", "Applied", "Apply failed")

  eq(said("No reviewed plan"), true)
  eq(applied_marker(h), nil)
end

-- The claim has to be released on every exit, including the one where the
-- process is never started at all. A directory stuck in "a plan is running"
T["superseding"]["the claim is released when the process cannot start"] = function()
  local h = harness()
  fake_terraform_by_mode(h)
  fake_aws(h, { "sleep 1" })
  vim.fn.writefile({ "a" }, h.sts)
  start(h, { strict_aws_identity = true })

  next_plan(h, "changes", "first")
  terraform.plan()
  settle("Plan saved")
  notices = {}

  terraform.plan()
  -- Gone before the identity lookup answers, so `run` finds nothing to start.
  vim.wait(300, function()
    return false
  end)
  vim.fn.delete(h.bin .. "/terraform")

  settle("not found on PATH")
  eq(said("not found on PATH"), true)
  notices = {}

  -- Not "a plan is still running": nothing is. And not the earlier plan either,
  -- which this attempt superseded before it failed to start.
  terraform.apply()
  eq(said("still running"), false)
  eq(said("No reviewed plan"), true)
  eq(applied_marker(h), nil)
end

-- Two plans may overlap: the generation counter decides whose result becomes the
-- reviewed plan. The claim on the directory is a different question, and it used
-- to hold one generation — so the newer plan finishing released the directory
-- while the older terraform was still running in it, and `init`, which exists to
-- refuse exactly that, let itself through.
T["ordering"]["a finished newer plan does not release a running older one"] = function()
  local h = harness()
  local release = h.root .. "/release"
  h.fake("terraform", {
    'if [ "$1" = "plan" ]; then',
    '  for a in "$@"; do case "$a" in -out=*) echo plan > "${a#-out=}";; esac; done',
    -- The first plan waits; every later one returns at once.
    ("  if [ ! -f %s ]; then while [ ! -f %s ]; do sleep 0.05; done; fi"):format(
      vim.fn.shellescape(h.counter),
      vim.fn.shellescape(release)
    ),
    "  exit 2",
    "fi",
    "exit 0",
  })
  start(h)

  -- The slow one. It is still running when the next starts.
  terraform.plan()
  vim.wait(1000, function()
    return #h.calls("plan") > 0
  end, 20)

  vim.fn.writefile({ "second" }, h.counter)
  terraform.plan()
  settle("Plan saved", "Plan failed")
  eq(said("Plan saved"), true)
  notices = {}

  -- The first terraform has not exited. init would rewrite .terraform underneath it.
  terraform.init()
  eq(said("A plan is running"), true)
  eq(#h.calls("init"), 0)

  -- Let it go, and the directory frees up as usual.
  vim.fn.writefile({ "" }, release)
  vim.wait(5000, function()
    notices = {}
    terraform.init()
    return said("Initialised") or said("Init failed")
  end, 100)
  eq(said("A plan is running"), false)
end

-- ---------------------------------------------------------------------------
-- Spawning that raises rather than fails

T["spawn failure"] = new_set()

---Waits out the identity lookup, so what follows lands between it and the spawn.
local function during_the_lookup()
  vim.wait(300, function()
    return false
  end)
end

---Puts the project directory back the way `harness` made it.
---@param h table
local function restore_project(h)
  vim.fn.delete(h.work, "rf")
  vim.fn.mkdir(h.work, "p")
  vim.fn.writefile({ 'resource "null_resource" "x" {}' }, h.work .. "/main.tf")
end

-- Measured: vim.system raises ENOENT before starting anything when its cwd has been
-- removed. It used to raise past plan(), which had already claimed the directory, and
-- every later init and apply answered "a plan is running" for the rest of the session.
T["spawn failure"]["a plan whose directory vanished releases it"] = function()
  local h = harness()
  fake_terraform_by_mode(h)
  fake_aws(h, { "sleep 1" })
  vim.fn.writefile({ "a" }, h.sts)
  start(h, { strict_aws_identity = true })

  next_plan(h, "changes", "first")
  terraform.plan()
  during_the_lookup()
  vim.fn.delete(h.work, "rf")

  settle("Could not start", "Plan saved", "Plan failed")
  eq(said("Could not start"), true)
  eq(#h.calls("plan"), 0)

  restore_project(h)
  notices = {}

  -- The directory is free: init is the operation a stuck planning claim refused.
  terraform.init()
  settle("Initialised", "Init failed", "A plan is running")
  eq(said("A plan is running"), false)
  eq(said("Initialised"), true)
end

-- The other error the same call raises: the path exists but is no longer a directory.
T["spawn failure"]["a plan whose directory became a file releases it"] = function()
  local h = harness()
  fake_terraform_by_mode(h)
  fake_aws(h, { "sleep 1" })
  vim.fn.writefile({ "a" }, h.sts)
  start(h, { strict_aws_identity = true })

  next_plan(h, "changes", "first")
  terraform.plan()
  during_the_lookup()
  vim.fn.delete(h.work, "rf")
  vim.fn.writefile({ "not a directory" }, h.work)

  settle("Could not start", "Plan saved", "Plan failed")
  eq(said("Could not start"), true)
  eq(#h.calls("plan"), 0)

  restore_project(h)
  notices = {}

  terraform.init()
  settle("Initialised", "Init failed", "A plan is running")
  eq(said("A plan is running"), false)
  eq(said("Initialised"), true)
end

T["spawn failure"]["an apply whose directory vanished releases it"] = function()
  local h = harness()
  fake_terraform_by_mode(h)
  fake_aws(h, { "sleep 1" })
  vim.fn.writefile({ "a" }, h.sts)
  start(h, { strict_aws_identity = true })

  next_plan(h, "changes", "first")
  terraform.plan()
  settle("Plan saved")
  notices = {}

  terraform.apply()
  during_the_lookup()
  vim.fn.delete(h.work, "rf")

  settle("Could not start", "Applied", "Apply failed", "Refusing")
  eq(said("Could not start"), true)
  eq(applied_marker(h), nil)

  restore_project(h)
  notices = {}

  -- Not "an apply is already running": nothing is.
  next_plan(h, "changes", "second")
  terraform.plan()
  settle("Plan saved", "Plan failed", "apply is running")
  eq(said("apply is running"), false)
  eq(said("Plan saved"), true)
end

-- init spawns with no await in between, so its directory cannot be removed from a
-- test at the right moment. The raise is injected instead; the two cases above are
-- what prove the injected error is the one that really happens.
T["spawn failure"]["an init that cannot spawn releases the directory"] = function()
  local h = harness()
  fake_terraform_by_mode(h)
  start(h)

  local real = vim.system
  vim.system = function(cmd, opts, on_exit)
    if cmd[1]:match("terraform$") then
      error("ENOENT: no such file or directory (cwd): '" .. tostring(opts.cwd) .. "'")
    end
    return real(cmd, opts, on_exit)
  end

  local ok, err = pcall(terraform.init)
  vim.system = real
  eq(ok, true, err)

  eq(said("Could not start"), true)
  eq(#h.calls("init"), 0)
  notices = {}

  next_plan(h, "changes", "after")
  terraform.plan()
  settle("Plan saved", "Plan failed", "An init is running")
  eq(said("An init is running"), false)
  eq(said("Plan saved"), true)
end

-- The identity lookup is asked after the directory is claimed, so a spawn raising
-- there strands it just as one in the runner would.
T["spawn failure"]["an identity lookup that cannot spawn refuses the plan and releases it"] = function()
  local h = harness()
  fake_terraform_by_mode(h)
  -- Written so the executable check ahead of the spawn answers from this fake
  -- rather than from whatever `aws` the machine running the suite happens to have.
  fake_aws(h)
  vim.fn.writefile({ "a" }, h.sts)
  start(h, { strict_aws_identity = true })

  local real = vim.system
  vim.system = function(cmd, opts, on_exit)
    if cmd[1]:match("aws$") then
      error("ENOENT: no such file or directory")
    end
    return real(cmd, opts, on_exit)
  end

  next_plan(h, "changes", "first")
  local ok, err = pcall(terraform.plan)
  vim.system = real
  eq(ok, true, err)
  settle("Plan saved", "Plan failed", "Could not start")

  -- Under strict, an identity that cannot be established is a refusal. The claim
  -- still has to come back, or the directory stays blocked for the session.
  eq(said("Refusing to plan"), true)
  eq(said("Plan saved"), false)
  notices = {}

  terraform.init()
  settle("Initialised", "Init failed", "A plan is running")
  eq(said("A plan is running"), false)
end

-- ---------------------------------------------------------------------------
-- Who owns which command-line arguments

T["arguments"] = new_set()

---The argument list a command was actually invoked with.
---@param h table
---@param verb string
---@return string|nil
local function invocation(h, verb)
  return h.calls(verb)[1] and h.calls(verb)[1]:match("^%S+%s+(.*)$") or nil
end

-- terraform documents `terraform [global options] <subcommand> [args]`, so global
-- options appended after the subcommand land where it does not look for them.
T["arguments"]["global arguments come before the subcommand"] = function()
  local h = harness()
  fake_terraform_by_mode(h)
  start(h, { global_args = { "-no-color" } })

  next_plan(h, "changes", "first")
  terraform.plan()
  settle("Plan saved", "Plan failed")

  local args = h.invocations()[1]:match("^%S+%s+(.*)$")
  eq(args:sub(1, #"-no-color plan"), "-no-color plan")
end

T["arguments"]["-chdir is dropped from global arguments"] = function()
  local h = harness()
  fake_terraform_by_mode(h)
  start(h)
  configure({ global_args = { "-chdir=/somewhere/else", "-no-color" } })

  eq(said("-chdir was ignored"), true)
  notices = {}

  next_plan(h, "changes", "first")
  terraform.plan()
  settle("Plan saved", "Plan failed")

  local args = invocation(h, "-no-color")
  eq(args ~= nil, true)
  eq(args:find("-chdir", 1, true), nil)
end

-- Terragrunt has its own way of working somewhere else, and the sanitizer only
-- knew terraform's. The lifecycle is keyed by directory throughout — the claims,
-- the saved plan, the AWS context, the plan file — so a CLI running elsewhere
-- makes the runner and the process it started talk about different places.
T["arguments"]["terragrunt working-directory options are dropped"] = function()
  local h = harness()
  fake_terraform_by_mode(h)
  h.fake("terragrunt", { "exit 0" })
  start(h)
  configure({ global_args = { "--working-dir=/somewhere/else", "-no-color" } })

  -- Escaped: a bare `-` is a quantifier in a Lua pattern, and the assertion would
  -- then be about a message nothing produces.
  eq(said("%-%-working%-dir was ignored"), true)
  notices = {}

  next_plan(h, "changes", "first")
  terraform.plan()
  settle("Plan saved", "Plan failed")

  local args = invocation(h, "-no-color")
  eq(args ~= nil, true)
  eq(args:find("working-dir", 1, true), nil)
end

-- Both terragrunt spellings take a value, so they also arrive split from it. The
-- path has to go with the flag: left behind it becomes a positional argument,
-- which for `plan` is the directory terragrunt runs in — the same escape by
-- another route.
T["arguments"]["a working-directory option takes its value with it"] = function()
  local h = harness()
  fake_terraform_by_mode(h)
  start(h)
  configure({
    global_args = { "--working-dir", "/somewhere/else", "-no-color", "--terragrunt-working-dir", "/elsewhere" },
  })

  eq(said("%-%-working%-dir was ignored"), true)
  eq(said("%-%-terragrunt%-working%-dir was ignored"), true)
  notices = {}

  next_plan(h, "changes", "first")
  terraform.plan()
  settle("Plan saved", "Plan failed")

  local args = invocation(h, "-no-color")
  eq(args ~= nil, true)
  eq(args:find("working-dir", 1, true), nil)
  eq(args:find("/somewhere/else", 1, true), nil)
  eq(args:find("/elsewhere", 1, true), nil)
end

-- The runner's headline promise is that a destroy is visible: the review window is
-- marked and the confirmation has to be typed out.
T["arguments"]["-destroy in plan_args is dropped"] = function()
  local h = harness()
  fake_terraform_by_mode(h)
  start(h)
  configure({ plan_args = { "-destroy" } })

  eq(said("-destroy was ignored"), true)
  notices = {}

  next_plan(h, "changes", "first")
  terraform.plan()
  settle("Plan saved", "Plan failed")

  local args = invocation(h, "plan")
  eq(args:find("-destroy", 1, true), nil)
  -- And the plan is still an ordinary one, which is the point: the runner's
  -- record and the command it ran agree.
  eq(said("this plan DESTROYS"), false)
end

T["arguments"]["-out in plan_args is dropped"] = function()
  local h = harness()
  fake_terraform_by_mode(h)
  start(h)
  configure({ plan_args = { "-out=/tmp/somewhere-else.tfplan" } })

  eq(said("-out was ignored"), true)
  notices = {}

  next_plan(h, "changes", "first")
  terraform.plan()
  settle("Plan saved", "Plan failed")

  eq(said("Plan saved"), true)
  -- Exactly one -out, and it is the runtime directory's.
  local args = invocation(h, "plan")
  eq(select(2, args:gsub("%-out=", "")), 1)
  eq(args:find("somewhere%-else"), nil)
  eq(#h.plan_files(), 1)
end

T["arguments"]["-input is dropped wherever the runner sets it"] = function()
  local h = harness()
  fake_terraform_by_mode(h)
  start(h)
  configure({ plan_args = { "-input=true" }, apply_args = { "-input=true" }, init_args = { "-input=true" } })

  -- Once per list, at configuration time, rather than on every command.
  local count = 0
  for _, message in ipairs(notices) do
    if message:match("%-input was ignored") then
      count = count + 1
    end
  end
  eq(count, 3)
  notices = {}

  next_plan(h, "changes", "first")
  terraform.plan()
  settle("Plan saved", "Plan failed")
  eq(invocation(h, "plan"):find("-input=true", 1, true), nil)
end

-- Arguments terraform itself rejects are deliberately left alone, and so is
-- everything else: this is not a general blacklist.
T["arguments"]["other arguments are passed through untouched"] = function()
  local h = harness()
  fake_terraform_by_mode(h)
  start(h)
  configure({ plan_args = { "-refresh=false", "-lock-timeout=30s" } })

  eq(said("was ignored"), false)

  next_plan(h, "changes", "first")
  terraform.plan()
  settle("Plan saved", "Plan failed")

  local args = invocation(h, "plan")
  eq(args:find("-refresh=false", 1, true) ~= nil, true)
  eq(args:find("-lock-timeout=30s", 1, true) ~= nil, true)
end

-- ---------------------------------------------------------------------------
-- The reviewed plan as an artefact

T["integrity"] = new_set()

-- Regression: the chmod was wrapped in pcall, which catches nothing here.
T["integrity"]["a plan that cannot be protected is discarded"] = function()
  local h = harness()
  fake_terraform_by_mode(h)
  start(h)

  -- Only the plan file's chmod fails. The runtime directory's own chmod has to
  -- keep working, or the case would fail before reaching what it tests.
  local original = vim.uv.fs_chmod
  vim.uv.fs_chmod = function(target, mode)
    if tostring(target):match("%.tfplan$") then
      return nil, "EPERM: operation not permitted"
    end
    return original(target, mode)
  end

  next_plan(h, "changes", "first")
  terraform.plan()
  settle("could not be protected", "Plan saved", "Plan failed")

  vim.uv.fs_chmod = original

  eq(said("could not be protected"), true)
  eq(said("Plan saved"), false)
  -- The file goes with it, rather than being left in the runtime directory.
  eq(#h.plan_files(), 0)
  notices = {}

  terraform.apply()
  settle("No reviewed plan", "Applied", "Apply failed")
  eq(said("No reviewed plan"), true)
  eq(applied_marker(h), nil)
  notices = {}

  -- And the directory is not left claimed by the plan that failed.
  next_plan(h, "changes", "second")
  terraform.plan()
  settle("Plan saved", "Plan failed", "still running")
  eq(said("Plan saved"), true)
end

T["integrity"]["an unchanged plan applies"] = function()
  local h = harness()
  fake_terraform_by_mode(h)
  start(h)

  next_plan(h, "changes", "first")
  terraform.plan()
  settle("Plan saved")
  notices = {}

  terraform.apply()
  settle("Applied", "Apply failed", "Refusing")

  eq(said("Applied"), true)
  eq(applied_marker(h), "first")
end

T["integrity"]["a plan whose contents changed is refused"] = function()
  local h = harness()
  fake_terraform_by_mode(h)
  start(h)

  next_plan(h, "changes", "first")
  terraform.plan()
  settle("Plan saved")
  notices = {}

  local plan_file = h.plan_files()[1]
  vim.fn.writefile({ "tampered-with-a-longer-line" }, plan_file)

  terraform.apply()
  settle("Refusing to apply", "Applied", "Apply failed")

  eq(said("has changed on disk"), true)
  eq(applied_marker(h), nil)
  -- Discarded rather than left for the next attempt.
  eq(#h.plan_files(), 0)
  notices = {}

  terraform.apply()
  settle("No reviewed plan", "Applied", "Apply failed")
  eq(said("No reviewed plan"), true)
end

-- The case that says why this is a hash rather than a stat fingerprint: same
-- size, same mtime down to the nanosecond, different bytes.
T["integrity"]["a plan replaced with same-size contents is refused"] = function()
  local h = harness()
  fake_terraform_by_mode(h)
  start(h)

  next_plan(h, "changes", "first")
  terraform.plan()
  settle("Plan saved")
  notices = {}

  local plan_file = h.plan_files()[1]
  local original = vim.fn.readfile(plan_file)[1]
  local stat = vim.uv.fs_stat(plan_file)

  -- Same number of bytes, different content.
  local replacement = original:upper()
  eq(#replacement, #original)
  MiniTest.expect.no_equality(replacement, original)
  vim.fn.writefile({ replacement }, plan_file)

  -- And the timestamp put back, so nothing about the stat has moved either.
  vim.uv.fs_utime(plan_file, stat.atime.sec, stat.mtime.sec)
  local after = vim.uv.fs_stat(plan_file)
  eq(after.size, stat.size)
  eq(after.mtime.sec, stat.mtime.sec)

  terraform.apply()
  settle("Refusing to apply", "Applied", "Apply failed")

  eq(said("has changed on disk"), true)
  eq(applied_marker(h), nil)
end

-- The digest is taken before the review and again after, and the pair has to match.
-- The review is synchronous, so only something inside show() can change the file.
T["integrity"]["a plan that changes while being reviewed is discarded"] = function()
  local h = harness()
  fake_terraform_by_mode(h)
  start(h)

  local original = vim.keymap.set
  vim.keymap.set = function(...)
    vim.keymap.set = original
    for _, file in ipairs(h.plan_files()) do
      vim.fn.writefile({ "changed-while-you-were-reading" }, file)
    end
    return original(...)
  end

  next_plan(h, "changes", "first")
  terraform.plan()
  settle("changed while it was being reviewed", "Plan saved", "Plan failed")

  vim.keymap.set = original

  eq(said("changed while it was being reviewed"), true)
  eq(said("Plan saved"), false)
  eq(#h.plan_files(), 0)
end

T["integrity"]["a plan that vanished is refused"] = function()
  local h = harness()
  fake_terraform_by_mode(h)
  start(h)

  next_plan(h, "changes", "first")
  terraform.plan()
  settle("Plan saved")
  notices = {}

  vim.fn.delete(h.plan_files()[1])

  terraform.apply()
  settle("No reviewed plan", "Refusing", "Applied", "Apply failed")

  eq(applied_marker(h), nil)
  eq(said("Applied"), false)
end

-- The first digest is taken before the identity lookup and the confirmation prompt,
-- which is where the seconds go. Everything between the two used to be unguarded.
T["integrity"]["a plan replaced while the prompt is open is refused"] = function()
  local h = harness()
  fake_terraform_by_mode(h)
  start(h)

  next_plan(h, "changes", "first")
  terraform.plan()
  settle("Plan saved")
  notices = {}

  vim.fn.input = function()
    for _, file in ipairs(h.plan_files()) do
      vim.fn.writefile({ "swapped-while-you-were-deciding" }, file)
    end
    return "yes"
  end

  terraform.apply()
  settle("Refusing to apply", "Applied", "Apply failed")

  eq(said("while identity verification or confirmation was in progress"), true)
  eq(applied_marker(h), nil)
  -- Discarded, so the next attempt has nothing to reuse.
  eq(#h.plan_files(), 0)
end

T["integrity"]["a plan removed while the prompt is open is refused"] = function()
  local h = harness()
  fake_terraform_by_mode(h)
  start(h)

  next_plan(h, "changes", "first")
  terraform.plan()
  settle("Plan saved")
  notices = {}

  vim.fn.input = function()
    for _, file in ipairs(h.plan_files()) do
      vim.fn.delete(file)
    end
    return "yes"
  end

  terraform.apply()
  settle("Refusing to apply", "Applied", "Apply failed")

  eq(said("could not be read after confirmation"), true)
  eq(applied_marker(h), nil)
end

-- A plan larger than one read: the digest has to cover the part of the file that
-- a single read would have stopped short of.
T["integrity"]["a change past the first megabyte is still seen"] = function()
  local h = harness()
  -- Two megabytes of plan, with the marker at the very end of it.
  h.mode = h.root .. "/mode"
  h.marker = h.root .. "/marker"
  h.fake("terraform", {
    ("marker=$(cat %s 2>/dev/null)"):format(vim.fn.shellescape(h.marker)),
    'if [ "$1" = "apply" ]; then',
    ('  for a in "$@"; do case "$a" in *.tfplan) printf "applied %%s\\n" "$(tail -c 32 "$a")" >> %s;; esac; done'):format(
      vim.fn.shellescape(h.log)
    ),
    "  exit 0",
    "fi",
    'if [ "$1" = "plan" ]; then',
    '  for a in "$@"; do case "$a" in -out=*)',
    '    yes xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx | head -c 2000000 > "${a#-out=}"',
    '    printf "%s" "$marker" >> "${a#-out=}";;',
    "  esac; done",
    "  exit 2",
    "fi",
    "exit 0",
  })
  start(h)

  next_plan(h, "changes", "first")
  terraform.plan()
  settle("Plan saved", "Plan failed")
  eq(said("Plan saved"), true)
  notices = {}

  local plan_file = h.plan_files()[1]
  eq(vim.uv.fs_stat(plan_file).size > 1024 * 1024, true)

  -- Only the tail changes; everything a first read would have covered is identical.
  local fd = vim.uv.fs_open(plan_file, "r+", tonumber("600", 8))
  vim.uv.fs_write(fd, "tampered", vim.uv.fs_stat(plan_file).size - 8)
  vim.uv.fs_close(fd)

  terraform.apply()
  settle("Refusing to apply", "Applied", "Apply failed")

  eq(said("has changed on disk"), true)
  eq(applied_marker(h), nil)
end

-- ---------------------------------------------------------------------------
-- init against the rest of the lifecycle

-- init was serialised against apply and nothing else, so it could run beside a plan,
-- and two inits could rewrite the same directory at once.
T["init"] = new_set()

T["init"]["is refused while a plan is running"] = function()
  local h = harness()
  fake_terraform_by_mode(h)
  start(h)

  next_plan(h, "slow", "first")
  terraform.plan()
  vim.wait(400, function()
    return false
  end)
  notices = {}

  terraform.init()
  eq(said("init would rewrite"), true)
  eq(#h.calls("init"), 0)

  settle("Plan saved", "Plan failed")
end

T["init"]["is refused while an apply is running"] = function()
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
  terraform.init()

  eq(said("init would rewrite"), true)
  eq(#h.calls("init"), 0)
  settle("Applied", "Apply failed")
end

T["init"]["a second init is refused while one runs"] = function()
  local h = harness()
  fake_terraform_by_mode(h)
  start(h)

  next_plan(h, "slow-init")
  terraform.init()
  vim.wait(400, function()
    return false
  end)
  notices = {}

  terraform.init()
  eq(said("already running"), true)

  settle("Initialised", "Init failed")
  eq(#h.calls("init"), 1)
end

T["init"]["planning and applying are refused while it runs"] = function()
  local h = harness()
  fake_terraform_by_mode(h)
  start(h)

  next_plan(h, "slow-init")
  terraform.init()
  vim.wait(400, function()
    return false
  end)
  notices = {}

  terraform.plan()
  eq(said("wait for it before planning"), true)
  eq(#h.calls("plan"), 0)

  notices = {}
  terraform.apply()
  eq(said("An init is running"), true)

  notices = {}
  terraform.validate()
  eq(said("wait for it before validating"), true)
  eq(#h.calls("validate"), 0)

  settle("Initialised", "Init failed")
end

-- init can bring in a new provider version, a changed module source or a
-- different backend. A plan computed before it describes none of them.
T["init"]["discards the reviewed plan"] = function()
  local h = harness()
  fake_terraform_by_mode(h)
  start(h)

  next_plan(h, "changes", "first")
  terraform.plan()
  settle("Plan saved")
  eq(#h.plan_files(), 1)
  notices = {}

  next_plan(h, "ok")
  terraform.init()
  settle("Initialised", "Init failed")
  eq(said("Initialised"), true)
  notices = {}

  terraform.apply()
  settle("No reviewed plan", "Applied", "Apply failed")
  eq(said("No reviewed plan"), true)
  eq(applied_marker(h), nil)
  eq(#h.plan_files(), 0)
end

T["init"]["a failed init releases the directory"] = function()
  local h = harness()
  fake_terraform_by_mode(h)
  start(h)

  next_plan(h, "init-fail")
  terraform.init()
  settle("Init failed", "Initialised")
  eq(said("Init failed"), true)
  notices = {}

  -- Not "an init is running": it finished, badly.
  next_plan(h, "changes", "after")
  terraform.plan()
  settle("Plan saved", "Plan failed", "wait for it before planning")
  eq(said("Plan saved"), true)
end

-- The claim is taken before the process starts, so the path where nothing
-- starts has to release it too. Here the binary is simply gone, which `run`
T["init"]["the claim is released when the process cannot start"] = function()
  local h = harness()
  fake_terraform_by_mode(h)
  start(h)

  -- Nothing to resolve the name to. PATH is narrowed as well, so what the machine
  -- running the suite happens to have installed cannot answer for it.
  local full_path = vim.env.PATH
  vim.env.PATH = h.bin
  vim.fn.delete(h.bin .. "/terraform")
  terraform.init()
  vim.env.PATH = full_path

  eq(said("Neither `terraform` nor `tofu` was found on PATH"), true)
  eq(#h.calls("init"), 0)
  notices = {}

  -- Restored, and the directory must not still be claimed by an init that
  -- never ran.
  fake_terraform_by_mode(h)
  next_plan(h, "changes", "after")
  terraform.plan()
  settle("Plan saved", "Plan failed", "wait for it before planning")
  eq(said("Plan saved"), true)
end

T["init"]["a plan can start once it has finished"] = function()
  local h = harness()
  fake_terraform_by_mode(h)
  start(h)

  next_plan(h, "ok")
  terraform.init()
  settle("Initialised", "Init failed")
  notices = {}

  next_plan(h, "changes", "after")
  terraform.plan()
  settle("Plan saved", "Plan failed", "wait for it before planning")
  eq(said("Plan saved"), true)
end

-- ---------------------------------------------------------------------------
-- Strict AWS identity

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

-- The AWS provider reads ~/.aws/credentials and the environment itself, so a
-- machine without the CLI can still be planning against AWS. "No aws" means the
-- identity cannot be checked, which under strict is a refusal — it used to be a
-- silent pass, and the option then guaranteed nothing at all.
T["strict identity"]["refuses when the aws CLI is missing"] = function()
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
  settle("Refusing to plan", "Plan saved", "Plan failed")

  eq(said("Refusing to plan"), true)
  eq(said("Plan saved"), false)
  eq(#h.plan_files(), 0)
end

-- The same for every other way the question goes unanswered.
T["strict identity"]["refuses when STS exits non-zero"] = function()
  local h = harness()
  fake_terraform(h)
  fake_aws(h)
  vim.fn.writefile({ "fail" }, h.sts)
  start(h, { strict_aws_identity = true })

  terraform.plan()
  settle("Refusing to plan", "Plan saved", "Plan failed")

  eq(said("Refusing to plan"), true)
  eq(said("Plan saved"), false)
  eq(#h.plan_files(), 0)
end

T["strict identity"]["refuses when the STS answer cannot be read"] = function()
  local h = harness()
  fake_terraform(h)
  h.fake("aws", { "echo 'not json at all'", "exit 0" })
  start(h, { strict_aws_identity = true })

  terraform.plan()
  settle("Refusing to plan", "Plan saved", "Plan failed")

  eq(said("could not read the STS response"), true)
  eq(said("Plan saved"), false)
end

-- Asserted on the strict wording, not on "Refusing to apply": a plan bound to an
-- account also drifts away from an unknown one, and matching that message would
-- pass whether or not this guard exists.
T["strict identity"]["refuses an apply whose identity cannot be established"] = function()
  local h = harness()
  fake_terraform(h)
  fake_aws(h)
  vim.fn.writefile({ "a" }, h.sts)
  start(h, { strict_aws_identity = true })

  terraform.plan()
  settle("Plan saved", "Plan failed")
  eq(said("Plan saved"), true)
  notices = {}

  vim.fn.writefile({ "fail" }, h.sts)
  terraform.apply()
  settle("Refusing to apply", "Applied", "Apply failed")

  eq(said("the AWS identity could not be determined"), true)
  eq(#h.calls("apply"), 0)

  -- Still there: fix the credentials and apply again.
  notices = {}
  vim.fn.writefile({ "a" }, h.sts)
  terraform.apply()
  settle("Applied", "Apply failed", "No reviewed plan")
  eq(said("Applied"), true)
end

-- The case the comparison alone cannot catch, and the reason the guard runs
-- before it: a plan made with strict off carries no identity, so an apply that
-- also cannot establish one compares equal — nil against nil — and proceeds.
-- Turning the option on between the two is all it takes to get there.
T["strict identity"]["refuses an unidentified apply of an unidentified plan"] = function()
  local h = harness()
  fake_terraform(h)
  fake_aws(h)
  vim.fn.writefile({ "a" }, h.sts)
  start(h, {})

  terraform.plan()
  settle("Plan saved", "Plan failed")
  eq(said("Plan saved"), true)
  eq(#h.calls("sts"), 0)
  notices = {}

  -- Strict is turned on, and now nothing can answer.
  configure({ strict_aws_identity = true })
  vim.fn.writefile({ "fail" }, h.sts)

  terraform.apply()
  settle("Refusing to apply", "Applied", "Apply failed")

  eq(said("the AWS identity could not be determined"), true)
  eq(#h.calls("apply"), 0)
end

-- Off by default, and off means the old behaviour exactly: no lookup, no refusal.
T["strict identity"]["plans without an identity when it is off"] = function()
  local h = harness()
  fake_terraform(h)
  -- Nothing on PATH could answer even if it were asked.
  vim.env.PATH = h.bin
  vim.env.XDG_RUNTIME_DIR = h.runtime
  terraform.setup({})
  vim.cmd.edit({ args = { h.work .. "/main.tf" } })
  notices = {}

  terraform.plan()
  settle("Plan saved", "Plan failed", "Refusing to plan")

  eq(said("Plan saved"), true)
  eq(said("Refusing"), false)
end

-- The identity lookup is an await between the "already running" guard and the start
-- of the process, so the directory has to be claimed across it.
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

-- Claiming the generation after the lookup would order plans by how quickly STS
-- answered rather than by when they were asked for.
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

-- ---------------------------------------------------------------------------
-- Leaving Neovim

T["cleanup"] = new_set()

---Runs what leaving Neovim would run, without leaving it.
local function leave()
  vim.api.nvim_exec_autocmds("VimLeavePre", { group = "terraform_nvim_cleanup" })
end

---The directory plan files are written to.
---@param h table
---@return string
local function plan_dir(h)
  return h.runtime .. "/terraform.nvim"
end

T["cleanup"]["a reviewed plan is removed on exit"] = function()
  local h = harness()
  fake_terraform(h)
  start(h)

  terraform.plan()
  settle("Plan saved")
  eq(#h.plan_files(), 1)

  leave()
  eq(#h.plan_files(), 0)
end

-- The file is written by the command, so it exists before the callback that
-- would record it does. A session ending in that window used to leave it behind:
-- nothing knew about a plan that was not reviewed yet.
T["cleanup"]["a plan still running is removed on exit"] = function()
  local h = harness()
  local release = h.root .. "/release"
  -- Writes its -out file, then waits to be let go, so the case decides when the
  -- command is still running and when it has finished.
  fake_terraform(h, {
    'if [ "$1" = "plan" ]; then',
    '  for a in "$@"; do case "$a" in -out=*) echo plan > "${a#-out=}";; esac; done',
    ("  while [ ! -f %s ]; do sleep 0.05; done"):format(vim.fn.shellescape(release)),
    "  exit 2",
    "fi",
  })
  start(h)

  terraform.plan()
  vim.wait(5000, function()
    return #h.plan_files() > 0
  end, 20)
  eq(#h.plan_files(), 1)
  eq(said("Plan saved"), false)

  leave()
  eq(#h.plan_files(), 0)

  -- Let it finish inside this case rather than during a later one. It now finds
  -- its own file gone, which is what a session that really left would have done.
  vim.fn.writefile({ "" }, release)
  settle("could not be protected", "Plan saved", "Plan failed")
  eq(said("Plan saved"), false)
end

-- fs_unlink returns nil, err rather than raising, so the pcall this used to be
-- wrapped in reported success for a file that was still there.
T["cleanup"]["a plan file that cannot be removed is reported"] = function()
  local h = harness()
  fake_terraform(h)
  start(h)

  terraform.plan()
  settle("Plan saved")
  local plan = h.plan_files()[1]

  -- Unlinking needs write permission on the directory, not on the file.
  vim.fn.setfperm(plan_dir(h), "r-x------")
  notices = {}
  terraform.discard()

  eq(said("could not be removed"), true)
  eq(transcript():find(plan, 1, true) ~= nil, true)
  eq(#h.plan_files(), 1)

  vim.fn.setfperm(plan_dir(h), "rwx------")
end

-- The exception used to escape the async callback and take the outcome notification
-- with it, leaving an operation that changed infrastructure unreported.
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
