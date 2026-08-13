-- Run Task: the one place the pieces are put in order, and the order is the
-- contract:
--
--     availability → discovery → trust → schema → picker
--                  → cwd → argv → preview → confirmation → run
--
-- Three positions are load-bearing. Trust comes before the picker, because a
-- modal on top of a picker is a question about a list somebody can no longer
-- see. The directory and the executable resolve after it, so one task naming a
-- missing command cannot hide every other task in the document. And the preview
-- and the executor read one prepared execution, because between the question
-- and the answer a PATH can change.
--
-- Nothing here decides whether a task may run; it reports what the modules
-- decided, and anything that is not an explicit yes ends in nothing happening.

local M = {}

local availability = require("chroma.tasks.availability")
local command = require("chroma.tasks.command")
local cwd = require("chroma.tasks.cwd")
local preview = require("chroma.tasks.preview")
local run = require("chroma.tasks.run")
local schema = require("chroma.tasks.schema")
local source = require("chroma.tasks.source")
local trust = require("chroma.tasks.trust")

---How anything is said. A variable so a test can read what a person would.
---@type fun(message: string, level: integer|nil)
M.notify = function(message, level)
  vim.notify(message, level or vim.log.levels.INFO)
end

---How a task is chosen. `vim.ui.select` and nothing more: tasks are core, and
---a core feature may not need an external program — `fzf` is recommended in the
---contract, not required.
---@type fun(items: table[], opts: table, on_choice: fun(choice: table|nil))
M.select = function(items, opts, on_choice)
  vim.ui.select(items, opts, on_choice)
end

---What the picker shows for one task.
---@param task table
---@return string
local function label(task)
  if task.group then
    return ("%s / %s"):format(task.group, task.name)
  end
  return task.name
end

---What to say about a trust state that is not "trusted".
---@param decision table
---@return string message, integer level
local function refusal(decision)
  if decision.state == "denied" then
    return ("Project tasks are denied.\n\n%s has been denied in Neovim's trust database.\n"):format(decision.path)
      .. "View the file and remove that decision with `:trust ++remove` if you want to be asked again.",
      vim.log.levels.WARN
  end

  if decision.state == "untrusted" then
    -- The adapter has already put Neovim's question on screen, and `read()`
    -- gives no answer to wait for. The next step is the user's: view the file,
    -- `:trust`, and ask for the task again.
    return "Project tasks were not loaded. Trust the file and run this again.", vim.log.levels.INFO
  end

  return decision.problem or "Project tasks could not be read.", vim.log.levels.ERROR
end

---Everything after a task has been chosen.
---@param chosen table
---@param project chroma.tasks.Source
local function start(chosen, project)
  local directory, problem = cwd.resolve(project, chosen)
  if problem then
    M.notify(problem, vim.log.levels.ERROR)
    return
  end

  local prepared
  prepared, problem = command.prepare(chosen, directory)
  if problem then
    M.notify(problem, vim.log.levels.ERROR)
    return
  end

  -- One prepared execution, shown and then run: preparing it again after the
  -- confirmation would let the answer be about a different command.
  if not preview.confirm(preview.render(chosen, directory, prepared)) then
    return
  end

  run.start(chosen, directory, prepared)
end

---Run Task.
function M.run()
  if not availability.available() then
    local summary, advice = availability.reason()
    M.notify(("%s\n\n%s"):format(summary, advice), vim.log.levels.ERROR)
    return
  end

  local project, problem = source.find()
  if problem then
    M.notify(problem, vim.log.levels.ERROR)
    return
  end
  if not project then
    M.notify("No project tasks: no .chroma/tasks.json above this directory.", vim.log.levels.INFO)
    return
  end

  local decision = trust.consult(project, function(path)
    M.notify(
      ("%s declares tasks for this project, and Neovim has to trust the file before Chroma reads it.\n"):format(path)
        .. 'The prompt that follows is Neovim\'s own and calls this "exrc": choose (v)iew, read the file, then run `:trust`.',
      vim.log.levels.WARN
    )
  end)

  if decision.state ~= "trusted" then
    M.notify(refusal(decision))
    return
  end

  -- The bytes the adapter authorised, not a second reading of the file.
  local tasks
  tasks, problem = schema.read(decision.bytes)
  if problem then
    M.notify(("%s: %s"):format(project.path, problem), vim.log.levels.ERROR)
    return
  end

  if #tasks == 0 then
    M.notify(("%s declares no tasks."):format(project.path), vim.log.levels.INFO)
    return
  end

  -- The tasks themselves, not their labels: two may share a name, since the
  -- schema requires unique ids and says nothing about names.
  M.select(tasks, { prompt = "Run task", format_item = label }, function(chosen)
    if not chosen then
      return
    end
    start(chosen, project)
  end)
end

return M
