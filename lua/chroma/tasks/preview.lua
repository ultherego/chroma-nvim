-- What is about to run, and the question asked about it: the resolved
-- directory, the declared overrides, and the argument vector exactly as the
-- process will get it, `argv[0]` included.
--
-- Nothing is resolved here. A preview that worked anything out for itself would
-- be a second opinion about the command, and the one on screen is the one
-- somebody agrees to.
--
-- **There is no shell rendering.** The array never passes through a shell, and
-- a line joined with spaces misrepresents any argument holding a space, a quote
-- or a semicolon — and that is the line people copy.

local M = {}

---How a string is shown when it may contain anything: every argument stays one
---visible argument, since a newline would draw a second line that reads like
---the next one. The backslash is escaped too, so a literal `\n` and a real
---newline cannot look identical.
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

---What a task is called on screen.
---@param task table
---@return string
local function called(task)
  if task.group then
    return ("%s / %s"):format(task.group, task.name)
  end
  return task.name
end

---The preview of one prepared task.
---
---@param task table the task, for what it is called
---@param directory string the working directory, already resolved
---@param prepared table the prepared { argv, env } from chroma.tasks.command
---@return string[] lines
function M.render(task, directory, prepared)
  local lines = {
    "Task",
    called(task),
    "",
    "Working directory",
    directory,
  }

  -- Sorted, so two previews of the same task read the same: `pairs` promises
  -- no order.
  local names = vim.tbl_keys(prepared.env)
  table.sort(names)

  if #names > 0 then
    table.insert(lines, "")
    table.insert(lines, "Environment overrides")
    for _, name in ipairs(names) do
      table.insert(lines, ("%s=%s"):format(visible(name), visible(prepared.env[name])))
    end
  end

  table.insert(lines, "")
  for index, word in ipairs(prepared.argv) do
    -- Numbered from zero, as the process sees them.
    table.insert(lines, ("argv[%d]  %s"):format(index - 1, visible(word)))
  end

  return lines
end

---Asks whether to run what the preview showed. Escape, cancel, a dismissed
---dialog and an answer that never arrives are all no: this is the last gate
---before something applies infrastructure.
---@param lines string[] the preview, as rendered above
---@return boolean
function M.confirm(lines)
  local question = ("%s\n\nRun this task?"):format(table.concat(lines, "\n"))

  -- The default is the first choice, and the first choice is No. `confirm`
  -- answers 0 when dismissed, which is neither choice and therefore also no.
  return vim.fn.confirm(question, "&No\n&Yes", 1) == 2
end

return M
