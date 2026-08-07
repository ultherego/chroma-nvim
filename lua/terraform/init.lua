-- terraform.nvim — a plan/apply runner for Terraform and Terragrunt.
--
-- Deliberately thin. The survey behind CONTRACT.md found that most of what was
-- originally planned for this plugin already exists elsewhere in this config:
-- formatting is conform's `terraform_fmt`, validation is tflint running as a
-- language server. What was missing was a way to run a plan and apply it
-- without leaving the editor.
--
-- THE SAFETY MODEL, which is the whole point:
--
-- Naive runners call `terraform apply -auto-approve`. That applies a plan
-- nobody read, computed at a moment nobody chose. This one never does that.
--
--   1. `plan` writes the plan to a file and shows it.
--   2. You read it.
--   3. `apply` applies THAT FILE.
--
-- Terraform documents the consequence: "When you pass a saved plan file to
-- terraform apply, Terraform performs the operations in the saved plan without
-- prompting you for confirmation" — the file is the approval. So apply never
-- needs -auto-approve.
--
-- What that fixes, stated exactly: the saved plan fixes the planned action set.
-- The runner additionally pins the executable that carries it out and, when
-- strict_aws_identity is enabled, verifies the AWS account and principal before
-- applying. External infrastructure, credentials and remote state may still
-- change independently in between. This comment used to claim drift between
-- reading and applying was impossible; it is not, and claiming it was the more
-- dangerous of the two errors.
--
-- Destroy is not a separate, scarier command. It is `plan -destroy`, reviewed
-- the same way and applied through the same step. There is no key in this
-- plugin that destroys anything without a plan having been read first.
--
-- Plan files can contain sensitive values, so they are written to
-- $XDG_RUNTIME_DIR (tmpfs, user-only) with mode 0600 and removed on exit.
--
-- Kept free of any dependency on the rest of this configuration.

local M = {}

--- Extra arguments are per subcommand, not global.
---
--- A single list for all four commands was wrong twice over. It was appended
--- after the whole argument list, which for apply put it after the plan file —
--- terraform parses options before the positional argument, so any non-empty
--- value broke the one command that must not break. And the commands do not
--- share an option set: `-lock-timeout` means nothing to validate,
--- `-upgrade` only exists on init, `-refresh=false` only on plan and apply.
--- Whatever was put in the shared list was wrong for at least one command.
---
--- `global_args` is for the few options every command does accept, such as
--- `-chdir` style flags or `-no-color` overrides. Per-command lists come after
--- it, so the more specific one wins where terraform lets a later flag win.
local defaults = {
  keymaps = false,
  --- Ask STS which account and principal the credentials resolve to, record it
  --- with the plan, and refuse an apply that would run as anyone else.
  ---
  --- Off by default: it is a network round trip on every plan and every apply,
  --- and the environment comparison already catches the ordinary mistake of
  --- switching profile between reading a plan and applying it. On when the
  --- account matters more than the latency.
  strict_aws_identity = false,
  global_args = {},
  init_args = {},
  validate_args = {},
  plan_args = {},
  apply_args = {},
}

M.options = vim.deepcopy(defaults)

--- Saved plans, keyed by the directory they belong to.
---@type table<string, table>
local plans = {}

--- Monotonic counter per directory. Two plans can be in flight at once — start
--- one, edit, start another — and vim.system callbacks arrive in whatever order
--- the processes finish. Without this the slower run overwrites the newer plan
--- after you have already read the newer one, and apply then executes something
--- other than what was on screen. That is the exact guarantee this plugin
--- exists to make, so the stale callback is discarded instead.
---@type table<string, integer>
local generation = {}

--- Directories with a plan in flight, holding the generation that claimed them.
---
--- `generation` alone was not enough, and the gap between the two is the whole
--- point of this table. It orders callbacks: it decides which of two plans in
--- flight is allowed to record its result. It says nothing about the plan that
--- was reviewed *before* either of them started, which stayed in `plans[dir]`
--- and stayed appliable for as long as the new plan took to run — and, if the
--- new plan ended in "No changes" or an error, kept staying appliable
--- afterwards, because neither of those paths touched it. Verified against the
--- module with fake binaries: after a plan that reported no changes, apply was
--- still handed the plan from before it.
---
--- Asking for a new plan is a statement that the old one is no longer the
--- picture you want to act on. So the request itself supersedes it, at the
--- moment it is made rather than when it succeeds.
---
--- The generation is stored rather than a boolean so a finishing plan can only
--- clear the state it claimed. An older callback arriving late must not
--- announce that a newer plan has stopped running.
---@type table<string, integer>
local planning = {}

