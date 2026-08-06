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
-- needs -auto-approve, and more importantly it can never apply something other
-- than what was on screen. Drift between reading and applying is impossible.
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

local defaults = {
  keymaps = false,
  ---Extra arguments appended to every command.
  args = {},
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

--- What the next subprocess will authenticate as.
---
--- Recorded with every plan and compared before apply. The AWS module sets
--- these on the Neovim process, so switching profile between reading a plan and
--- applying it would run the apply against a different account while terraform
--- happily performs the operations the plan described.
---
--- This compares environment, not identity: it does not ask STS who the
--- credentials actually resolve to, because that is a network round trip on
--- every plan. `:AwsWhoami` answers that question when it matters.
---@return table
local function aws_context()
  return {
    profile = vim.env.AWS_PROFILE,
    region = vim.env.AWS_REGION or vim.env.AWS_DEFAULT_REGION,
  }
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
  return nil
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
  local dir = vim.env.XDG_RUNTIME_DIR
  if not dir or not vim.uv.fs_stat(dir) then
    return nil,
      "XDG_RUNTIME_DIR is not set. A plan file can contain sensitive values and "
        .. "this plugin will not write one to persistent storage."
  end
  return ("%s/terraform.nvim.%d.%d.tfplan"):format(dir, vim.uv.os_getpid(), vim.uv.hrtime())
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

  vim.cmd("botright split")
  vim.api.nvim_win_set_buf(0, buf)
  vim.api.nvim_win_set_height(0, math.min(#lines + 1, math.floor(vim.o.lines * 0.6)))
  vim.wo.winbar = title

  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = buf, nowait = true, desc = "Close" })
end

---@param args string[]
---@param dir string
---@param on_done fun(code: integer, lines: string[])
local function run(args, dir, on_done)
  local bin = binary_for(dir)

  if vim.fn.executable(bin) ~= 1 then
    vim.notify(("`%s` not found on PATH"):format(bin), vim.log.levels.ERROR)
    return
  end

  local cmd = { bin }
  vim.list_extend(cmd, args)
  vim.list_extend(cmd, M.options.args)

  vim.notify(("Running %s %s…"):format(bin, args[1]), vim.log.levels.INFO)

  vim.system(cmd, { cwd = dir, text = true }, function(result)
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

  local path, err = plan_path()
  if not path then
    vim.notify(err, vim.log.levels.ERROR)
    return
  end

  local args = { "plan", "-no-color", "-input=false", "-detailed-exitcode", "-out=" .. path }
  if destroy then
    table.insert(args, 2, "-destroy")
  end

  -- Claim this generation before starting. Any plan already running for this
  -- directory becomes stale the moment a newer one is asked for.
  generation[dir] = (generation[dir] or 0) + 1
  local mine = generation[dir]
  local context = aws_context()
  local binary = binary_for(dir)

  run(args, dir, function(code, lines)
    if generation[dir] ~= mine then
      -- A newer plan was started while this one was running. Its output would
      -- be misleading and its file must not become the plan that apply uses.
      pcall(vim.uv.fs_unlink, path)
      return
    end

    show(lines, (" %s plan%s "):format(vim.fs.basename(dir), destroy and " -destroy" or ""))

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

      -- Removes the file of the plan being replaced. Without this each
      -- superseded plan leaked a file into XDG_RUNTIME_DIR until logout.
      discard_plan(dir)

      plans[dir] = { path = path, destroy = destroy, context = context, binary = binary }
      vim.notify(
        ("Plan saved. Review it, then :TerraformApply%s"):format(destroy and "  (this plan DESTROYS)" or ""),
        destroy and vim.log.levels.WARN or vim.log.levels.INFO
      )
    else
      pcall(vim.uv.fs_unlink, path)
      vim.notify("Plan failed", vim.log.levels.ERROR)
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

  local saved = plans[dir]
  if not saved or not vim.uv.fs_stat(saved.path) then
    plans[dir] = nil
    vim.notify("No reviewed plan for this directory — run :TerraformPlan first", vim.log.levels.WARN)
    return
  end

  -- The plan file fixes what terraform will do. It does not fix who it will
  -- do it as: credentials come from the environment, which the AWS module can
  -- change between reading a plan and applying it. Terraform would carry out
  -- the reviewed operations against whatever account is configured now.
  local drift = context_differs(saved.context or {}, aws_context())
  if drift then
    vim.notify(
      ("Refusing to apply: %s since this plan was made.\nRun :TerraformPlan again under the current credentials."):format(
        drift
      ),
      vim.log.levels.ERROR
    )
    return
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
    return
  end

  run({ "apply", "-no-color", "-input=false", saved.path }, dir, function(code, lines)
    -- Spent, whatever happened: terraform refuses to reuse a plan file, and
    -- keeping it would only invite applying a stale one.
    discard_plan(dir)

    show(lines, (" %s apply "):format(vim.fs.basename(dir)))
    if code == 0 then
      vim.notify("Applied", vim.log.levels.INFO)
    else
      vim.notify("Apply failed", vim.log.levels.ERROR)
    end
  end)
end

function M.init()
  local dir = root_dir()
  if not dir then
    vim.notify("No .tf or terragrunt.hcl found above this buffer", vim.log.levels.WARN)
    return
  end

  run({ "init", "-no-color", "-input=false" }, dir, function(code, lines)
    show(lines, (" %s init "):format(vim.fs.basename(dir)))
    vim.notify(code == 0 and "Initialised" or "Init failed", code == 0 and vim.log.levels.INFO or vim.log.levels.ERROR)
  end)
end

function M.validate()
  local dir = root_dir()
  if not dir then
    vim.notify("No .tf or terragrunt.hcl found above this buffer", vim.log.levels.WARN)
    return
  end

  run({ "validate", "-no-color" }, dir, function(code, lines)
    if code == 0 then
      vim.notify("Configuration is valid", vim.log.levels.INFO)
    else
      show(lines, (" %s validate "):format(vim.fs.basename(dir)))
    end
  end)
end

---Discards any reviewed plan without applying it.
function M.discard()
  local count = 0
  for dir, _ in pairs(vim.deepcopy(plans)) do
    discard_plan(dir)
    count = count + 1
  end
  vim.notify(("Discarded %d saved plan(s)"):format(count), vim.log.levels.INFO)
end

--- Internals exposed for the test suite only.
M._test = {
  context_differs = context_differs,
}

---@param opts table|nil
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})

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
