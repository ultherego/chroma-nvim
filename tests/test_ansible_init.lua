-- The order of the questions, and what each answer does to the rest of them.
--
-- Every other module in `chroma-ansible` is checked on its own terms. This one
-- is checked as a sequence: that a refusal stops it, that a cancellation ends
-- it rather than skipping a step, that a failed inspection degrades into a way
-- of carrying on by hand, and that the last thing before a process is a yes.
--
-- The pickers are scripted rather than driven, because what is worth checking
-- is which question was asked and what the answer did — not how `vim.ui.select`
-- draws a list.
--
-- `doc/chroma-ansible-design.md`, sections 4, 5, 8, 9, 14, 15 and 16.

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local ansible = require("chroma-ansible")
local inspect = require("chroma-ansible.inspect")
local planner = require("chroma-ansible.planner")
local preview = require("chroma-ansible.preview")
local runner = require("chroma-ansible.run")

--- A directory holding a playbook, because both are checked for real. The
--- `ansible.cfg` is what makes the directory itself a candidate: §3.3 offers
--- Neovim's directory, the playbook's own, and ancestors carrying that file.
--- Inventory sources exist for real too, because the step now resolves what it
--- is given against the frozen directory and refuses what is not there.
local WORKING, PLAYBOOK = (function()
  local path = vim.fn.tempname()
  vim.fn.mkdir(vim.fs.joinpath(path, "plays"), "p")
  vim.fn.mkdir(vim.fs.joinpath(path, "inventories", "prod"), "p")
  vim.fn.mkdir(vim.fs.joinpath(path, "inventories", "common"), "p")
  vim.fn.writefile({ "[defaults]" }, vim.fs.joinpath(path, "ansible.cfg"))
  vim.fn.writefile({ "all:" }, vim.fs.joinpath(path, "inventories", "hosts.yml"))
  local playbook = vim.fs.joinpath(path, "plays", "site_upgrade.yml")
  vim.fn.writefile({ "- hosts: all" }, playbook)
  return vim.uv.fs_realpath(path), playbook
end)()

---A path inside the working directory.
---@param ... string
---@return string
local function at(...)
  return vim.fs.joinpath(WORKING, ...)
end

--- Stands in for both Ansible tools, and is executable, which `run.lua` checks.
local TOOL = vim.fn.exepath("sh")

local saved, prompts, started, confirmed, script, ran_out, menus, defaults

---Installs the scripted answers.
---
---Each step is `{ pick = "substring" }`, `{ type = "text" }`, or `{}` for the
---answer somebody gives by walking away.
---@param steps table[]
local function answering(steps)
  script = vim.deepcopy(steps)
end

---The next scripted answer, or the walk-away when the script has run out.
---@return table
local function next_answer()
  local step = table.remove(script, 1)
  if not step then
    ran_out = true
    return {}
  end
  return step
end

local T = new_set({
  hooks = {
    pre_case = function()
      prompts, started, confirmed, script, ran_out = {}, {}, true, {}, false
      -- What each menu offered and what each path prompt started from, kept
      -- apart from `prompts` so the substring helper stays a list of strings.
      menus, defaults = {}, {}
      planner.forget()

      saved = {
        select = vim.ui.select,
        input = vim.ui.input,
        tool = inspect.tool,
        tags = inspect.tags,
        inventory = inspect.inventory,
        targets = inspect.targets,
        confirm = preview.confirm,
        start = runner.start,
        notify = vim.notify,
      }

      vim.ui.select = function(items, opts, on_choice)
        table.insert(prompts, opts.prompt)
        local labels = {}
        for _, item in ipairs(items) do
          table.insert(labels, item.label)
        end
        table.insert(menus, { prompt = opts.prompt, labels = labels })
        local step = next_answer()
        if not step.pick then
          return on_choice(nil)
        end
        for _, item in ipairs(items) do
          if item.label:find(step.pick, 1, true) then
            return on_choice(item)
          end
        end
        error(("no choice matching %q under %q"):format(step.pick, opts.prompt))
      end

      vim.ui.input = function(opts, on_confirm)
        table.insert(prompts, opts.prompt)
        table.insert(defaults, { prompt = opts.prompt, default = opts.default })
        on_confirm(next_answer().type)
      end

      inspect.tool = function()
        return TOOL
      end
      inspect.tags = function(_, on_done)
        on_done({ tags = { "common", "security" } })
      end
      inspect.inventory = function(_, _, on_done)
        on_done({ graph = { groups = { "all", "webservers" }, hosts = { "web01" }, children = {} } })
      end
      inspect.targets = function(_, on_done)
        on_done({ targets = { "web01", "web02" } })
      end
      preview.confirm = function()
        return confirmed
      end
      runner.start = function(run, command)
        table.insert(started, { run = run, command = command })
        return { on = function() end }, nil
      end
      vim.notify = function() end
    end,
    post_case = function()
      vim.ui.select, vim.ui.input = saved.select, saved.input
      inspect.tool, inspect.tags = saved.tool, saved.tags
      inspect.inventory, inspect.targets = saved.inventory, saved.targets
      preview.confirm, runner.start = saved.confirm, saved.start
      vim.notify = saved.notify
      planner.forget()
    end,
  },
})

