-- What is about to run, and the question asked about it.
--
-- The last screen before a playbook touches anything. It shows the decisions in
-- the words §10 insists on, and then the argument vector exactly as it will be
-- handed to the process. The rules are `doc/chroma-ansible-design.md`,
-- section 15.
--
-- **Nothing is decided here.** This module is handed what the earlier steps
-- produced and represents it. In particular it is handed the prepared array
-- rather than building one: the preview and the executor read the same array,
-- which is the only way the thing shown and the thing started cannot disagree
-- (§15.2).
--
-- **There is no shell rendering** (§15.3). No line joins the arguments into
-- something that looks like a command line. The array never passes through a
-- shell, and a rendering joined with spaces misrepresents any argument holding a
-- space, a quote or a semicolon — and that is the line people copy.
--
-- **Nothing here says a value will win.** `CLI remote-user override` rather than
-- `Remote user`, because command-line options do not sit at the top of Ansible's
-- precedence in every case: playbook keywords and variables can outrank them
-- (§10, §10.2). And an option nobody chose reads `inherited`, never `no` — the
-- absence of `-b` is not become being off.
--
-- This is a second implementation of the same policy as `chroma.tasks.preview`
-- rather than a call into it, for the reason §15.5 gives: the own modules are
-- self-contained so that any of them can be lifted into its own repository
-- without edits.

local M = {}

--- Where every value starts, so that the labels form a column and two previews
--- of one plan read identically.
local COLUMN = "%-22s %s"

--- What the target row says when there is no snapshot to show. Not a summary of
--- why: §16 keeps the reason out of the preview and in the failure the operator
--- already saw.
local NOT_REPORTED = "not reported"

--- And what it says on a repeat that did not ask again (§14.5). The previous
--- run's number is never repeated as though it were still true.
local NOT_REFRESHED = "not refreshed"

---@class chroma_ansible.Snapshot
---@field targets string[]|nil the hosts Ansible resolved during this planning
---@field refreshed boolean|nil false when this is a repeat that did not re-ask

---How a string is shown when it may contain anything.
---
---Every value stays one visible line. A newline inside an argument would
---otherwise draw a second line reading exactly like the next argument, and a tab
---would silently become spacing. The backslash is escaped too, so that a literal
---`\n` and a real newline are not shown identically.
---@param text string
---@return string
local function visible(text)
  local escaped = text:gsub("[\\\n\r\t]", {
    ["\\"] = "\\\\",
    ["\n"] = "\\n",
    ["\r"] = "\\r",
    ["\t"] = "\\t",
  })
  return (escaped:gsub("%c", function(control)
    return ("\\x%02x"):format(control:byte())
  end))
end

---Adds one labelled row.
---@param lines string[]
---@param label string
---@param value string
local function row(lines, label, value)
  table.insert(lines, COLUMN:format(label, visible(value)))
end

---Adds a row per value, labelling only the first.
---
---A second inventory source under a blank label is still a second source; a
---second source appended to the first with a comma would read as one path with
---a comma in it.
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

  -- A count, not the names. §7.5: an inventory with thirty thousand hosts must
  -- not become thirty thousand lines in the dialog somebody is reading before
  -- they answer. The names have their own screen (§9.4).
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
  -- Shown even when off, like every other inherited row. §12.2's warning is
  -- attached to the value rather than the choice, because this is the screen
  -- where somebody is deciding whether to go ahead.
  row(lines, "Diff", plan.diff and "on — may print sensitive file contents" or "off")
  row(lines, "Targets reported now", targets(snapshot))

  vim.list_extend(lines, { "", "argv", "" })

  -- Indices are right-aligned so the arguments themselves form a column: a
  -- ten-argument vector and a hundred-argument one both stay readable.
  local width = #tostring(#command - 1)
  for index, word in ipairs(command) do
    table.insert(lines, ("  [%" .. width .. "d]  %s"):format(index - 1, visible(word)))
  end

  return lines
end

---Asks whether to run what the preview showed.
---
---§15.4: only an explicit affirmative starts the process. No, cancel, escape, a
---dismissed dialog and an answer that never arrives all mean that nothing runs,
---so the default is the choice that runs nothing — `confirm` answers 0 for a
---dismissed dialog, which is neither choice and is therefore also no.
---@param lines string[] the preview, as rendered above
---@return boolean
function M.confirm(lines)
  return vim.fn.confirm(("%s\n\nRun?"):format(table.concat(lines, "\n")), "&No\n&Yes", 1) == 2
end

return M
