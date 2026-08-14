-- The last screen before a playbook touches anything: the decisions in the words
-- §10 insists on, then the argument vector exactly as the process will get it.
--
-- Nothing is decided here, and the prepared array is handed in rather than
-- built, so the thing shown and the thing started cannot disagree (§15.2).
-- There is no shell rendering (§15.3): a line joined with spaces misrepresents
-- any argument holding a space or a quote, and that is the line people copy.
-- And nothing says a value will win — playbook keywords can outrank a
-- command-line option (§10.2), so an option nobody chose reads `inherited`.

local text = require("chroma-ansible.text")

local M = {}

--- Where every value starts, so that the labels form a column and two previews
--- of one plan read identically.
local COLUMN = "%-22s %s"

--- What the target row says when there is no snapshot. Not a summary of why:
--- §16 keeps the reason in the failure the operator already saw.
local NOT_REPORTED = "not reported"

--- And on a repeat that did not ask again (§14.5): the previous run's number
--- is never repeated as though it were still true.
local NOT_REFRESHED = "not refreshed"

--- The only environment names this screen will show, and an allowlist rather
--- than a prefix match on purpose: `AWS_*` prints `AWS_SECRET_ACCESS_KEY`.
---
--- §3.5 makes the environment exact, which is a guarantee about the run and not
--- an undertaking to display it — an environment holds credentials, tokens and
--- whatever else the operator's shell put there. These four are the ones that
--- change what an invocation means without changing a single argument, which is
--- the whole reason the freeze exists. `PATH` is not among them: `argv[0]` is
--- absolute and already says which program this is.
local CONTEXT = { "ANSIBLE_CONFIG", "AWS_PROFILE", "AWS_REGION", "AWS_DEFAULT_REGION" }

---@class chroma_ansible.Snapshot
---@field targets string[]|nil the hosts Ansible resolved during this planning
---@field refreshed boolean|nil false when this is a repeat that did not re-ask

--- Every value stays one visible line: a newline would draw a second line
--- reading like the next argument. The gate is shown the same way (§6.4).
local visible = text.visible

---Adds one labelled row.
---@param lines string[]
---@param label string
---@param value string
local function row(lines, label, value)
  table.insert(lines, COLUMN:format(label, visible(value)))
end

---Adds a row per value, labelling only the first: a second source appended to
---the first with a comma would read as one path with a comma in it.
---@param lines string[]
---@param label string
---@param values string[]
---@param when_empty string
local function rows(lines, label, values, when_empty)
  if #values == 0 then
    return row(lines, label, when_empty)
  end
  for index, value in ipairs(values) do
    row(lines, index == 1 and label or "", value)
  end
end

---What the target row shows.
---@param snapshot chroma_ansible.Snapshot|nil
---@return string
local function targets(snapshot)
  if not snapshot then
    return NOT_REPORTED
  end
  if snapshot.refreshed == false then
    return NOT_REFRESHED
  end
  if not snapshot.targets then
    return NOT_REPORTED
  end

  -- A count, not the names (§7.5): an inventory of thirty thousand hosts must
  -- not become thirty thousand lines in a dialog. The names have their own
  -- screen (§9.4).
  return ("%d host%s"):format(#snapshot.targets, #snapshot.targets == 1 and "" or "s")
end

---The preview of one prepared run.
---
---@param run chroma_ansible.Run
---@param command string[] the prepared array, from `argv.execution`
---@param snapshot chroma_ansible.Snapshot|nil what `--list-hosts` last reported
---@return string[] lines
function M.render(run, command, snapshot)
  local plan = run.plan
  local lines = { "ANSIBLE EXECUTION", "" }

  row(lines, "Working directory", run.directory or "")
  rows(lines, "Playbook", plan.playbooks, "none")
  -- §5.3: no `-i` means Ansible's own configuration decides, and the preview
  -- says which of the two this is rather than leaving the line out.
  rows(lines, "Inventory", plan.inventory, "from Ansible configuration")
  rows(lines, "Tags", plan.tags, "no CLI filter")
  row(lines, "Limit", plan.limit or "no CLI limit")
  row(lines, "CLI remote-user", plan.remote_user or "inherited")
  row(lines, "CLI become override", plan.become and "enabled" or "inherited")
  row(lines, "Ask become password", plan.ask_become_pass and "yes (-K)" or "no CLI flag")
  rows(lines, "Vault", plan.vault, "inherited")
  row(lines, "Mode", plan.check and "check (--check)" or "run")
  -- Shown even when off, like every inherited row. §12.2's warning is attached
  -- to the value, because this is the screen where somebody decides.
  row(lines, "Diff", plan.diff and "on — may print sensitive file contents" or "off")
  row(lines, "Targets reported now", targets(snapshot))

  -- Said whether or not any of the four are set, because the sentence people
  -- need is that the run and the inspections behind that host count happened in
  -- one environment.
  row(lines, "Environment", "frozen when this run started")
  for _, name in ipairs(CONTEXT) do
    local value = (run.environment or {})[name]
    if value and value ~= "" then
      row(lines, ("  %s"):format(name), value)
    end
  end

  vim.list_extend(lines, { "", "argv", "" })

  -- Indices right-aligned so the arguments themselves form a column.
  local width = #tostring(#command - 1)
  for index, word in ipairs(command) do
    table.insert(lines, ("  [%" .. width .. "d]  %s"):format(index - 1, visible(word)))
  end

  return lines
end

---Asks whether to run what the preview showed. §15.4: only an explicit
---affirmative starts the process, and `confirm` answers 0 for a dismissed
---dialog, which is neither choice and therefore also no.
---@param lines string[] the preview, as rendered above
---@return boolean
function M.confirm(lines)
  return vim.fn.confirm(("%s\n\nRun?"):format(table.concat(lines, "\n")), "&No\n&Yes", 1) == 2
end

return M
