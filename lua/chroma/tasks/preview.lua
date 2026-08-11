-- What is about to run, and the question asked about it.
--
-- The preview shows the prepared execution and nothing else: the directory the
-- resolver produced, the overrides the task declared, and the argument vector
-- exactly as it will be handed to the process — including `argv[0]` resolved to
-- the path that was found, because that is what will start.
--
-- Nothing is resolved here. This module is handed what the earlier steps
-- decided and represents it; a preview that worked anything out for itself
-- would be a second opinion about the command, and the one on screen is the one
-- somebody agrees to.
--
-- **There is no shell rendering.** No line joins the arguments into something
-- that looks like a command line, because the array never passes through a
-- shell and a rendering joined with spaces misrepresents any argument with a
-- space, a quote or a semicolon in it — and that is the line people copy. See
-- concept.md §7.

local M = {}

---How a string is shown when it may contain anything.
---
---Every argument stays one visible argument. A newline inside one would
---otherwise draw a second line that reads exactly like the next argument, and a
---tab would silently become spacing. The escapes are unambiguous in both
---directions, which is why the backslash is escaped too: without it a literal
---`\n` and a real newline would appear identical.
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

  -- Sorted, so that two previews of the same task read the same. `pairs` has no
  -- order to promise, and a list that rearranges itself between two runs is one
  -- somebody has to read twice.
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

---Asks whether to run what the preview showed.
---
---Only an explicit affirmative starts anything. Escape, cancel, a dismissed
---dialog and an answer that never arrives are all the same answer, and the
---default is the one that runs nothing — this is the last gate before something
---applies infrastructure.
---@param lines string[] the preview, as rendered above
---@return boolean
function M.confirm(lines)
  local question = ("%s\n\nRun this task?"):format(table.concat(lines, "\n"))

  -- The default is the first choice, and the first choice is No. `confirm`
  -- answers 0 when the dialog is dismissed, which is neither choice and is
  -- therefore also no.
  return vim.fn.confirm(question, "&No\n&Yes", 1) == 2
end

return M