--- Directories with an apply in flight.
---
--- An apply cannot be taken back and it is the one operation here that changes
--- real infrastructure, so for as long as one is running this refuses anything
--- that could pull the ground out from under it: a second apply handed the same
--- plan file, a new plan whose bookkeeping unlinks the file being applied, a
--- discard doing the same, an init rewriting `.terraform` mid-run.
---
--- `validate` is deliberately not refused: it reads configuration and provider
--- schemas, and does not touch state or the backend, so it cannot collide with
--- an apply. Refusing it would only be theatre.
---
--- The audit sketched a full state machine over planning/reviewed/applying.
--- This is the smaller half of it, and the half that carries the risk: the
--- planning states are already ordered by `generation`, and only apply mutates
--- anything outside this process.
---@type table<string, boolean>
local applying = {}

--- What the next subprocess will authenticate as.
---
--- Recorded with every plan and compared before apply. The AWS module sets
--- these on the Neovim process, so switching profile between reading a plan and
--- applying it would run the apply against a different account while terraform
--- happily performs the operations the plan described.
---
--- By default this compares environment, not identity: it does not ask STS who
--- the credentials actually resolve to, because that is a network round trip on
--- every plan. `:AwsWhoami` answers that question when it matters, and
--- `strict_aws_identity` folds the answer into this comparison for people who
--- would rather pay the round trip than trust the environment.
---
--- The environment is a weak proxy, and the gap is real. AWS_PROFILE unchanged
--- still covers new static credentials, a refreshed SSO session pointing at
--- another account, an edited ~/.aws/credentials, the same profile name now
--- assuming a different role, and credential environment variables that take
--- precedence over the profile entirely. None of those change the two fields
--- below.
---@param identity table|nil what STS said, when it was asked
---@return table
local function aws_context(identity)
  return {
    profile = vim.env.AWS_PROFILE,
    region = vim.env.AWS_REGION or vim.env.AWS_DEFAULT_REGION,
    account = identity and identity.account,
    arn = identity and identity.arn,
  }
end

--- Asks STS who the current credentials actually are.
---
--- Off unless `strict_aws_identity` is set, in which case it runs once per plan
--- and once per apply. Not cached: a cache is precisely a way to be told about
--- the credentials that were in effect earlier, which is the thing being
--- guarded against.
---
--- Two kinds of "no answer" are distinguished. No `aws` on PATH means this is
--- most likely not an AWS project, and the check is skipped without comment.
--- An `aws` that is present and refuses is worth saying out loud, because the
--- plan is then recorded without the protection the option was turned on for.
---@param callback fun(identity: table|nil, err: string|nil)
local function aws_identity(callback)
  if not M.options.strict_aws_identity then
    callback(nil)
    return
  end

  if vim.fn.executable("aws") ~= 1 then
    callback(nil)
    return
  end

  vim.system({ "aws", "sts", "get-caller-identity", "--output", "json" }, { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        callback(nil, ((result.stderr or "") .. (result.stdout or "")):gsub("%s+$", ""))
        return
      end

      local ok, decoded = pcall(vim.json.decode, result.stdout or "")
      if not ok or type(decoded) ~= "table" or not decoded.Account then
        callback(nil, "could not read the STS response")
        return
      end

      callback({ account = decoded.Account, arn = decoded.Arn })
    end)
  end)
end