--- Answers that walk the whole planner through with everything inherited.
---@return table[]
local function straight_through()
  return {
    { pick = "Choose another" }, -- Playbook
    { type = PLAYBOOK },
    { pick = "ancestor with ansible.cfg" }, -- Working directory

    { pick = "Use Ansible configuration" }, -- Inventory
    { pick = "No tag filter" }, -- Tags
    { pick = "No limit" }, -- Limit
    { pick = "Inherit" }, -- Remote user
    { pick = "Inherit" }, -- Become
    { pick = "No CLI prompt flag" }, -- Ask become password
    { pick = "Inherit" }, -- Vault
    { pick = "Run" }, -- Mode
    { pick = "Off" }, -- Diff
  }
end

---Whether any prompt held this text.
---@param text string
---@return boolean
local function asked(text)
  for _, prompt in ipairs(prompts) do
    if prompt and prompt:find(text, 1, true) then
      return true
    end
  end
  return false
end

---What one menu offered, found by the text in its prompt.
---@param text string
---@return string[]|nil
local function offered(text)
  for _, menu in ipairs(menus) do
    if menu.prompt and menu.prompt:find(text, 1, true) then
      return menu.labels
    end
  end
  return nil
end

---What the command carries after `flag`. Adjacency rather than presence: a
---value that reached the command in the wrong place is not the same answer.
---@param command string[]
---@param flag string
---@return string|nil
local function after(command, flag)
  for index, word in ipairs(command) do
    if word == flag then
      return command[index + 1]
    end
  end
  return nil
end

---What a path prompt was pre-filled with, found by the text in its prompt.
---@param text string
---@return string|nil
local function started_at(text)
  for _, entry in ipairs(defaults) do
    if entry.prompt and entry.prompt:find(text, 1, true) then
      return entry.default
    end
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Refusing before anything is asked

T["refusing"] = new_set()

