-- chroma-ansible — the Ansible execution planner. The modules beside this one
-- each answer one question; this is the order, and every step names its
-- section in `doc/chroma-ansible-design.md`:
--
--     playbook → working directory → inventory → tags → limit → overrides
--     → target snapshot → preview → explicit yes → terminal
--
-- Nothing here decides anything twice. Cancelling is an answer, and it ends the
-- run through `planner.cancel` so an inspection in flight cannot populate a
-- picker for a run that is gone. Failure to inspect is not failure to execute
-- (§16): the only refusals that end the planner are the ones with nothing left
-- to describe.

local argv = require("chroma-ansible.argv")
local context = require("chroma-ansible.context")
local inspect = require("chroma-ansible.inspect")
local planner = require("chroma-ansible.planner")
local preview = require("chroma-ansible.preview")
local runner = require("chroma-ansible.run")

local M = {}

local defaults = {
  keymaps = false,
}

M.options = vim.deepcopy(defaults)

--- The tool that must be there, and the one whose absence only costs discovery
--- (§16). Both are required by the contract; a machine can still disagree.
local PLAYBOOK_TOOL, INVENTORY_TOOL = "ansible-playbook", "ansible-inventory"

---Says why nothing will happen. Chroma's own words — never a subprocess's
---output, which belongs on the screen that offers a way onwards (§7.4).
---@param message string
local function refuse(message)
  vim.notify(message, vim.log.levels.ERROR)
end

--- What goes between a prompt and whatever is typed after it. Pickers put
--- `opts.prompt` immediately before the input, so a bare label and a filter run
--- together — `Limit` and `webservers` read as `Limitwebservers`. Composed
--- through one constant so no step can be missed.
local PROMPT = "%s: "

---@class chroma_ansible.Choice
---@field label string what the operator reads
---@field value table what the step does with it, carrying what it is

---A picker's own option, which is never something Ansible or the operator
---named. Kept apart by kind rather than by string: comparing values put
---`No tag filter` and a tag reported as `none` in one namespace, and choosing
---that tag cleared the filter instead of applying it (§8.1).
---@param action string
---@return table
local function control(action)
  return { kind = "control", action = action }
end

---A value, carried with what kind of value it is.
---@param kind string
---@param value string|integer
---@return table
local function datum(kind, value)
  return { kind = kind, value = value }
end

---Whether a choice is the control `action`, and never a value that reads like
---one.
---@param choice table
---@param action string
---@return boolean
local function chose(choice, action)
  return choice.kind == "control" and choice.action == action
end

---Asks the operator to choose, and ends the run if they decline to.
---@param run chroma_ansible.Run
---@param prompt string
---@param choices chroma_ansible.Choice[]
---@param chosen fun(value: any)
local function choose(run, prompt, choices, chosen)
  vim.ui.select(choices, {
    prompt = PROMPT:format(prompt),
    format_item = function(choice)
      return choice.label
    end,
  }, function(choice)
    if choice == nil then
      -- §15.4: a dismissed picker is not a pause. Ending the run invalidates
      -- the generation, so a slow inspection cannot answer into one that is gone.
      return planner.cancel(run)
    end
    chosen(choice.value)
  end)
end

---Asks for a path, ending the run on an empty answer. `vim.ui.input` with
---`completion = "file"` (measured, §20.9), so no plugin is needed. Nothing
---scans the filesystem: a playbook need not live anywhere in particular (§4.3).
---@param run chroma_ansible.Run
---@param prompt string
---@param default string
---@param entered fun(path: string)
local function ask_path(run, prompt, default, entered)
  vim.ui.input({ prompt = PROMPT:format(prompt), default = default, completion = "file" }, function(answer)
    if not answer or answer == "" then
      return planner.cancel(run)
    end
    entered(answer)
  end)
end

---Where a path picker should start.
---@return string
local function nearby()
  local buffer = vim.api.nvim_buf_get_name(0)
  local directory = buffer ~= "" and vim.fs.dirname(buffer) or vim.fn.getcwd()
  return directory .. "/"
end

-- ---------------------------------------------------------------------------
-- §4 Playbook