---@param a table
---@param b table
---@return string|nil description of the difference
local function context_differs(a, b)
  local function show(v)
    return v == nil and "(unset)" or v
  end
  if a.profile ~= b.profile then
    return ("AWS_PROFILE changed: %s -> %s"):format(show(a.profile), show(b.profile))
  end
  if a.region ~= b.region then
    return ("AWS region changed: %s -> %s"):format(show(a.region), show(b.region))
  end
  -- Only ever set when strict_aws_identity was on. nil on one side and a value
  -- on the other is itself a difference, which covers the case the audit asked
  -- for: STS answered when the plan was made and cannot be reached now.
  if a.account ~= b.account then
    return ("AWS account changed: %s -> %s"):format(show(a.account), show(b.account))
  end
  if a.arn ~= b.arn then
    return ("AWS identity changed: %s -> %s"):format(show(a.arn), show(b.arn))
  end
  return nil
end

---Releases a directory claimed by `plan`, if this plan is still the current one.
---@param dir string
---@param mine integer the generation that claimed it
local function finish_planning(dir, mine)
  if planning[dir] == mine then
    planning[dir] = nil
  end
end

---Drops a saved plan and removes its file.
---@param dir string
local function discard_plan(dir)
  local saved = plans[dir]
  if saved then
    pcall(vim.uv.fs_unlink, saved.path)
    plans[dir] = nil
  end
end

---Terragrunt owns a directory when terragrunt.hcl sits in it. Running
---`terraform` there would ignore the generated configuration entirely.
---@param dir string
---@return string
local function binary_for(dir)
  for _, name in ipairs({ "terragrunt.hcl", "terragrunt.stack.hcl" }) do
    if vim.uv.fs_stat(vim.fs.joinpath(dir, name)) then
      return "terragrunt"
    end
  end
  return vim.fn.executable("terraform") == 1 and "terraform" or "tofu"
end

---The directory a command should run in: the nearest one holding .tf or
---terragrunt files, starting from the current buffer.
---@return string|nil
local function root_dir()
  local buf = vim.api.nvim_buf_get_name(0)
  local start = buf ~= "" and vim.fs.dirname(buf) or vim.fn.getcwd()

  -- Must stay in step with binary_for, which already knew about
  -- terragrunt.stack.hcl. A stack-only directory was invisible here, so every
  -- command reported "nothing found" in a project that plainly had one.
  local found = vim.fs.find(function(name)
    return name:match("%.tf$") or name == "terragrunt.hcl" or name == "terragrunt.stack.hcl"
  end, { path = start, upward = true, type = "file" })[1]

  return found and vim.fs.dirname(found) or nil
end

---Somewhere to put a plan that is not persistent storage.
---@return string|nil path, string|nil err
local function plan_path()
  local dir, err = require("terraform.runtime").secure_dir("terraform.nvim")
  if not dir then
    return nil,
      ("%s\nA plan file can quote sensitive values, so this plugin will not fall back to persistent storage."):format(
        err
      )
  end
  return ("%s/plan.%d.%d.tfplan"):format(dir, vim.uv.os_getpid(), vim.uv.hrtime())
end

---Shows command output in a scratch buffer.
---@param lines string[]
---@param title string
local function show(lines, title)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  -- A plan can quote variable values, so the same rule as everywhere else
  -- applies: it does not get persisted.
  vim.bo[buf].undofile = false
  vim.bo[buf].swapfile = false
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "terraform-plan"

  -- Focus is deliberately left where it was.
  --
  -- These windows open from an async callback. A plan can take a minute, and
  -- the natural thing to do meanwhile is edit another file — at which point a
  -- split that grabs the cursor sends your keystrokes into a non-modifiable
  -- scratch buffer without warning. Verified: it did exactly that.
  --
  -- The output is visible either way; `q` closes it once you move to it.
  local previous = vim.api.nvim_get_current_win()

  vim.cmd("botright split")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_win_set_height(win, math.min(#lines + 1, math.floor(vim.o.lines * 0.6)))
  vim.wo[win].winbar = title

  if vim.api.nvim_win_is_valid(previous) then
    vim.api.nvim_set_current_win(previous)
  end

  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = buf, nowait = true, desc = "Close" })
end

