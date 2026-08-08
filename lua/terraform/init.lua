-- terraform.nvim — a plan/apply runner for Terraform and Terragrunt.
-- Safety model, concurrency and options: :help devops-nvim-terraform.

local M = {}

local defaults = {
  keymaps = false,
  -- Bind plans to the AWS account and principal STS reports. Off: a round trip per plan and apply.
  strict_aws_identity = false,
  -- global_args go before the subcommand; the rest after our own flags.
  global_args = {},
  init_args = {},
  validate_args = {},
  plan_args = {},
  apply_args = {},
}

M.options = vim.deepcopy(defaults)

--- Reviewed plans, keyed by the directory they belong to.
---@type table<string, table>
local plans = {}

--- Every plan file this session has asked for and has not removed yet, keyed by path.
--- A reviewed plan is in `plans` as well; one still being written, or one whose
--- command ended with nothing worth keeping, is only here.
---@type table<string, boolean>
local artifacts = {}

--- Orders callbacks from overlapping plans; the older one discards its result.
---@type table<string, integer>
local generation = {}

--- Directories with a plan in flight, holding the generation that claimed them.
---@type table<string, integer>
local planning = {}

--- Directories with an `init` in flight.
---@type table<string, boolean>
local initializing = {}

--- Directories with an apply in flight.
--- At most one of planning, applying and initializing is set for a directory.
---@type table<string, boolean>
local applying = {}

--- What the next subprocess will authenticate as, recorded with a plan and compared before apply.
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

--- Asks STS who the current credentials are. Never cached — a cache would answer for earlier ones.
---@param callback fun(identity: table|nil, err: string|nil)
local function aws_identity(callback)
  if not M.options.strict_aws_identity then
    callback(nil)
    return
  end

  -- No `aws` at all most likely means this is not an AWS project, so it passes without comment.
  if vim.fn.executable("aws") ~= 1 then
    callback(nil)
    return
  end

  -- Callers claim the directory before asking, so a spawn that raises here would leak
  -- the claim just as one in `run` would. An unanswerable question is an ordinary
  -- unknown identity: plan says so and continues, apply refuses on the difference.
  local started, err = pcall(
    vim.system,
    { "aws", "sts", "get-caller-identity", "--output", "json" },
    { text = true },
    function(result)
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
    end
  )

  if not started then
    callback(nil, ("could not run aws: %s"):format(err))
  end
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
  -- Set only under strict_aws_identity, where nil on one side is itself a difference.
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

---Removes a file, telling "already gone" apart from "could not be removed".
---`vim.uv.fs_unlink` returns nil, err instead of raising, so a pcall around it
---reports success for a file that is still there.
---@param path string
---@return boolean removed, string|nil err
local function unlink_checked(path)
  local ok, err = vim.uv.fs_unlink(path)
  if ok then
    return true
  end
  -- Already gone is the outcome this was for.
  if not vim.uv.fs_stat(path) then
    return true
  end
  return false, err or "unlink failed"
end

---Removes a plan file and stops tracking it, saying so when it stays behind.
---@param path string
local function drop_artifact(path)
  local removed, err = unlink_checked(path)
  if removed then
    artifacts[path] = nil
    return
  end

  -- Left in the table on purpose: the file is still on disk and still ours, so
  -- leaving Neovim tries once more.
  vim.notify(
    ("A plan file could not be removed (%s). It can quote variable values:\n%s"):format(err, path),
    vim.log.levels.WARN
  )
end

---Drops a saved plan and removes its file.
---@param dir string
local function discard_plan(dir)
  local saved = plans[dir]
  if saved then
    plans[dir] = nil
    drop_artifact(saved.path)
  end
end

---Terragrunt owns a directory when terragrunt.hcl sits in it; `terraform` there ignores it.
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

---The nearest directory above the buffer holding .tf or terragrunt files.
---@return string|nil
local function root_dir()
  local buf = vim.api.nvim_buf_get_name(0)
  local start = buf ~= "" and vim.fs.dirname(buf) or vim.fn.getcwd()

  -- Must list what binary_for lists, or a stack-only directory looks like no project at all.
  local found = vim.fs.find(function(name)
    return name:match("%.tf$") or name == "terragrunt.hcl" or name == "terragrunt.stack.hcl"
  end, { path = start, upward = true, type = "file" })[1]

  return found and vim.fs.dirname(found) or nil
