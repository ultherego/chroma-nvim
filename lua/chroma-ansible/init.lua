-- chroma-ansible — the Ansible execution planner.
--
-- The seven modules beside this one each answer one question and none of them
-- knows the order. This is the order: what is asked, when, and what a failure
-- does to the rest of it. The rules are `doc/chroma-ansible-design.md`, and
-- every step below names the section it comes from.
--
--     playbook → working directory → inventory → tags → limit → overrides
--     → target snapshot → preview → explicit yes → terminal
--
-- **Nothing here decides anything twice.** The steps hand their answers to
-- `planner`, the array comes from `argv`, the screen from `preview`, the
-- process from `run`. A step that worked something out for itself would be a
-- second opinion about a command somebody is agreeing to.
--
-- **Cancelling is an answer.** Escape, a dismissed picker, an empty input and a
-- selection nobody made all end the run — and end it through `planner.cancel`,
-- so that an inspection still in flight cannot come back and populate a picker
-- for a run that no longer exists (§13.2, §15.4).
--
-- **Failure to inspect is not failure to execute** (§16). Every inspection here
-- is best-effort: its failure offers Ansible's own output and a way to carry on
-- describing the run by hand. The only refusals that end the planner outright
-- are the ones where there is nothing left to describe — no `ansible-playbook`,
-- no readable playbook, no usable directory.

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
--- (§16). Both are required by the component contract; a machine can still
--- disagree with its manifest.
local PLAYBOOK_TOOL, INVENTORY_TOOL = "ansible-playbook", "ansible-inventory"

---Says why nothing will happen. Chroma's own words — never a subprocess's
---output, which belongs on the screen that offers a way onwards (§7.4).
---@param message string
local function refuse(message)
  vim.notify(message, vim.log.levels.ERROR)
end

---@class chroma_ansible.Choice
---@field label string what the operator reads
---@field value any what the step does with it

---Asks the operator to choose, and ends the run if they decline to.
---@param run chroma_ansible.Run
---@param prompt string
---@param choices chroma_ansible.Choice[]
---@param chosen fun(value: any)
local function choose(run, prompt, choices, chosen)
  vim.ui.select(choices, {
    prompt = prompt,
    format_item = function(choice)
      return choice.label
    end,
  }, function(choice)
    if choice == nil then
      -- §15.4: a dismissed picker is not a pause. It ends the run, and ending
      -- it invalidates the generation so a slow inspection cannot answer into
      -- a planner that is gone.
      return planner.cancel(run)
    end
    chosen(choice.value)
  end)
end