---Opens the output window, reporting failure instead of raising it.
---
---`show` opens a split, and a split can fail — E36 when the layout leaves no
---room for one. Every call site is inside an async callback, where raising
---abandons whatever bookkeeping that callback had left to do. For plan that
---meant a plan file terraform had already written was neither cleaned up nor
---recorded, and the traceback was the only sign anything had happened.
---
---Presentation must not be able to decide the outcome of an operation. This
---makes the failure a value the caller handles.
---@param lines string[]
---@param title string
---@return boolean shown
local function try_show(lines, title)
  local ok, err = pcall(show, lines, title)
  if not ok then
    vim.notify(("Could not open the output window: %s"):format(err), vim.log.levels.ERROR)
  end
  return ok
end

---Assembles the argument list for one subcommand.
---
---Order is the point of this function. Our own flags come first, then the
---user's global arguments, then the user's arguments for this command, and
---positional arguments last. `terraform apply` takes the plan file as a
---positional argument and expects options ahead of it, so anything appended
---blindly to the end of an apply lands in the wrong place.
---@param command string the subcommand, which also names its option list
---@param flags string[] our own flags
---@param positional? string[] arguments that must come last
---@return string[]
local function argv(command, flags, positional)
  local out = { command }
  vim.list_extend(out, flags)
  vim.list_extend(out, M.options.global_args or {})
  -- init_args, validate_args, plan_args, apply_args — named after the
  -- subcommand so this stays a lookup rather than a branch per command.
  vim.list_extend(out, M.options[command .. "_args"] or {})
  vim.list_extend(out, positional or {})
  return out
end

---@param args string[]
---@param dir string
---@param on_done fun(code: integer, lines: string[])
---@param binary? string an executable resolved earlier; re-resolved from dir when absent
---@return vim.SystemObj|nil handle nil when nothing was started
local function run(args, dir, on_done, binary)
  local name = binary or binary_for(dir)
  -- exepath() is idempotent for a path that is already absolute, so this
  -- accepts both a bare name and a path pinned at plan time. Verified.
  local bin = vim.fn.executable(name) == 1 and vim.fn.exepath(name) or ""

  if bin == "" then
    vim.notify(("`%s` not found on PATH"):format(name), vim.log.levels.ERROR)
    return nil
  end

  local cmd = { bin }
  vim.list_extend(cmd, args)

  vim.notify(("Running %s %s…"):format(vim.fs.basename(bin), args[1]), vim.log.levels.INFO)

  return vim.system(cmd, { cwd = dir, text = true }, function(result)
    local out = (result.stdout or "") .. (result.stderr or "")
    local lines = vim.split(out:gsub("%s+$", ""), "\n", { trimempty = false })
    vim.schedule(function()
      on_done(result.code, lines)
    end)
  end)
end