---@param run chroma_ansible.Run
---@param picked fun(playbook: string)
local function ask_playbook(run, picked)
  ---@param path string
  local function accept(path)
    local resolved, problem = context.playbook(path)
    if not resolved then
      -- Named, and the run ends: there is nothing left to plan around a
      -- playbook that cannot be read (§4.4).
      refuse(problem)
      return planner.cancel(run)
    end
    picked(resolved)
  end

  local choices = {}

  -- §4.2: the buffer is a suggestion and never an authority. The old
  -- `<leader>ar` guessed the playbook from it, and that is not coming back.
  local suggestion = context.suggestion(vim.api.nvim_buf_get_name(0))
  if suggestion then
    table.insert(choices, {
      label = ("Current buffer: %s"):format(vim.fn.fnamemodify(suggestion, ":~:.")),
      value = datum("playbook", suggestion),
    })
  end
  table.insert(choices, { label = "Choose another…", value = control("another") })

  choose(run, "Playbook", choices, function(value)
    if chose(value, "another") then
      return ask_path(run, "Playbook", nearby(), accept)
    end
    accept(value.value)
  end)
end

-- ---------------------------------------------------------------------------
-- §3 Working directory

---@param run chroma_ansible.Run
---@param playbook string canonical
---@param frozen fun(directory: string)
local function ask_directory(run, playbook, frozen)
  ---@param path string
  local function accept(path)
    local resolved, problem = context.freeze(path)
    if not resolved then
      refuse(problem)
      return planner.cancel(run)
    end
    frozen(resolved)
  end

  local choices = {}
  for _, candidate in ipairs(context.candidates(playbook, vim.fn.getcwd())) do
    table.insert(choices, {
      -- `ansible.cfg present` is a `stat` and is worded as one: Ansible does
      -- not search upward (§3.1, measured §20.1).
      label = ("%s    %s    %s"):format(
        candidate.path,
        candidate.why,
        candidate.config and "ansible.cfg present" or "no ansible.cfg"
      ),
      value = datum("directory", candidate.path),
    })
  end
  table.insert(choices, { label = "Choose another…", value = control("another") })

  choose(run, "Working directory", choices, function(value)
    if chose(value, "another") then
      return ask_path(run, "Working directory", nearby(), accept)
    end
    accept(value.value)
  end)
end

-- ---------------------------------------------------------------------------
-- §5 Inventory sources

