-- aws.nvim — switch the AWS profile and region for this Neovim session.

local M = {}

local defaults = {
  keymaps = false,
}

M.options = vim.deepcopy(defaults)

--- The environment Neovim was started with, captured once at setup.
---@type table<string, string|nil>
local initial = {}

--- Credentials that take precedence over AWS_PROFILE.
local OVERRIDING = {
  "AWS_ACCESS_KEY_ID",
  "AWS_SECRET_ACCESS_KEY",
  "AWS_SESSION_TOKEN",
  "AWS_WEB_IDENTITY_TOKEN_FILE",
  "AWS_ROLE_ARN",
}

---@return string[] names of overriding variables that are set
local function overriding_credentials()
  local found = {}
  for _, name in ipairs(OVERRIDING) do
    if vim.env[name] and vim.env[name] ~= "" then
      table.insert(found, name)
    end
  end
  return found
end

---@param cmd string[]
---@return string[]|nil lines, string|nil err
local function capture(cmd)
  if vim.fn.executable("aws") ~= 1 then
    return nil, "`aws` not found on PATH"
  end

  local result = vim.system(cmd, { text = true }):wait()
  if result.code ~= 0 then
    return nil, (result.stderr or ""):gsub("%s+$", "")
  end

  return vim.split((result.stdout or ""):gsub("%s+$", ""), "\n", { trimempty = true })
end

---What the next subprocess will see.
---@return string profile, string region
local function current()
  return vim.env.AWS_PROFILE or "(default)", vim.env.AWS_REGION or vim.env.AWS_DEFAULT_REGION or "(unset)"
end

function M.status()
  local profile, region = current()
  local message = ("AWS profile: %s   region: %s"):format(profile, region)

  local overriding = overriding_credentials()
  if #overriding > 0 then
    vim.notify(
      ("%s\n%s set in the environment — these take precedence over AWS_PROFILE, so the profile above is not what will be used."):format(
        message,
        table.concat(overriding, ", ")
      ),
      vim.log.levels.WARN
    )
    return
  end

  vim.notify(message, vim.log.levels.INFO)
end

---Picks a profile from those the CLI knows about.
function M.pick_profile()
  local profiles, err = capture({ "aws", "configure", "list-profiles" })
  if not profiles then
    vim.notify(err, vim.log.levels.ERROR)
    return
  end

  if #profiles == 0 then
    vim.notify("No AWS profiles configured — run `aws configure` or `aws sso login`", vim.log.levels.WARN)
    return
  end

  vim.ui.select(profiles, { prompt = "AWS profile" }, function(choice)
    if not choice then
      return
    end

    vim.env.AWS_PROFILE = choice

    -- Cleared first: a profile that carries no region should not inherit the last one.
    vim.env.AWS_REGION = nil
    vim.env.AWS_DEFAULT_REGION = nil

    local region = capture({ "aws", "configure", "get", "region", "--profile", choice })
    if region and region[1] and region[1] ~= "" then
      vim.env.AWS_REGION = region[1]
      vim.env.AWS_DEFAULT_REGION = region[1]
    end

    M.status()
  end)
end

---Picks a region, asking the account when it can and the user when it cannot.
function M.pick_region()
  local regions = capture({
    "aws",
    "ec2",
    "describe-regions",
    "--all-regions",
    "--query",
    "Regions[].RegionName",
    "--output",
    "text",
  })

  local list = {}
  if regions and regions[1] then
    -- `--output text` returns one tab-separated line.
    for name in regions[1]:gmatch("[%w%-]+") do
      table.insert(list, name)
    end
    table.sort(list)
  end

  if #list == 0 then
    -- No credentials, no network, or no permission. Typing is better than
    -- choosing from a list this plugin would have to keep up to date.
    vim.ui.input({ prompt = "AWS region: ", default = vim.env.AWS_REGION or "" }, function(value)
      if value and value ~= "" then
        vim.env.AWS_REGION = value
        vim.env.AWS_DEFAULT_REGION = value
        M.status()
      end
    end)
    return
  end

  vim.ui.select(list, { prompt = "AWS region" }, function(choice)
    if not choice then
      return
    end
    vim.env.AWS_REGION = choice
    vim.env.AWS_DEFAULT_REGION = choice
    M.status()
  end)
end

---Restores the environment Neovim started with.
function M.clear()
  vim.env.AWS_PROFILE = initial.AWS_PROFILE
  vim.env.AWS_REGION = initial.AWS_REGION
  vim.env.AWS_DEFAULT_REGION = initial.AWS_DEFAULT_REGION

  local profile, region = current()
  vim.notify(
    ("Restored the starting environment — profile: %s   region: %s"):format(profile, region),
    vim.log.levels.INFO
  )
end

---Confirms which account the current credentials actually resolve to.
function M.whoami()
  local out, err = capture({ "aws", "sts", "get-caller-identity", "--output", "text" })
  if not out then
    vim.notify(("Not authenticated: %s"):format(err), vim.log.levels.ERROR)
    return
  end
  vim.notify(("Caller identity: %s"):format(table.concat(out, " ")), vim.log.levels.INFO)
end

--- Internals exposed for the test suite only.
M._test = {
  overriding_credentials = overriding_credentials,
}

---@param opts table|nil
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})

  for _, name in ipairs({ "AWS_PROFILE", "AWS_REGION", "AWS_DEFAULT_REGION" }) do
    initial[name] = vim.env[name]
  end

  local commands = {
    AwsProfile = M.pick_profile,
    AwsRegion = M.pick_region,
    AwsStatus = M.status,
    AwsClear = M.clear,
    AwsWhoami = M.whoami,
  }

  for name, fn in pairs(commands) do
    vim.api.nvim_create_user_command(name, fn, { desc = name })
  end

  if M.options.keymaps then
    vim.keymap.set("n", "<leader>Ap", M.pick_profile, { desc = "AWS profile" })
    vim.keymap.set("n", "<leader>Ar", M.pick_region, { desc = "AWS region" })
    vim.keymap.set("n", "<leader>As", M.status, { desc = "AWS status" })
    vim.keymap.set("n", "<leader>Aw", M.whoami, { desc = "AWS caller identity" })
    vim.keymap.set("n", "<leader>Ac", M.clear, { desc = "Clear AWS profile and region" })
  end
end

return M