---@param destroy boolean
local function plan(destroy)
  local dir = root_dir()
  if not dir then
    vim.notify("No .tf or terragrunt.hcl found above this buffer", vim.log.levels.WARN)
    return
  end

  if applying[dir] then
    vim.notify(
      "An apply is running in this directory — planning now would delete the plan it is applying",
      vim.log.levels.WARN
    )
    return
  end

  local path, err = plan_path()
  if not path then
    vim.notify(err, vim.log.levels.ERROR)
    return
  end

  -- Resolve the executable once, here, and record where it resolved to. Saving
  -- the name would only mean apply looks it up again later, and by then PATH
  -- may point somewhere else, `terraform` may have been uninstalled leaving
  -- `tofu` to answer for it, or a terragrunt.hcl may have appeared in the
  -- directory. None of those three produce the plan that was on screen.
  local binary_name = binary_for(dir)
  local binary = vim.fn.exepath(binary_name)
  if binary == "" then
    vim.notify(("`%s` not found on PATH"):format(binary_name), vim.log.levels.ERROR)
    return
  end

  local flags = { "-no-color", "-input=false", "-detailed-exitcode", "-out=" .. path }
  if destroy then
    table.insert(flags, 1, "-destroy")
  end
  local args = argv("plan", flags)

  -- Claim this generation before anything asynchronous happens, the STS call
  -- included. Claiming it after would order plans by how fast their identity
  -- lookup answered rather than by when they were asked for, and the older one
  -- could end up counted as the newer.
  generation[dir] = (generation[dir] or 0) + 1
  local mine = generation[dir]

  -- Claimed in the same breath, and for the same reason: from here on there is
  -- an await before anything else happens, and apply must not walk through it
  -- and pick up the plan this one is replacing.
  planning[dir] = mine

  -- The old plan stops being appliable now, not when this one succeeds.
  -- Asking for a new plan says the old picture is out of date; if this plan
  -- then fails, or reports no changes, the honest state is "nothing reviewed",
  -- not "the previous answer still stands".
  discard_plan(dir)

  aws_identity(function(identity, identity_err)
    if generation[dir] ~= mine then
      -- Superseded while the identity lookup was in flight. Nothing has been
      -- started yet, so there is nothing to clean up but the reservation —
      -- which the newer plan has already taken over, making this a no-op.
      finish_planning(dir, mine)
      return
    end

    -- Said out loud rather than degraded quietly: with the option on, a plan
    -- recorded without an identity is not carrying the protection it was
    -- turned on for.
    if identity_err then
      vim.notify(
        ("Could not determine the AWS identity, so this plan will not be bound to one:\n%s"):format(identity_err),
        vim.log.levels.WARN
      )
    end

    local context = aws_context(identity)

    local process = run(args, dir, function(code, lines)
      if generation[dir] ~= mine then
        -- A newer plan was started while this one was running. Its output would
        -- be misleading and its file must not become the plan that apply uses.
        pcall(vim.uv.fs_unlink, path)
        finish_planning(dir, mine)
        return
      end

      -- Past the generation check this callback is the end of this plan's life,
      -- whichever branch below it takes. Released here rather than on each exit
      -- so a branch added later cannot forget to, and leave the directory
      -- refusing every apply for the rest of the session.
      finish_planning(dir, mine)

      -- Showing the plan is not decoration, it is the review step, and a plan
      -- becomes appliable only because it was reviewed. If the window could not
      -- be opened then nothing was read, so this fails closed: the file
      -- terraform wrote is removed and no plan is recorded. The plan this one
      -- replaced is already gone, discarded when this run was asked for, so
      -- nothing is left that :TerraformApply could run.
      if not try_show(lines, (" %s plan%s "):format(vim.fs.basename(dir), destroy and " -destroy" or "")) then
        pcall(vim.uv.fs_unlink, path)
        vim.notify(
          "The plan ran, but it could not be shown, so it was discarded unread.\nNothing to apply — run :TerraformPlan again.",
          vim.log.levels.ERROR
        )
        return
      end

      -- -detailed-exitcode: 0 no changes, 1 error, 2 changes present.
      if code == 0 then
        pcall(vim.uv.fs_unlink, path)
        vim.notify("No changes — infrastructure matches the configuration", vim.log.levels.INFO)
      elseif code == 2 then
        -- terraform creates the plan file itself, under the ambient umask — it
        -- came out 0644 in testing, which is world-readable and a plan can quote
        -- variable values. Tightened as soon as it exists. It cannot be
        -- pre-created with the right mode because terraform replaces it.
        pcall(vim.uv.fs_chmod, path, tonumber("600", 8))

        -- Nothing to discard first: the plan this one replaces was dropped, and
        -- its file unlinked, when this run was asked for. That is also what
        -- keeps superseded plans from leaking files into XDG_RUNTIME_DIR until
        -- logout.
        plans[dir] = { path = path, destroy = destroy, context = context, binary = binary }
        vim.notify(
          ("Plan saved%s. Review it, then :TerraformApply%s"):format(
            identity and (" as " .. (identity.arn or identity.account)) or "",
            destroy and "  (this plan DESTROYS)" or ""
          ),
          destroy and vim.log.levels.WARN or vim.log.levels.INFO
        )
      else
        pcall(vim.uv.fs_unlink, path)
        vim.notify("Plan failed", vim.log.levels.ERROR)
      end
    end, binary)

    -- Nothing started, so no callback will arrive to release the claim. Without
    -- this the directory would refuse every apply for the rest of the session,
    -- waiting for a plan that is not running. `run` has already said why.
    if not process then
      finish_planning(dir, mine)
    end
  end)
end

function M.plan()
  plan(false)
end

function M.plan_destroy()
  plan(true)
end