T["refusing"]["without ansible-playbook, nothing is planned"] = function()
  -- §16, first row: refuse at the start, naming the tool.
  local said
  inspect.tool = function()
    return nil
  end
  vim.notify = function(message)
    said = message
  end

  ansible.plan()

  eq(said:find("ansible-playbook", 1, true) ~= nil, true)
  eq(#prompts, 0)
  eq(#started, 0)
end

-- ---------------------------------------------------------------------------
-- The order

T["the order"] = new_set()

T["the order"]["asks the playbook before the directory, and the directory before the rest"] = function()
  answering(straight_through())

  ansible.plan()

  eq(ran_out, false)
  eq(prompts[1], "Playbook: ")
  eq(prompts[3], "Working directory: ")
  eq(prompts[4], "Inventory: ")
  eq(asked("Tags reported by Ansible"), true)
  eq(asked("Limit"), true)
end

T["the order"]["ends every prompt where the typing starts"] = function()
  -- A picker puts the prompt straight in front of what is typed into it, so a
  -- bare label and a filter run together: `Limit` and `webservers` came out as
  -- `Limitwebservers`. Asserted over the whole walk-through rather than on one
  -- prompt, because the failure is per step and a new step is easy to add.
  local steps = straight_through()
  steps[4] = { pick = "Add a source" }
  table.insert(steps, 5, { type = "inventories/hosts.yml" })
  table.insert(steps, 6, { pick = "Done" })
  answering(steps)

  ansible.plan()

  eq(ran_out, false)
  eq(#prompts > 10, true)
  for _, prompt in ipairs(prompts) do
    if not prompt:find(": $") then
      error(("prompt %q runs into whatever is typed after it"):format(prompt))
    end
  end
end

T["the order"]["ends at a started process with the prepared array"] = function()
  answering(straight_through())

  ansible.plan()

  eq(#started, 1)
  eq(started[1].command[1], TOOL)
  -- The playbook is positional and last, and shown relative to the directory it
  -- runs from because it lives inside it.
  eq(started[1].command[#started[1].command], "plays/site_upgrade.yml")
  eq(started[1].run.directory, WORKING)
end

T["the order"]["remembers what ran, and only once it ran"] = function()
  answering(straight_through())
  ansible.plan()

  eq(planner.repeatable(), true)
end

T["the order"]["remembers nothing when the terminal refused to start"] = function()
  -- A plan that was confirmed is still not the last invocation until something
  -- ran. Repeating one that never started would repeat a refusal.
  local said
  vim.notify = function(message)
    said = message
  end
  runner.start = function()
    return nil, "the working directory /work/operations is no longer usable"
  end
  answering(straight_through())

  ansible.plan()

  eq(planner.repeatable(), false)
  eq(said:find("no longer usable", 1, true) ~= nil, true)
end

T["the order"]["offers the buffer and still asks"] = function()
  -- §4.2 and §2.4: the old `<leader>ar` guessed the playbook from the buffer,
  -- and that is the part that is not coming back. The suggestion is a row in a
  -- picker, never an answer.
  local other = vim.fs.joinpath(WORKING, "plays", "second.yml")
  vim.fn.writefile({ "- hosts: all" }, other)
  local buffer = vim.api.nvim_create_buf(false, false)
  vim.api.nvim_buf_set_name(buffer, PLAYBOOK)
  vim.api.nvim_set_current_buf(buffer)

  local steps = straight_through()
  steps[2] = { type = other }
  answering(steps)
  ansible.plan()
  vim.api.nvim_set_current_buf(vim.api.nvim_create_buf(false, true))

  eq(offered("Playbook")[1]:find("Current buffer", 1, true) ~= nil, true)
  eq(started[1].command[#started[1].command], "plays/second.yml")
end

-- ---------------------------------------------------------------------------
-- Walking away

T["cancelling"] = new_set()

---Runs the planner with the first `count` answers of a full walk-through, then
---an answer nobody gave.
---@param count integer
local function up_to(count)
  local steps = vim.list_slice(straight_through(), 1, count)
  table.insert(steps, {})
  answering(steps)
  ansible.plan()
end

T["refusing"]["a playbook that cannot be read"] = function()
  -- §4.4: a named refusal, and the run ends — there is nothing left to plan
  -- around a file that is not there.
  local said
  vim.notify = function(message)
    said = message
  end
  answering({ { pick = "Choose another" }, { type = vim.fs.joinpath(WORKING, "plays", "missing.yml") } })

  ansible.plan()

  eq(said:find("missing.yml", 1, true) ~= nil, true)
  eq(#started, 0)
end

T["cancelling"]["at the playbook ends the run"] = function()
  up_to(0)

  eq(#started, 0)
  eq(#prompts, 1)
end

T["cancelling"]["at the directory ends the run"] = function()
  up_to(2)

  eq(#started, 0)
  eq(asked("Inventory"), false)
end

T["cancelling"]["at the inventory ends the run"] = function()
  up_to(3)

  eq(#started, 0)
  eq(asked("Tags reported by Ansible"), false)
end

T["cancelling"]["ends the run rather than leaving it waiting"] = function()
  -- A step that simply returned would start nothing either, and would leave a
  -- run whose generation is still current — so a slow inspection could come
  -- back and populate a picker for a planner nobody is looking at (§13.2).
  local cancelled = 0
  local cancel = planner.cancel
  planner.cancel = function(run)
    cancelled = cancelled + 1
    return cancel(run)
  end

  up_to(0)
  local at_playbook = cancelled
  up_to(3)
  planner.cancel = cancel

  eq(at_playbook, 1)
  eq(cancelled, 2)
end

T["cancelling"]["at the preview starts nothing"] = function()
  -- §15.4: the last question, and the only affirmative that matters.
  confirmed = false
  answering(straight_through())

  ansible.plan()

  eq(#started, 0)
  eq(planner.repeatable(), false)
end

T["cancelling"]["invalidates the generation of the run it ended"] = function()
  -- So that an inspection still in flight cannot answer into a planner that is
  -- gone (§13.2). The run is reached through the inspection it started.
  local seen
  inspect.tags = function(run)
    seen = run
  end
  answering({
    { pick = "Choose another" },
    { type = PLAYBOOK },
    { pick = "ancestor with ansible.cfg" },
    { pick = "Use Ansible configuration" },
  })

  ansible.plan()
  local before = seen.generation
  -- The tag step never answered, so the planner is waiting; ending it is what a
  -- dismissed picker would do.
  planner.cancel(seen)

  eq(seen.generation > before, true)
end

-- ---------------------------------------------------------------------------
-- Degrading

T["degrading"] = new_set()

T["degrading"]["a failed tag inspection offers a way to carry on"] = function()
  inspect.tags = function(_, on_done)
    on_done({ problem = "[ERROR]: couldn't resolve module/action 'bogus'" })
  end
  local steps = straight_through()
  -- The tag step is answered twice now: once in the failure menu, once not at
  -- all, because `No tag filter` settles it there.
  table.remove(steps, 5)
  table.insert(steps, 5, { pick = "No tag filter" })
  answering(steps)

  ansible.plan()

  -- §16: Ansible's own output, whole, on the screen that offers the way out.
  eq(asked("Tag inspection failed"), true)
  eq(asked("couldn't resolve module/action 'bogus'"), true)
  eq(#started, 1)
end

T["degrading"]["a failed tag inspection can be retried"] = function()
  local calls = 0
  inspect.tags = function(_, on_done)
    calls = calls + 1
    if calls == 1 then
      return on_done({ problem = "[ERROR]: transient" })
    end
    on_done({ tags = { "common" } })
  end
  local steps = straight_through()
  table.insert(steps, 5, { pick = "Retry" })
  answering(steps)

  ansible.plan()

  eq(calls, 2)
  eq(#started, 1)
end

T["degrading"]["a failed inventory inspection still allows a limit"] = function()
  inspect.inventory = function(_, _, on_done)
    on_done({ problem = "[ERROR]: Unable to parse inventory source" })
  end
  local steps = straight_through()
  table.insert(steps, 6, { pick = "Continue without discovered groups and hosts" })
  answering(steps)

  ansible.plan()

  eq(asked("Inventory inspection failed"), true)
  eq(#started, 1)
end

T["degrading"]["without ansible-inventory nothing is inspected for the limit"] = function()
  -- §16: no discovery, and the run proceeds. `No limit` and `Custom pattern…`
  -- still describe a limit completely.
  local inspected = false
  inspect.tool = function(name)
    if name == "ansible-inventory" then
      return nil
    end
    return TOOL
  end
  inspect.inventory = function()
    inspected = true
  end
  answering(straight_through())

  ansible.plan()

  eq(inspected, false)
  eq(#started, 1)
end

T["degrading"]["a failed target listing does not stop the run"] = function()
  local snapshot = "unset"
  inspect.targets = function(_, on_done)
    on_done({ problem = "[ERROR]: no hosts to target" })
  end
  preview.confirm = function()
    return true
  end
  local rendered = preview.render
  preview.render = function(run, command, given)
    snapshot = given
    return rendered(run, command, given)
  end
  answering(straight_through())

  ansible.plan()
  preview.render = rendered

  eq(snapshot, nil)
  eq(#started, 1)
end

T["degrading"]["a declined gate ends the planner"] = function()
  inspect.tags = function(_, on_done)
    on_done({ declined = true })
  end
  answering(straight_through())

  ansible.plan()

  eq(#started, 0)
  eq(asked("Limit"), false)
end

-- ---------------------------------------------------------------------------
-- What the steps record

-- ---------------------------------------------------------------------------
-- What the limit offers

T["the limit"] = new_set()

T["the limit"]["offers the groups Ansible reported before its hosts"] = function()
  answering(straight_through())

  ansible.plan()

  eq(offered("Limit"), { "No limit", "Group: all", "Group: webservers", "Host: web01", "Custom pattern…" })
end

T["the limit"]["says so when the inventory reported no hosts"] = function()
  -- `--graph` answers `@all:` and `@ungrouped:` with `rc=0` for an empty
  -- inventory, for one Ansible could not parse and for a path that is not
  -- there. Offering those two groups would be a list indistinguishable from a
  -- working inventory, and limiting to either of them would match nothing.
  inspect.inventory = function(_, _, on_done)
    on_done({ graph = { groups = { "all", "ungrouped" }, hosts = {}, children = {} } })
  end
  answering(straight_through())

  ansible.plan()

  eq(asked("Limit (the inventory reported no hosts): "), true)
  eq(offered("Limit"), { "No limit", "Custom pattern…" })
end

T["the limit"]["still offers a group that has hosts under it"] = function()
  -- The rule is "no hosts anywhere", not "no groups worth showing": an
  -- inventory with one group and one host in it is a normal inventory.
  inspect.inventory = function(_, _, on_done)
    on_done({ graph = { groups = { "all", "web" }, hosts = { "web01" }, children = {} } })
  end
  answering(straight_through())

  ansible.plan()

  eq(asked("the inventory reported no hosts"), false)
  eq(offered("Limit"), { "No limit", "Group: all", "Group: web", "Host: web01", "Custom pattern…" })
end

-- ---------------------------------------------------------------------------
-- A question that outlived the run that asked it
--
-- A picker and an input are on screen for as long as nobody answers them, which
-- is longer than the run they belong to. Answering one after the operator has
-- started something else calls a setter, and a setter bumps a generation —
-- which used to be the whole test of whether a run was still current.

T["superseded"] = new_set()

---Holds the next question instead of answering it.
---@return table held `{ items, choose }` or `{ confirm }`, filled when asked
local function holding()
  local held = {}
  vim.ui.select = function(items, opts, on_choice)
    table.insert(prompts, opts.prompt)
    held.items, held.choose = items, on_choice
  end
  vim.ui.input = function(opts, on_confirm)
    table.insert(prompts, opts.prompt)
    held.confirm = on_confirm
  end
  return held
end

T["superseded"]["a picker still open when another run starts answers nothing"] = function()
  local held = holding()

  ansible.plan()
  local first = { items = held.items, choose = held.choose }

  -- The operator started another run rather than answering the first.
  ansible.plan()
  local drawn = #prompts

  -- And then went back and answered the old one. `Choose another…` is the
  -- answer that would have drawn the next question.
  first.choose(first.items[#first.items])

  eq(#prompts, drawn)
  eq(#started, 0)
end

T["superseded"]["an input still open when another run starts answers nothing"] = function()
  local held = holding()

  ansible.plan()
  held.choose(held.items[#held.items])
  local first = { confirm = held.confirm }

  ansible.plan()
  local drawn = #prompts

  first.confirm(PLAYBOOK)

  eq(#prompts, drawn)
  eq(#started, 0)
end

T["the answers"] = new_set()

T["the answers"]["put the tags and the limit into the command"] = function()
  local steps = straight_through()
  steps[5] = { pick = "common" }
  table.insert(steps, 6, { pick = "Done" })
  steps[7] = { pick = "Group: webservers" }
  answering(steps)

  ansible.plan()

  local command = started[1].command
  eq(vim.tbl_contains(command, "--tags"), true)
  eq(vim.tbl_contains(command, "common"), true)
  eq(vim.tbl_contains(command, "-l"), true)
  eq(vim.tbl_contains(command, "webservers"), true)
end

T["the answers"]["pass a custom pattern through untouched"] = function()
  local steps = straight_through()
  steps[6] = { pick = "Custom pattern…" }
  table.insert(steps, 7, { type = "webservers:&production" })
  answering(steps)

  ansible.plan()

  eq(vim.tbl_contains(started[1].command, "webservers:&production"), true)
end

-- ---------------------------------------------------------------------------
-- A value that reads like one of the picker's own options
--
-- Every choice carries what kind of thing it is, so nothing Ansible or the
-- operator named can be mistaken for `No tag filter`, `Custom…` or `Done`.
-- Comparing values put the two in one namespace, and a tag reported as `none`
-- cleared the filter instead of applying it — the run got wider than the
-- operator asked for.

T["the answers"]["a tag named like a control choice is a tag"] = new_set({
  parametrize = { { "none" }, { "custom" }, { "done" } },
})

T["the answers"]["a tag named like a control choice is a tag"][""] = function(tag)
  inspect.tags = function(_, on_done)
    on_done({ tags = { tag } })
  end
  local steps = straight_through()
  steps[5] = { pick = tag }
  table.insert(steps, 6, { pick = "Done" })
  answering(steps)

  ansible.plan()

  eq(after(started[1].command, "--tags"), tag)
end

T["the answers"]["a group named like a control choice is a group"] = function()
  inspect.inventory = function(_, _, on_done)
    on_done({ graph = { groups = { "custom" }, hosts = { "web01" }, children = {} } })
  end
  local steps = straight_through()
  steps[6] = { pick = "Group: custom" }
  answering(steps)

  ansible.plan()

  eq(after(started[1].command, "-l"), "custom")
end

T["the answers"]["a host named like a control choice is a host"] = function()
  inspect.inventory = function(_, _, on_done)
    on_done({ graph = { groups = { "all" }, hosts = { "custom" }, children = {} } })
  end
  local steps = straight_through()
  steps[6] = { pick = "Host: custom" }
  answering(steps)

  ansible.plan()

  eq(after(started[1].command, "-l"), "custom")
end

T["the answers"]["emit nothing for No limit"] = function()
  -- §9.2: not `-l all`. The playbook's own `hosts:` stays the authority.
  answering(straight_through())

  ansible.plan()

  eq(vim.tbl_contains(started[1].command, "-l"), false)
  eq(vim.tbl_contains(started[1].command, "all"), false)
end

T["the answers"]["emit no -i when Ansible's configuration decides"] = function()
  -- §5.3: the planner does not look up what the default inventory would be and
  -- pass it explicitly.
  answering(straight_through())

  ansible.plan()

  eq(vim.tbl_contains(started[1].command, "-i"), false)
end

T["the answers"]["keep several inventory sources in the order they were added"] = function()
  local steps = straight_through()
  steps[4] = { pick = "Add a source" }
  -- Deliberately not alphabetical: Ansible merges sources in the order they are
  -- given, so sorting them would quietly change which definition of a host wins.
  table.insert(steps, 5, { type = "inventories/prod" })
  table.insert(steps, 6, { pick = "Add a source" })
  table.insert(steps, 7, { type = "inventories/common" })
  table.insert(steps, 8, { pick = "Done" })
  answering(steps)

  ansible.plan()

  local command = started[1].command
  eq({ command[2], command[3], command[4], command[5] }, {
    "-i",
    at("inventories", "prod"),
    "-i",
    at("inventories", "common"),
  })
end

T["the answers"]["open the inventory prompt at the frozen directory"] = function()
  -- Completion is Neovim's and is anchored at Neovim's directory; the run is
  -- anchored at the directory chosen two steps earlier. Pre-filling the prompt
  -- is what puts the two in the same place before anything is typed.
  local steps = straight_through()
  steps[4] = { pick = "Add a source" }
  table.insert(steps, 5, { type = "inventories/hosts.yml" })
  table.insert(steps, 6, { pick = "Done" })
  answering(steps)

  ansible.plan()

  eq(started_at("Inventory source"), WORKING .. "/")
end

T["the answers"]["store an inventory source resolved against the frozen directory"] = function()
  -- The relative path is real from the working directory and would be a
  -- different file, or none, from anywhere else. What reaches `-i` is neither
  -- ambiguous nor dependent on where Neovim happens to be.
  local steps = straight_through()
  steps[4] = { pick = "Add a source" }
  table.insert(steps, 5, { type = "plays/../inventories/hosts.yml" })
  table.insert(steps, 6, { pick = "Done" })
  answering(steps)

  ansible.plan()

  eq(started[1].run.plan.inventory, { at("inventories", "hosts.yml") })
end

T["refusing"]["an inventory source that is not there, and asking again"] = function()
  -- The failure that produced this: a path typed against Neovim's directory is
  -- absent from the working directory, Ansible answers a warning and `rc=0`,
  -- and the planner used to carry on with an inventory of nothing. It is
  -- refused here instead, naming the path the subprocess would have opened —
  -- and the list is offered again, because one mistyped source is not a reason
  -- to lose the run.
  local said
  vim.notify = function(message)
    said = message
  end
  local steps = straight_through()
  steps[4] = { pick = "Add a source" }
  table.insert(steps, 5, { type = "inventories/dev/hosts.yml" })
  table.insert(steps, 6, { pick = "Use Ansible configuration" })
  answering(steps)

  ansible.plan()

  eq(said:find(at("inventories", "dev", "hosts.yml"), 1, true) ~= nil, true)
  eq(started[1].run.plan.inventory, {})
  eq(vim.tbl_contains(started[1].command, "-i"), false)

  local asked_twice = 0
  for _, prompt in ipairs(prompts) do
    if prompt == "Inventory: " then
      asked_twice = asked_twice + 1
    end
  end
  eq(asked_twice, 2)
end

T["the answers"]["emit nothing for the overrides nobody set"] = function()
  answering(straight_through())

  ansible.plan()

  for _, flag in ipairs({ "-u", "-b", "-K", "--ask-vault-pass", "--check", "--diff" }) do
    eq({ flag, vim.tbl_contains(started[1].command, flag) }, { flag, false })
  end
end

T["the answers"]["emit the overrides somebody did set"] = function()
  local steps = straight_through()
  steps[7] = { pick = "Custom" }
  table.insert(steps, 8, { type = "deploy" })
  steps[9] = { pick = "Enable (-b)" }
  steps[10] = { pick = "Yes (-K)" }
  steps[11] = { pick = "Ask for a password" }
  steps[12] = { pick = "Check" }
  steps[13] = { pick = "On" }
  answering(steps)

  ansible.plan()

  for _, flag in ipairs({ "-u", "deploy", "-b", "-K", "--ask-vault-pass", "--check", "--diff" }) do
    eq({ flag, vim.tbl_contains(started[1].command, flag) }, { flag, true })
  end
end

-- ---------------------------------------------------------------------------
-- Repeating

T["repeating"] = new_set()

T["repeating"]["says so when there is nothing to repeat"] = function()
  local said
  vim.notify = function(message)
    said = message
  end

  ansible.again()

  eq(said ~= nil, true)
  eq(#started, 0)
end

T["repeating"]["goes straight to the preview"] = function()
  answering(straight_through())
  ansible.plan()
  prompts = {}

  ansible.again()

  -- §14.2: no questions, and still a `Run?`.
  eq(#prompts, 0)
  eq(#started, 2)
end

T["repeating"]["runs nothing without an explicit yes"] = function()
  answering(straight_through())
  ansible.plan()
  confirmed = false

  ansible.again()

  eq(#started, 1)
end

T["repeating"]["does not repeat the previous host count"] = function()
  local snapshot
  answering(straight_through())
  ansible.plan()

  local rendered = preview.render
  preview.render = function(run, command, given)
    snapshot = given
    return rendered(run, command, given)
  end
  ansible.again()
  preview.render = rendered

  -- §14.5: `4 hosts` an hour ago is not a fact now.
  eq(snapshot, { refreshed = false })
end

-- ---------------------------------------------------------------------------
-- Setting up

T["setup"] = new_set()

T["setup"]["registers the commands whether or not keymaps are wanted"] = function()
  ansible.setup({ keymaps = false })

  local commands = vim.api.nvim_get_commands({})
  eq(commands.AnsibleRun ~= nil, true)
  eq(commands.AnsibleRepeat ~= nil, true)
end

T["setup"]["maps the keys only when asked"] = function()
  -- Cleared first, because an earlier case in this session may have set them
  -- and `del` raises when there is nothing to delete.
  pcall(vim.keymap.del, "n", "<leader>ar")
  pcall(vim.keymap.del, "n", "<leader>aR")

  ansible.setup({ keymaps = false })
  local without = #vim.fn.maparg("<leader>ar", "n")

  ansible.setup({ keymaps = true })
  local with = #vim.fn.maparg("<leader>ar", "n")

  eq(without, 0)
  eq(with > 0, true)
  eq(#vim.fn.maparg("<leader>aR", "n") > 0, true)
end

return T