---@param run chroma_ansible.Run
---@param sources string[] collected so far, in the operator's order
---@param settled fun()
local function ask_inventory(run, sources, settled)
  local choices = {}

  if #sources == 0 then
    -- §5.3: this means one thing — no `-i` is passed. Looking up Ansible's
    -- default and passing it explicitly would replace its precedence with a
    -- guess at it.
    table.insert(choices, { label = "Use Ansible configuration", value = control("inherit") })
  end
  table.insert(choices, { label = "Add a source…", value = control("add") })
  if #sources > 0 then
    table.insert(choices, { label = ("Done (%d source(s))"):format(#sources), value = control("done") })
    for index, source in ipairs(sources) do
      -- The position, not the path: two `-i` sources may be the same one twice,
      -- and removing "the one that reads like this" would remove the wrong one.
      table.insert(choices, { label = ("Remove %d: %s"):format(index, source), value = datum("source", index) })
    end
  end

  choose(run, "Inventory", choices, function(value)
    if chose(value, "inherit") or chose(value, "done") then
      planner.set_inventory(run, sources)
      return settled()
    end
    if chose(value, "add") then
      -- A file or a directory, and never called a `hosts.yml`: an inventory
      -- may be a directory, an executable script or a plugin configuration
      -- (§5.2). The prompt opens at the frozen directory and the answer is
      -- resolved against it, because completion is anchored at Neovim's
      -- directory and the run is anchored at the one chosen two steps ago —
      -- with the playbook one level down, a source typed against the wrong one
      -- used to arrive as an inventory with no hosts and `rc=0`.
      return ask_path(run, "Inventory source", run.directory .. "/", function(entered)
        local resolved, problem = context.inventory(run.directory, entered)
        if not resolved then
          refuse(problem)
          -- Back to the list rather than out of the run, unlike a refused
          -- working directory (§3.3): nothing has been frozen by this step and
          -- the sources already chosen are still good.
          return ask_inventory(run, sources, settled)
        end
        table.insert(sources, resolved)
        ask_inventory(run, sources, settled)
      end)
    end
    -- The order is never sorted, so removing one keeps the rest as they were.
    table.remove(sources, value.value)
    ask_inventory(run, sources, settled)
  end)
end

-- ---------------------------------------------------------------------------
-- §16 What a failed inspection offers

---Offers Ansible's own output and the ways onwards. Shown rather than notified,
---because a notification is a message-history entry and §7.4 keeps subprocess
---output out of anything that keeps it. Shown whole: not summarised, not
---truncated.
---@param run chroma_ansible.Run
---@param headline string
---@param answer chroma_ansible.Answer
---@param choices chroma_ansible.Choice[]
---@param chosen fun(value: any)
local function degraded(run, headline, answer, choices, chosen)
  choose(run, ("%s\n\n%s"):format(headline, answer.problem or ""), choices, chosen)
end

-- ---------------------------------------------------------------------------
-- §8 Tags

---@param run chroma_ansible.Run
---@param picked string[] chosen so far
---@param settled fun()
local function pick_tags(run, reported, picked, settled)
  local choices = { { label = "No tag filter", value = control("none") } }
  for _, tag in ipairs(reported) do
    if not vim.tbl_contains(picked, tag) then
      table.insert(choices, { label = tag, value = datum("tag", tag) })
    end
  end
  -- §8.1: the list is what Ansible *reported*. Tags inside dynamically
  -- included files are not in it, so this is how they are reached.
  table.insert(choices, { label = "Custom tag…", value = control("custom") })
  if #picked > 0 then
    table.insert(choices, { label = ("Done (%s)"):format(table.concat(picked, ", ")), value = control("done") })
  end

  choose(run, "Tags reported by Ansible", choices, function(value)
    if chose(value, "none") then
      planner.set_tags(run, {})
      return settled()
    end
    if chose(value, "done") then
      planner.set_tags(run, picked)
      return settled()
    end
    if chose(value, "custom") then
      return vim.ui.input({ prompt = PROMPT:format("Tag") }, function(entered)
        if not entered or entered == "" then
          return planner.cancel(run)
        end
        table.insert(picked, entered)
        pick_tags(run, reported, picked, settled)
      end)
    end
    table.insert(picked, value.value)
    pick_tags(run, reported, picked, settled)
  end)
end

---@param run chroma_ansible.Run
---@param settled fun()
local function ask_tags(run, settled)
  inspect.tags(run, function(answer)
    if answer.declined then
      -- The gate said no. Nothing ran, and nothing more will (§16).
      return planner.cancel(run)
    end
    if answer.tags then
      return pick_tags(run, answer.tags, {}, settled)
    end

    degraded(run, "Tag inspection failed", answer, {
      { label = "Retry", value = control("retry") },
      { label = "No tag filter", value = control("none") },
      { label = "Custom tag…", value = control("custom") },
      { label = "Cancel", value = control("cancel") },
    }, function(value)
      if chose(value, "retry") then
        return ask_tags(run, settled)
      end
      if chose(value, "cancel") then
        return planner.cancel(run)
      end
      if chose(value, "none") then
        planner.set_tags(run, {})
        return settled()
      end
      pick_tags(run, {}, {}, settled)
    end)
  end)
end

-- ---------------------------------------------------------------------------
-- §9 Limit

---@param run chroma_ansible.Run
---@param graph chroma_ansible.Graph|nil what discovery found, if it ran
---@param settled fun()
local function pick_limit(run, graph, settled)
  local choices = { { label = "No limit", value = control("none") } }
  local prompt = "Limit"

  -- An inventory with no hosts is a graph, not a failure: `--graph` answers
  -- `@all:` and `@ungrouped:` for an empty inventory, an unparseable one and a
  -- path that is not there, all three with `rc=0`. Offering those two groups
  -- would be indistinguishable from a working inventory, so the fact is said
  -- out loud instead, in Chroma's own words (§7.4).
  local discovered = graph
  if graph and #graph.hosts == 0 then
    prompt = "Limit (the inventory reported no hosts)"
    discovered = nil
  end

  if discovered then
    -- Groups first (§7.5): thirty thousand hosts must not become thirty
    -- thousand rows before anybody has chosen anything.
    for _, group in ipairs(discovered.groups) do
      table.insert(choices, { label = ("Group: %s"):format(group), value = datum("group", group) })
    end
    for _, host in ipairs(discovered.hosts) do
      table.insert(choices, { label = ("Host: %s"):format(host), value = datum("host", host) })
    end
  end
  -- §9.1: no multi-select of hosts. Combining two means generating a pattern,
  -- and whether that is a comma or a colon is the operator's decision.
  table.insert(choices, { label = "Custom pattern…", value = control("custom") })

  choose(run, prompt, choices, function(value)
    if chose(value, "custom") then
      return vim.ui.input({ prompt = PROMPT:format("Host pattern") }, function(entered)
        if not entered or entered == "" then
          return planner.cancel(run)
        end
        -- Byte for byte, unparsed and unexpanded (§9.3).
        planner.set_limit(run, entered)
        settled()
      end)
    end
    -- §9.2: `No limit` emits nothing at all, never `-l all`.
    planner.set_limit(run, not chose(value, "none") and value.value or nil)
    settled()
  end)
end

---@param run chroma_ansible.Run
---@param inventory_tool string|nil absolute path, or nil when it is not installed
---@param settled fun()
local function ask_limit(run, inventory_tool, settled)
  if not inventory_tool then
    -- §16: no discovery, and the run proceeds. `No limit` and `Custom
    -- pattern…` are still a complete description of a limit.
    return pick_limit(run, nil, settled)
  end

  inspect.inventory(run, inventory_tool, function(answer)
    if answer.declined then
      return planner.cancel(run)
    end
    if answer.graph then
      return pick_limit(run, answer.graph, settled)
    end

    degraded(run, "Inventory inspection failed", answer, {
      { label = "Retry", value = control("retry") },
      { label = "Continue without discovered groups and hosts", value = control("continue") },
      { label = "Cancel", value = control("cancel") },
    }, function(value)
      if chose(value, "retry") then
        return ask_limit(run, inventory_tool, settled)
      end
      if chose(value, "cancel") then
        return planner.cancel(run)
      end
      pick_limit(run, nil, settled)
    end)
  end)
end

-- ---------------------------------------------------------------------------
-- §10, §12 The CLI overrides

--- Every question here is inherit-or-override, never on/off: command-line
--- options do not outrank playbook keywords in every case, so `Become: no`
--- would be a claim about the run that Chroma cannot make (§10).
---
--- The only values in this module that are not tagged with a kind. They are
--- applied and never compared, so there is nothing here for a value to be
--- mistaken for.
local OVERRIDES = {
  {
    prompt = "Become CLI override",
    choices = {
      { label = "Inherit from Ansible", value = false },
      { label = "Enable (-b)", value = true },
    },
    apply = function(plan, value)
      plan.become = value
    end,
  },
  {
    prompt = "Ask become password",
    choices = {
      { label = "No CLI prompt flag", value = false },
      { label = "Yes (-K)", value = true },
    },
    apply = function(plan, value)
      -- §10.1: separate from `-b`, because become may be enabled by the
      -- playbook and the password still has to be asked for.
      plan.ask_become_pass = value
    end,
  },
  {
    prompt = "Vault",
    choices = {
      { label = "Inherit from Ansible", value = false },
      { label = "Ask for a password (--ask-vault-pass)", value = true },
    },
    apply = function(plan, value)
      -- A list, so that vault ids are a picker change rather than a model
      -- change (§10.3). Chroma never holds the password itself (§11).
      plan.vault = value and { "--ask-vault-pass" } or {}
    end,
  },
  {
    prompt = "Execution mode",
    choices = {
      { label = "Run", value = false },
      { label = "Check (--check)", value = true },
    },
    apply = function(plan, value)
      -- §12.1: check mode is Ansible's semantics, not Chroma's guarantee — a
      -- task may set `check_mode: false` and act anyway.
      plan.check = value
    end,
  },
  {
    prompt = "Diff",
    choices = {
      { label = "Off", value = false },
      { label = "On — may print sensitive file contents", value = true },
    },
    apply = function(plan, value)
      -- Never defaulted on: Ansible itself warns that diff can reveal file
      -- contents (§12.2).
      plan.diff = value
    end,
  },
}

---@param run chroma_ansible.Run
---@param index integer
---@param settled fun()
local function ask_overrides(run, index, settled)
  local step = OVERRIDES[index]
  if not step then
    return settled()
  end

  choose(run, step.prompt, step.choices, function(value)
    step.apply(run.plan, value)
    ask_overrides(run, index + 1, settled)
  end)
end

---@param run chroma_ansible.Run
---@param settled fun()
local function ask_remote_user(run, settled)
  choose(run, "Remote user", {
    { label = "Inherit from Ansible", value = control("inherit") },
    { label = "Custom…", value = control("custom") },
  }, function(value)
    if chose(value, "inherit") then
      run.plan.remote_user = nil
      return settled()
    end
    vim.ui.input({ prompt = PROMPT:format("Remote user") }, function(entered)
      if not entered or entered == "" then
        return planner.cancel(run)
      end
      run.plan.remote_user = entered
      settled()
    end)
  end)
end

-- ---------------------------------------------------------------------------
-- §9.4, §15 The snapshot, the preview and the yes

---@param run chroma_ansible.Run
---@param snapshot chroma_ansible.Snapshot|nil
local function confirm_and_run(run, snapshot)
  local command, problem = argv.execution(run.plan)
  if not command then
    refuse(problem)
    return planner.cancel(run)
  end

  if not preview.confirm(preview.render(run, command, snapshot)) then
    -- §15.4. Nothing runs, and the run ends where it was.
    return planner.cancel(run)
  end

  local terminal, refusal = runner.start(run, command)
  if not terminal then
    return refuse(refusal)
  end

  -- Remembered only once it started: a plan nobody ran is not the last
  -- invocation (§14).
  planner.remember(run)
end

---@param run chroma_ansible.Run
local function ask_targets(run)
  inspect.targets(run, function(answer)
    if answer.declined then
      return planner.cancel(run)
    end
    -- §16: a failed `--list-hosts` costs the snapshot and nothing else.
    confirm_and_run(run, answer.targets and { targets = answer.targets } or nil)
  end)
end

-- ---------------------------------------------------------------------------
-- The entry points

---Plans and runs one Ansible invocation — `<leader>ar`. Every step is a
---question, the last is `Run?`, and any of them may be answered by walking away.
function M.plan()
  local executable = inspect.tool(PLAYBOOK_TOOL)
  if not executable then
    -- §16, first row: refuse at the start, naming the tool. Nothing else runs.
    return refuse(("%s was not found on PATH, so there is nothing to plan"):format(PLAYBOOK_TOOL))
  end
  local inventory_tool = inspect.tool(INVENTORY_TOOL)

  local run = planner.start()
  planner.set_executable(run, executable)

  ask_playbook(run, function(playbook)
    ask_directory(run, playbook, function(directory)
      planner.set_directory(run, directory)

      -- Shown relative to the directory it runs from when it lives inside it.
      -- Both paths are canonical, so this is presentation, not a second lookup.
      local inside = vim.startswith(playbook, directory .. "/") and playbook:sub(#directory + 2) or playbook
      planner.set_playbooks(run, { inside })

      ask_inventory(run, {}, function()
        ask_tags(run, function()
          ask_limit(run, inventory_tool, function()
            ask_remote_user(run, function()
              ask_overrides(run, 1, function()
                ask_targets(run)
              end)
            end)
          end)
        end)
      end)
    end)
  end)
end

---Repeats the last invocation, stopping at the preview. §14.2: it runs nothing
---by itself, and §14.4 re-resolves the executable and re-checks the paths, so a
---repeat refuses rather than running something that has moved.
function M.again()
  local run, problem = planner.recall(inspect.tool)
  if not run then
    return refuse(problem)
  end

  -- §14.5: the previous host count is not repeated as though it were still
  -- true. Refreshing it is an active inspection and passes the gate again.
  confirm_and_run(run, { refreshed = false })
end

---@param opts table|nil
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})

  vim.api.nvim_create_user_command("AnsibleRun", M.plan, { desc = "Plan and run an Ansible playbook" })
  vim.api.nvim_create_user_command("AnsibleRepeat", M.again, { desc = "Repeat the last Ansible invocation" })

  if M.options.keymaps then
    vim.keymap.set("n", "<leader>ar", M.plan, { desc = "New Ansible run" })
    vim.keymap.set("n", "<leader>aR", M.again, { desc = "Repeat the last Ansible invocation" })
  end
end

return M