---Applies the plan that was last reviewed for this directory.
function M.apply()
  local dir = root_dir()
  if not dir then
    vim.notify("No .tf or terragrunt.hcl found above this buffer", vim.log.levels.WARN)
    return
  end

  -- The plan survives in `plans[dir]` until the apply callback clears it, so
  -- without this a second :TerraformApply during a long apply finds it, prompts,
  -- and hands the same plan file to a second process.
  if applying[dir] then
    vim.notify("An apply is already running for this directory", vim.log.levels.WARN)
    return
  end

  -- A plan is being computed for this directory, so there is by definition no
  -- current reviewed plan: the one that was there has been discarded and the
  -- replacement has not been read yet. Saying so is better than the bare "no
  -- reviewed plan" below, which would be true but would read as though the plan
  -- had gone missing.
  if planning[dir] then
    vim.notify(
      "A new plan is still running for this directory — wait for it, read it, then apply",
      vim.log.levels.WARN
    )
    return
  end

  local saved = plans[dir]
  if not saved or not vim.uv.fs_stat(saved.path) then
    plans[dir] = nil
    vim.notify("No reviewed plan for this directory — run :TerraformPlan first", vim.log.levels.WARN)
    return
  end

  -- Pinned when the plan was made. If it has since been removed or replaced by
  -- something non-executable, there is no safe substitute: applying a terraform
  -- plan with tofu, or bypassing terragrunt, is not the reviewed operation.
  if vim.fn.executable(saved.binary or "") ~= 1 then
    vim.notify(
      ("The executable that created this plan is no longer available (%s).\nRun :TerraformPlan again."):format(
        saved.binary or "unknown"
      ),
      vim.log.levels.ERROR
    )
    return
  end

  -- Claimed here, before the identity lookup, not after the prompt. With
  -- strict_aws_identity on there is now an await between the guard above and
  -- the start of the process, and leaving the directory unclaimed across it
  -- would let a second :TerraformApply walk straight through — the race the
  -- guard exists to close. Every path out from here releases it.
  applying[dir] = true
  local function release()
    applying[dir] = nil
  end

  aws_identity(function(identity, identity_err)
    -- With the option on, an identity that cannot be read is not "no identity":
    -- the plan recorded one, and nil compares as a difference below. This only
    -- makes the reason legible.
    if identity_err then
      vim.notify(("Could not determine the AWS identity:\n%s"):format(identity_err), vim.log.levels.WARN)
    end

    -- The plan file fixes what terraform will do. It does not fix who it will
    -- do it as: credentials come from the environment, which the AWS module can
    -- change between reading a plan and applying it. Terraform would carry out
    -- the reviewed operations against whatever account is configured now.
    local drift = context_differs(saved.context or {}, aws_context(identity))
    if drift then
      vim.notify(
        ("Refusing to apply: %s since this plan was made.\nRun :TerraformPlan again under the current credentials."):format(
          drift
        ),
        vim.log.levels.ERROR
      )
      return release()
    end

    -- The plan file is the approval as far as terraform is concerned. This
    -- prompt is for the human: applying is the point of no return, and a
    -- destroy plan deserves to be typed out rather than confirmed by reflex.
    local want = saved.destroy and "destroy" or "yes"
    local answer = vim.fn.input({
      prompt = ("Apply this plan to %s? Type %q to confirm: "):format(vim.fs.basename(dir), want),
    })

    if answer ~= want then
      vim.notify("Cancelled", vim.log.levels.INFO)
      return release()
    end

    local process = run(argv("apply", { "-no-color", "-input=false" }, { saved.path }), dir, function(code, lines)
      release()

      -- Spent, whatever happened: terraform refuses to reuse a plan file, and
      -- keeping it would only invite applying a stale one.
      discard_plan(dir)

      -- No state hangs off this one — the lock is already released and the plan
      -- already discarded above — but the outcome of an operation that changed
      -- infrastructure must still be reported if the window cannot open.
      try_show(lines, (" %s apply "):format(vim.fs.basename(dir)))
      if code == 0 then
        vim.notify("Applied", vim.log.levels.INFO)
      else
        vim.notify("Apply failed", vim.log.levels.ERROR)
      end
    end, saved.binary)

    -- Nothing started, so nothing will arrive to clear the flag. Without this
    -- the directory stays locked against plan, apply, init and discard for the
    -- rest of the session.
    if not process then
      release()
    end
  end)