end

---Somewhere to put a plan: the validated private runtime directory, or nowhere.
---@return string|nil path, string|nil err
local function plan_path()
  local dir, err = require("terraform.runtime").secure_dir("terraform.nvim")
  if not dir then
    return nil,
      ("%s\nA plan file can quote sensitive values, so this plugin will not fall back outside $XDG_RUNTIME_DIR."):format(
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

  -- A plan can quote variable values, so it is not persisted either.
  vim.bo[buf].undofile = false
  vim.bo[buf].swapfile = false
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "terraform-plan"

  -- Focus stays put: these open from an async callback, into whatever you are editing by then.
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

---Opens the output window, returning failure instead of raising it inside an async callback.
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

---Assembles the argument list: global options, subcommand, our flags, user flags, positional.
---@param command string the subcommand, which also names its option list
---@param flags string[] our own flags
---@param positional? string[] arguments that must come last
---@return string[]
local function argv(command, flags, positional)
  local out = {}
  vim.list_extend(out, M.options.global_args or {})
  table.insert(out, command)
  vim.list_extend(out, flags)
  vim.list_extend(out, M.options[command .. "_args"] or {})
  vim.list_extend(out, positional or {})
  return out
end

---The SHA-256 of a file's contents.
---@param path string
---@return string|nil digest, string|nil err
local function file_sha256(path)
  local fd, open_err = vim.uv.fs_open(path, "r", tonumber("400", 8))
  if not fd then
    return nil, open_err or "open failed"
  end

  -- Read to the end rather than to a size measured beforehand: a read returning fewer
  -- bytes than asked for would otherwise be hashed as though it were the whole file.
  local chunks, offset = {}, 0
  while true do
    local chunk, read_err = vim.uv.fs_read(fd, 1024 * 1024, offset)
    if chunk == nil then
      vim.uv.fs_close(fd)
      return nil, read_err or "read failed"
    end
    if #chunk == 0 then
      break
    end
    table.insert(chunks, chunk)
    offset = offset + #chunk
  end

  local closed, close_err = vim.uv.fs_close(fd)
  if not closed then
    return nil, close_err or "close failed"
  end

  return vim.fn.sha256(table.concat(chunks))
end

---The option a token sets: `-out=x` and `-out` both name `-out`.
---@param arg string
---@return string
local function option_name(arg)
  return arg:match("^([^=]+)") or arg
end

--- Options the runner sets and depends on the value of; see :help devops-nvim-terraform-arguments.
local reserved = {
  init = { ["-input"] = true },
  plan = { ["-out"] = true, ["-destroy"] = true, ["-detailed-exitcode"] = true, ["-input"] = true },
  apply = { ["-input"] = true },
}

---Drops `-chdir`, which would move terraform away from the directory all bookkeeping is keyed by.
---@param args string[]|nil
---@return string[]
local function sanitize_global_args(args)
  local kept = {}
  for _, arg in ipairs(args or {}) do
    if option_name(arg) == "-chdir" then
      vim.notify(
        "terraform.nvim: -chdir was ignored in global_args. The runner owns the working directory — "
          .. "terraform running elsewhere would leave the saved plan and its lifecycle pointing at a directory nothing ran in.",
        vim.log.levels.ERROR
      )
    else
      table.insert(kept, arg)
    end
  end
  return kept
end

---Drops the options this runner owns from a per-command list.
---@param command string
---@param args string[]|nil
---@return string[]
local function sanitize_command_args(command, args)
  local owned = reserved[command] or {}
  local kept = {}
  for _, arg in ipairs(args or {}) do
    local name = option_name(arg)
    if owned[name] then
      vim.notify(
        ("terraform.nvim: %s was ignored in %s_args — the runner sets it and relies on its value."):format(
          name,
          command
        ),
        vim.log.levels.ERROR
      )
    else
      table.insert(kept, arg)
    end
  end
  return kept
end

---@param command string the subcommand being run, for the message only
---@param args string[]
---@param dir string
---@param on_done fun(code: integer, lines: string[])
---@param binary? string an executable resolved earlier; re-resolved from dir when absent
---@return vim.SystemObj|nil handle nil when nothing was started
local function run(command, args, dir, on_done, binary)
  local name = binary or binary_for(dir)
  -- exepath() is idempotent for an absolute path, so a bare name and a pinned path both work.
  local bin = vim.fn.executable(name) == 1 and vim.fn.exepath(name) or ""

  if bin == "" then
    vim.notify(("`%s` not found on PATH"):format(name), vim.log.levels.ERROR)
    return nil
  end

  local cmd = { bin }
  vim.list_extend(cmd, args)

  vim.notify(("Running %s %s…"):format(vim.fs.basename(bin), command), vim.log.levels.INFO)

  -- vim.system raises before it starts anything when the directory has been removed
  -- (ENOENT) or is no longer a directory (ENOTDIR). Raising past the caller would skip
  -- the claim it releases on `nil`, leaving the directory blocked for the session.
  local started, process = pcall(vim.system, cmd, { cwd = dir, text = true }, function(result)
    local out = (result.stdout or "") .. (result.stderr or "")
    local lines = vim.split(out:gsub("%s+$", ""), "\n", { trimempty = false })
    vim.schedule(function()
      on_done(result.code, lines)
    end)
  end)

  if not started then
    vim.notify(
      ("Could not start %s %s in %s: %s"):format(vim.fs.basename(bin), command, dir, process),
      vim.log.levels.ERROR
    )
    return nil
  end

  return process
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

  if initializing[dir] then
    vim.notify("An init is running in this directory — wait for it before planning", vim.log.levels.WARN)
    return
  end

  local path, err = plan_path()
  if not path then
    vim.notify(err, vim.log.levels.ERROR)
    return
  end

  -- Resolved once and recorded, so apply cannot pick up a different binary later.
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

  -- Both claimed before the first await, or an apply could slip through it.
  generation[dir] = (generation[dir] or 0) + 1
  local mine = generation[dir]
  planning[dir] = mine

  -- Asking for a new plan supersedes the reviewed one now, not when this one succeeds.
  discard_plan(dir)

  aws_identity(function(identity, identity_err)
    if generation[dir] ~= mine then
      finish_planning(dir, mine)
      return
    end

    -- Said out loud: with the option on, a plan without an identity lacks the protection asked for.
    if identity_err then
      vim.notify(
        ("Could not determine the AWS identity, so this plan will not be bound to one:\n%s"):format(identity_err),
        vim.log.levels.WARN
      )
    end

    local context = aws_context(identity)

    -- Tracked from before the process exists, because the file appears while it runs
    -- and a session that ends there would otherwise leave nobody knowing about it.
    artifacts[path] = true

    local process = run("plan", args, dir, function(code, lines)
      if generation[dir] ~= mine then
        -- Superseded, so this file must not become the plan apply uses.
        drop_artifact(path)
        finish_planning(dir, mine)
        return
      end

      -- Released here, not per branch, so a branch added later cannot leave the directory claimed.
      finish_planning(dir, mine)

      ---Removes the plan file and says why nothing was kept.
      ---@param message string
      local function abandon(message)
        drop_artifact(path)
        vim.notify(message, vim.log.levels.ERROR)
      end

      -- -detailed-exitcode: 0 no changes, 1 error, 2 changes present.
      local before
      if code == 2 then
        -- terraform writes the plan under the ambient umask; measured 0644, and a plan quotes values.
        local protected, chmod_err = vim.uv.fs_chmod(path, tonumber("600", 8))
        if not protected then
          return abandon(
            ("The plan could not be protected (%s), so it was discarded rather than left readable.\nNothing to apply."):format(
              chmod_err or "chmod failed"
            )
          )
        end

        local digest_err
        before, digest_err = file_sha256(path)
        if not before then
          return abandon(
            ("The plan could not be read back (%s), so it was discarded.\nNothing to apply."):format(digest_err)
          )
        end
      end

      -- Showing the plan is the review step, so a window that will not open fails closed.
      if not try_show(lines, (" %s plan%s "):format(vim.fs.basename(dir), destroy and " -destroy" or "")) then
        return abandon(
          "The plan ran, but it could not be shown, so it was discarded unread.\nNothing to apply — run :TerraformPlan again."
        )
      end

      if code == 0 then
        drop_artifact(path)
        vim.notify("No changes — infrastructure matches the configuration", vim.log.levels.INFO)
      elseif code == 2 then
        -- The digest recorded has to be one that survived the review.
        local after, digest_err = file_sha256(path)
        if not after then
          return abandon(
            ("The plan could not be read back after review (%s), so it was discarded.\nNothing to apply."):format(
              digest_err
            )
          )
        end
        if after ~= before then
          return abandon(
            "The plan file changed while it was being reviewed, so it was discarded.\nRun :TerraformPlan again."
          )
        end

        plans[dir] = { path = path, destroy = destroy, context = context, binary = binary, sha256 = after }
        vim.notify(
          ("Plan saved%s. Review it, then :TerraformApply%s"):format(
            identity and (" as " .. (identity.arn or identity.account)) or "",
            destroy and "  (this plan DESTROYS)" or ""
          ),
          destroy and vim.log.levels.WARN or vim.log.levels.INFO
        )
      else
        drop_artifact(path)
        vim.notify("Plan failed", vim.log.levels.ERROR)
      end
    end, binary)

    -- No process means no callback to release the claim, and no file either.
    if not process then
      drop_artifact(path)
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

  -- Without this a second apply finds the same plan file and hands it to a second process.
  if applying[dir] then
    vim.notify("An apply is already running for this directory", vim.log.levels.WARN)
    return
  end

  if planning[dir] then
    vim.notify(
      "A new plan is still running for this directory — wait for it, read it, then apply",
      vim.log.levels.WARN
    )
    return
  end

  -- Unreachable while init discards the plan first, but the refusal names the reason.
  if initializing[dir] then
    vim.notify("An init is running in this directory — it discarded the reviewed plan", vim.log.levels.WARN)
    return
  end

  local saved = plans[dir]
  if not saved or not vim.uv.fs_stat(saved.path) then
    plans[dir] = nil
    vim.notify("No reviewed plan for this directory — run :TerraformPlan first", vim.log.levels.WARN)
    return
  end

  -- Before the identity lookup and the prompt: nothing to approve if the artefact is already invalid.
  local digest, digest_err = file_sha256(saved.path)
  if not digest then
    discard_plan(dir)
    vim.notify(
      ("Refusing to apply: the reviewed plan could not be read (%s).\nRun :TerraformPlan again."):format(digest_err),
      vim.log.levels.ERROR
    )
    return
  end

  if digest ~= saved.sha256 then
    discard_plan(dir)
    vim.notify(
      "Refusing to apply: the reviewed plan file has changed on disk since it was read.\nRun :TerraformPlan again.",
      vim.log.levels.ERROR
    )
    return
  end

  -- Applying a terraform plan with tofu, or bypassing terragrunt, is not the reviewed operation.
  if vim.fn.executable(saved.binary or "") ~= 1 then
    vim.notify(
      ("The executable that created this plan is no longer available (%s).\nRun :TerraformPlan again."):format(
        saved.binary or "unknown"
      ),
      vim.log.levels.ERROR
    )
    return
  end

  -- Claimed before the identity lookup: leaving the directory free across that await reopens the race.
  applying[dir] = true
  local function release()
    applying[dir] = nil
  end

  aws_identity(function(identity, identity_err)
    if identity_err then
      vim.notify(("Could not determine the AWS identity:\n%s"):format(identity_err), vim.log.levels.WARN)
    end

    -- The plan fixes what terraform does, not who it does it as.
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

    -- The file is terraform's approval; this prompt is the human's, and destroy is typed out.
    local want = saved.destroy and "destroy" or "yes"
    local answer = vim.fn.input({
      prompt = ("Apply this plan to %s? Type %q to confirm: "):format(vim.fs.basename(dir), want),
    })

    if answer ~= want then
      vim.notify("Cancelled", vim.log.levels.INFO)
      return release()
    end

    -- The first digest was taken before the identity lookup and the prompt, which is
    -- where the time goes. This one covers that window, so what terraform is handed is
    -- what was reviewed rather than what was reviewed some seconds ago.
    local final, final_err = file_sha256(saved.path)
    if not final then
      release()
      discard_plan(dir)
      vim.notify(
        ("Refusing to apply: the reviewed plan could not be read after confirmation (%s).\nRun :TerraformPlan again."):format(
          final_err
        ),
        vim.log.levels.ERROR
      )
      return
    end

    if final ~= saved.sha256 then
      release()
      discard_plan(dir)
      vim.notify(
        "Refusing to apply: the reviewed plan changed while identity verification or confirmation was in progress.\nRun :TerraformPlan again.",
        vim.log.levels.ERROR
      )
      return
    end

    local process = run(
      "apply",
      argv("apply", { "-no-color", "-input=false" }, { saved.path }),
      dir,
      function(code, lines)
        release()

        -- Spent whatever happened: terraform refuses to reuse a plan file.
        discard_plan(dir)

        try_show(lines, (" %s apply "):format(vim.fs.basename(dir)))
        if code == 0 then
          vim.notify("Applied", vim.log.levels.INFO)
        else
          vim.notify("Apply failed", vim.log.levels.ERROR)
        end
      end,
      saved.binary
    )

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

  -- init rewrites `.terraform/` — providers, modules, backend — under whatever is reading it.
  if applying[dir] then
    vim.notify("An apply is running in this directory — init would rewrite .terraform under it", vim.log.levels.WARN)
    return
  end

  if planning[dir] then
    vim.notify("A plan is running in this directory — init would rewrite .terraform under it", vim.log.levels.WARN)
    return
  end

  if initializing[dir] then
    vim.notify("An init is already running in this directory", vim.log.levels.WARN)
    return
  end

  initializing[dir] = true
  local function release()
    initializing[dir] = nil
  end

  -- A plan computed before this init describes providers and modules it may replace.
  discard_plan(dir)

  local process = run("init", argv("init", { "-no-color", "-input=false" }), dir, function(code, lines)
    -- First: nothing below decides whether the directory stays claimed.
    release()

    try_show(lines, (" %s init "):format(vim.fs.basename(dir)))
    vim.notify(code == 0 and "Initialised" or "Init failed", code == 0 and vim.log.levels.INFO or vim.log.levels.ERROR)
  end)

  if not process then
    release()
  end
end

function M.validate()
  local dir = root_dir()
  if not dir then
    vim.notify("No .tf or terragrunt.hcl found above this buffer", vim.log.levels.WARN)
    return
  end

  -- The only refusal validate gets: init replaces the provider schemas it reads.
  if initializing[dir] then
    vim.notify("An init is running in this directory — wait for it before validating", vim.log.levels.WARN)
    return
  end

  run("validate", argv("validate", { "-no-color" }), dir, function(code, lines)
    if code == 0 then
      vim.notify("Configuration is valid", vim.log.levels.INFO)
    else
      try_show(lines, (" %s validate "):format(vim.fs.basename(dir)))
    end
  end)
end

---Discards every reviewed plan, except where an apply is using one.
function M.discard()
  local count, held = 0, 0
  for dir, _ in pairs(vim.deepcopy(plans)) do
    if applying[dir] then
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

  -- Removed rather than silently ignored: `args` broke apply by landing after the plan file.
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

  -- Filtered at configuration time, so a rejected option is reported once rather than per command.
  M.options.global_args = sanitize_global_args(M.options.global_args)
  for _, command in ipairs({ "init", "validate", "plan", "apply" }) do
    local key = command .. "_args"
    M.options[key] = sanitize_command_args(command, M.options[key])
  end

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

  -- Reviewed plans are not the only files on disk: one whose command is still
  -- running is written by that command, not by us, and is worth removing too. What
  -- a subprocess creates after this point outlives the session; nothing here can
  -- promise otherwise.
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("terraform_nvim_cleanup", { clear = true }),
    callback = function()
      for _, path in ipairs(vim.tbl_keys(artifacts)) do
        drop_artifact(path)
      end
    end,
  })

  if M.options.keymaps then
    vim.keymap.set("n", "<leader>ti", M.init, { desc = "Terraform init" })
    vim.keymap.set("n", "<leader>tv", M.validate, { desc = "Terraform validate" })
    vim.keymap.set("n", "<leader>tp", M.plan, { desc = "Terraform plan" })
    vim.keymap.set("n", "<leader>ta", M.apply, { desc = "Apply the reviewed plan" })
    vim.keymap.set("n", "<leader>td", M.discard, { desc = "Discard the reviewed plan" })
    -- Destroy has no mapping on purpose; it is typed out, and still only produces a plan.
  end
end

return M