---Asks for a path, ending the run on an empty answer.
---
---`vim.ui.input` with `completion = "file"` — measured, §20.9 — so no plugin is
---needed to type a path. Nothing scans the filesystem for playbooks: a playbook
---need not live in a repository, a project, or anywhere in particular (§4.3).
---@param run chroma_ansible.Run
---@param prompt string
---@param default string
---@param entered fun(path: string)
local function ask_path(run, prompt, default, entered)
  vim.ui.input({ prompt = prompt, default = default, completion = "file" }, function(answer)
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
  -- `<leader>ar` guessed the playbook from the buffer and that is exactly what
  -- is not coming back (§2.4).
  local suggestion = context.suggestion(vim.api.nvim_buf_get_name(0))
  if suggestion then
    table.insert(choices, {
      label = ("Current buffer: %s"):format(vim.fn.fnamemodify(suggestion, ":~:.")),
      value = suggestion,
    })
  end
  table.insert(choices, { label = "Choose another…", value = false })

  choose(run, "Playbook", choices, function(value)
    if value then
      return accept(value)
    end
    ask_path(run, "Playbook: ", nearby(), accept)
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
      -- `ansible.cfg present` is a `stat` and is worded as one. Ansible does
      -- not search upward (§3.1, measured §20.1), so the interface may not
      -- imply it would find any of these by itself.
      label = ("%s    %s    %s"):format(
        candidate.path,
        candidate.why,
        candidate.config and "ansible.cfg present" or "no ansible.cfg"
      ),
      value = candidate.path,
    })
  end
  table.insert(choices, { label = "Choose another…", value = false })

  choose(run, "Working directory", choices, function(value)
    if value then
      return accept(value)
    end
    ask_path(run, "Working directory: ", nearby(), accept)
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
    -- §5.3: this means one thing — no `-i` is passed. The planner does not go
    -- looking for what Ansible's default inventory would be and then pass it
    -- explicitly, because that replaces Ansible's precedence with a guess at it.
    table.insert(choices, { label = "Use Ansible configuration", value = "inherit" })
  end
  table.insert(choices, { label = "Add a source…", value = "add" })
  if #sources > 0 then
    table.insert(choices, { label = ("Done (%d source(s))"):format(#sources), value = "done" })
    for index, source in ipairs(sources) do
      table.insert(choices, { label = ("Remove %d: %s"):format(index, source), value = index })
    end
  end

  choose(run, "Inventory", choices, function(value)
    if value == "inherit" or value == "done" then
      planner.set_inventory(run, sources)
      return settled()
    end
    if value == "add" then
      -- A file or a directory, and never called a `hosts.yml`: an inventory may
      -- be a directory, an executable script or a plugin configuration (§5.2).
      -- Relative to the frozen directory, which is what makes
      -- `../inventories/dev/hosts.yml` mean one thing.
      return ask_path(run, "Inventory source: ", "", function(entered)
        table.insert(sources, entered)
        ask_inventory(run, sources, settled)
      end)
    end
    -- The order is never sorted, so removing one keeps the rest as they were.
    table.remove(sources, value)
    ask_inventory(run, sources, settled)
  end)
end

-- ---------------------------------------------------------------------------
-- §16 What a failed inspection offers

---Offers Ansible's own output and the ways onwards.
---
---The output is shown here rather than notified, because a notification is a
---message-history entry and §7.4 keeps subprocess output out of anything that
---keeps it. It is shown whole: not summarised, not rewritten, not truncated.
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
  local choices = { { label = "No tag filter", value = "none" } }
  for _, tag in ipairs(reported) do
    if not vim.tbl_contains(picked, tag) then
      table.insert(choices, { label = tag, value = tag })
    end
  end
  -- §8.1: the list is what Ansible *reported*. Tags inside dynamically included
  -- files are not in it, so this is how they are reached — not a fallback.
  table.insert(choices, { label = "Custom tag…", value = "custom" })
  if #picked > 0 then
    table.insert(choices, { label = ("Done (%s)"):format(table.concat(picked, ", ")), value = "done" })
  end

  choose(run, "Tags reported by Ansible", choices, function(value)
    if value == "none" then
      planner.set_tags(run, {})
      return settled()
    end
    if value == "done" then
      planner.set_tags(run, picked)
      return settled()
    end
    if value == "custom" then
      return vim.ui.input({ prompt = "Tag: " }, function(entered)
        if not entered or entered == "" then
          return planner.cancel(run)
        end
        table.insert(picked, entered)
        pick_tags(run, reported, picked, settled)
      end)
    end
    table.insert(picked, value)
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
      { label = "Retry", value = "retry" },
      { label = "No tag filter", value = "none" },
      { label = "Custom tag…", value = "custom" },
      { label = "Cancel", value = "cancel" },
    }, function(value)
      if value == "retry" then
        return ask_tags(run, settled)
      end
      if value == "cancel" then
        return planner.cancel(run)
      end
      if value == "none" then
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
  local choices = { { label = "No limit", value = false } }

  if graph then
    -- Groups first (§7.5). An inventory with thirty thousand hosts must not
    -- become thirty thousand rows before anybody has chosen anything.
    for _, group in ipairs(graph.groups) do
      table.insert(choices, { label = ("Group: %s"):format(group), value = group })
    end
    for _, host in ipairs(graph.hosts) do
      table.insert(choices, { label = ("Host: %s"):format(host), value = host })
    end
  end
  -- §9.1: no multi-select of hosts. Combining two hosts means generating a
  -- pattern, and whether that is a comma or a colon is the operator's decision.
  table.insert(choices, { label = "Custom pattern…", value = "custom" })

  choose(run, "Limit", choices, function(value)
    if value == "custom" then
      return vim.ui.input({ prompt = "Host pattern: " }, function(entered)
        if not entered or entered == "" then
          return planner.cancel(run)
        end
        -- Byte for byte, unparsed and unexpanded (§9.3).
        planner.set_limit(run, entered)
        settled()
      end)
    end
    -- §9.2: `No limit` emits nothing at all, never `-l all`.
    planner.set_limit(run, value or nil)
    settled()
  end)
end

---@param run chroma_ansible.Run
---@param inventory_tool string|nil absolute path, or nil when it is not installed
---@param settled fun()
local function ask_limit(run, inventory_tool, settled)
  if not inventory_tool then
    -- §16: no discovery, and the run proceeds. `No limit` and `Custom pattern…`
    -- are still a complete description of a limit.
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
      { label = "Retry", value = "retry" },
      { label = "Continue without discovered groups and hosts", value = "continue" },
      { label = "Cancel", value = "cancel" },
    }, function(value)
      if value == "retry" then
        return ask_limit(run, inventory_tool, settled)
      end
      if value == "cancel" then
        return planner.cancel(run)
      end
      pick_limit(run, nil, settled)
    end)
  end)
end

-- ---------------------------------------------------------------------------
-- §10, §12 The CLI overrides

--- Every question here is inherit-or-override, never on/off: command-line
--- options do not outrank playbook keywords and variables in every case, so
--- `Become: no` would be a claim about the run that Chroma cannot make (§10).
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
    { label = "Inherit from Ansible", value = false },
    { label = "Custom…", value = true },
  }, function(value)
    if not value then
      run.plan.remote_user = nil
      return settled()
    end
    vim.ui.input({ prompt = "Remote user: " }, function(entered)
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

  -- Remembered only once it started. A plan nobody ran is not the last
  -- invocation (§14).
  planner.remember(run)
end

---@param run chroma_ansible.Run
local function ask_targets(run)
  inspect.targets(run, function(answer)
    if answer.declined then
      return planner.cancel(run)
    end
    -- §16: a failed `--list-hosts` costs the snapshot and nothing else. The
    -- preview says `not reported` and the run stands.
    confirm_and_run(run, answer.targets and { targets = answer.targets } or nil)
  end)
end

-- ---------------------------------------------------------------------------
-- The entry points

---Plans and runs one Ansible invocation.
---
---`<leader>ar`. Every step is a question, the last one is `Run?`, and any of
---them may be answered by walking away.
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

      -- Shown relative to the directory it will run from when it lives inside
      -- it. Both paths are canonical, so this is a presentation of the same
      -- file and not a second way of finding it.
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

---Repeats the last invocation, stopping at the preview.
---
---`<leader>aR`. §14.2: it runs nothing by itself. The executable is resolved
---again and the paths re-checked, so a repeat refuses rather than running
---something that has moved since (§14.4).
function M.again()
  local run, problem = planner.recall(inspect.tool)
  if not run then
    return refuse(problem)
  end

  -- §14.5: the previous run's host count is not repeated as though it were
  -- still true. Refreshing it is an active inspection and passes the gate again.
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