end

function M.init()
  local dir = root_dir()
  if not dir then
    vim.notify("No .tf or terragrunt.hcl found above this buffer", vim.log.levels.WARN)
    return
  end

  -- init rewrites `.terraform/` — providers, modules, backend config — under a
  -- process that is currently reading it.
  if applying[dir] then
    vim.notify("An apply is running in this directory — init would rewrite .terraform under it", vim.log.levels.WARN)
    return
  end

  run(argv("init", { "-no-color", "-input=false" }), dir, function(code, lines)
    try_show(lines, (" %s init "):format(vim.fs.basename(dir)))
    vim.notify(code == 0 and "Initialised" or "Init failed", code == 0 and vim.log.levels.INFO or vim.log.levels.ERROR)
  end)
end

function M.validate()
  local dir = root_dir()
  if not dir then
    vim.notify("No .tf or terragrunt.hcl found above this buffer", vim.log.levels.WARN)
    return
  end

  run(argv("validate", { "-no-color" }), dir, function(code, lines)
    if code == 0 then
      vim.notify("Configuration is valid", vim.log.levels.INFO)
    else
      try_show(lines, (" %s validate "):format(vim.fs.basename(dir)))
    end
  end)
end

---Discards any reviewed plan without applying it.
function M.discard()
  local count, held = 0, 0
  for dir, _ in pairs(vim.deepcopy(plans)) do
    if applying[dir] then
      -- Unlinking it now would delete the file out from under a running apply.
      held = held + 1
    else
      discard_plan(dir)
      count = count + 1
    end
  end
  vim.notify(
    held > 0 and ("Discarded %d saved plan(s); %d left alone, an apply is using them"):format(count, held)
      or ("Discarded %d saved plan(s)"):format(count),
    vim.log.levels.INFO
  )
end

--- Internals exposed for the test suite only.
M._test = {
  context_differs = context_differs,
  argv = argv,
}

---@param opts table|nil
function M.setup(opts)
  opts = opts or {}

  -- `args` was a single list appended to every command, which put it after the
  -- plan file on apply. Dropping it silently would leave flags the user
  -- believes are in effect quietly doing nothing.
  if opts.args ~= nil then
    vim.notify(
      "terraform.nvim: `args` is gone — it broke apply and meant different things per command. "
        .. "Use `global_args`, or `init_args` / `validate_args` / `plan_args` / `apply_args`. "
        .. "The value given was ignored.",
      vim.log.levels.WARN
    )
    opts = vim.deepcopy(opts)
    opts.args = nil
  end

  M.options = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts)

  local commands = {
    TerraformInit = M.init,
    TerraformValidate = M.validate,
    TerraformPlan = M.plan,
    TerraformPlanDestroy = M.plan_destroy,
    TerraformApply = M.apply,
    TerraformDiscard = M.discard,
  }

  for name, fn in pairs(commands) do
    vim.api.nvim_create_user_command(name, fn, { desc = name })
  end

  -- Plan files outlive the command that made them but must not outlive the
  -- session; they are on tmpfs, but a stale plan is its own hazard.
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("terraform_nvim_cleanup", { clear = true }),
    callback = function()
      for _, saved in pairs(plans) do
        pcall(vim.uv.fs_unlink, saved.path)
      end
    end,
  })

  if M.options.keymaps then
    vim.keymap.set("n", "<leader>ti", M.init, { desc = "Terraform init" })
    vim.keymap.set("n", "<leader>tv", M.validate, { desc = "Terraform validate" })
    vim.keymap.set("n", "<leader>tp", M.plan, { desc = "Terraform plan" })
    vim.keymap.set("n", "<leader>ta", M.apply, { desc = "Apply the reviewed plan" })
    vim.keymap.set("n", "<leader>td", M.discard, { desc = "Discard the reviewed plan" })
    -- Destroy has no single-key mapping on purpose. It is reached by typing
    -- the command, and even then it only produces a plan to read.
  end
end

return M
