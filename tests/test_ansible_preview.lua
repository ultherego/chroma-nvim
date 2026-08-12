-- The last screen, and what it is not allowed to claim.
--
-- Two kinds of case here. One kind checks that a decision reaches the screen at
-- all — an inventory source, a tag, the mode. The other checks the wording, and
-- those matter more than they look: `Become = no` and `CLI become override:
-- inherited` describe the same absent flag and only one of them is true, since
-- a playbook keyword can enable become that no CLI flag mentions.
--
-- `doc/chroma-ansible-design.md`, sections 10, 12, 14.5 and 15.

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local argv = require("chroma-ansible.argv")
local planner = require("chroma-ansible.planner")
local preview = require("chroma-ansible.preview")

local T = new_set()

---A run with everything inherited.
---@param plan table|nil what to override in the plan
---@return chroma_ansible.Run
local function prepared(plan)
  local run = planner.start()
  planner.set_executable(run, "/usr/bin/ansible-playbook")
  planner.set_directory(run, "/work/operations")
  planner.set_playbooks(run, { "plays/site_upgrade.yml" })
  planner.set_inventory(run, { "../inventories/dev/hosts.yml" })
  run.plan = vim.tbl_extend("force", run.plan, plan or {})
  return run
end

---The rendered preview of a run, as one string.
---@param run chroma_ansible.Run
---@param snapshot chroma_ansible.Snapshot|nil
---@return string
local function shown(run, snapshot)
  local command = assert(argv.execution(run.plan))
  return table.concat(preview.render(run, command, snapshot), "\n")
end

---The value on the row with this label.
---@param run chroma_ansible.Run
---@param label string
---@param snapshot chroma_ansible.Snapshot|nil
---@return string|nil
local function value_of(run, label, snapshot)
  local command = assert(argv.execution(run.plan))
  for _, line in ipairs(preview.render(run, command, snapshot)) do
    local found = line:match("^" .. vim.pesc(label) .. "%s+(.*)$")
    if found then
      return found
    end
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- The decisions

T["decisions"] = new_set()

T["decisions"]["name the frozen directory and the playbook"] = function()
  local text = shown(prepared())

  eq(text:find("Working directory      /work/operations", 1, true) ~= nil, true)
  eq(text:find("Playbook               plays/site_upgrade.yml", 1, true) ~= nil, true)
end

T["decisions"]["give every inventory source its own line"] = function()
  local run = prepared()
  planner.set_inventory(run, { "../inventories/common", "../inventories/prod" })

  local text = shown(run)

  -- Two sources joined with a comma would read as one path with a comma in it,
  -- and the order is Ansible's business (§5.1), so it is shown as given.
  eq(text:find("Inventory              ../inventories/common\n", 1, true) ~= nil, true)
  eq(text:find("\n                       ../inventories/prod", 1, true) ~= nil, true)
end

T["decisions"]["say when Ansible's own configuration decides the inventory"] = function()
  local run = prepared()
  planner.set_inventory(run, {})

  eq(value_of(run, "Inventory"), "from Ansible configuration")
end

T["decisions"]["give every tag its own line"] = function()
  local run = prepared()
  planner.set_tags(run, { "common", "security" })

  local text = shown(run)

  eq(text:find("Tags                   common\n", 1, true) ~= nil, true)
  eq(text:find("\n                       security", 1, true) ~= nil, true)
end

T["decisions"]["show the limit exactly as it was written"] = function()
  local run = prepared()
  planner.set_limit(run, "webservers:&production")

  eq(value_of(run, "Limit"), "webservers:&production")
end

-- ---------------------------------------------------------------------------
-- The wording

T["wording"] = new_set()

T["wording"]["calls an unset option inherited, never no"] = function()
  -- §10: the absence of `-b` is not become being off. A playbook keyword or a
  -- variable may enable it, and saying `no` would be a claim about the run that
  -- Chroma is in no position to make.
  local run = prepared()

  eq(value_of(run, "CLI become override"), "inherited")
  eq(value_of(run, "CLI remote-user"), "inherited")
  eq(value_of(run, "Vault"), "inherited")
end

T["wording"]["calls the remote user an override rather than the user"] = function()
  local run = prepared({ remote_user = "deploy" })

  -- §10.2: `CLI remote-user override: deploy`, not `Remote user =
  -- deploy`. Command-line options do not outrank everything.
  eq(value_of(run, "CLI remote-user"), "deploy")
  eq(shown(run):find("Remote user =", 1, true), nil)
end

T["wording"]["keeps the two become questions apart"] = function()
  local run = prepared({ ask_become_pass = true })

  -- §10.1: `-K` is meaningful without `-b`, because become may come from the
  -- playbook. One row may not answer for the other.
  eq(value_of(run, "CLI become override"), "inherited")
  eq(value_of(run, "Ask become password"), "yes (-K)")
end

T["wording"]["names check mode as Ansible's own"] = function()
  eq(value_of(prepared({ check = true }), "Mode"), "check (--check)")
  eq(value_of(prepared(), "Mode"), "run")
end

T["wording"]["carries the diff warning on the row that turns it on"] = function()
  -- §12.2: Ansible itself warns that diff mode may reveal sensitive contents.
  eq(value_of(prepared({ diff = true }), "Diff"), "on — may print sensitive file contents")
end

T["wording"]["shows diff even when it is off"] = function()
  -- Like every other inherited row. Silence would read as "did I look at that
  -- one?" on the screen where somebody is deciding to go ahead.
  eq(value_of(prepared(), "Diff"), "off")
end

-- ---------------------------------------------------------------------------
-- The target snapshot

T["the snapshot"] = new_set()

T["the snapshot"]["is a count taken now"] = function()
  eq(value_of(prepared(), "Targets reported now", { targets = { "web01", "web02" } }), "2 hosts")
end

T["the snapshot"]["counts one host in the singular"] = function()
  eq(value_of(prepared(), "Targets reported now", { targets = { "web01" } }), "1 host")
end

T["the snapshot"]["is a count and not thirty thousand lines"] = function()
  -- §7.5. The names have their own screen; this is a dialog somebody reads
  -- before answering.
  local many = {}
  for index = 1, 5000 do
    table.insert(many, ("host%d"):format(index))
  end

  local rendered = preview.render(prepared(), { "/usr/bin/ansible-playbook", "p.yml" }, { targets = many })

  eq(value_of(prepared(), "Targets reported now", { targets = many }), "5000 hosts")
  eq(#rendered < 40, true)
end

T["the snapshot"]["says so when nothing was reported"] = function()
  -- §16: a failed `--list-hosts` does not block the run, and the preview does
  -- not quietly leave the row out either.
  eq(value_of(prepared(), "Targets reported now", nil), "not reported")
  eq(value_of(prepared(), "Targets reported now", {}), "not reported")
end

T["the snapshot"]["is never a number carried over from a previous run"] = function()
  -- §14.5: a repeat that did not ask again may not show the old count as though
  -- it were still true. Between the two runs an autoscaling group can have
  -- resized.
  eq(value_of(prepared(), "Targets reported now", { refreshed = false, targets = { "web01" } }), "not refreshed")
end

-- ---------------------------------------------------------------------------
-- argv

T["argv"] = new_set()

T["argv"]["is the array that will start, numbered from zero"] = function()
  local run = prepared({ remote_user = "deploy", become = true })
  local text = shown(run)

  eq(text:find("  [0]  /usr/bin/ansible-playbook", 1, true) ~= nil, true)
  eq(text:find("  [1]  -u", 1, true) ~= nil, true)
  eq(text:find("  [2]  deploy", 1, true) ~= nil, true)
end

T["argv"]["is shown, not built, by this module"] = function()
  -- §15.2: the preview and the executor read one prepared array. A preview that
  -- worked the command out for itself would be a second opinion about what
  -- somebody is agreeing to.
  local rendered = preview.render(prepared(), { "/opt/wrapper/ansible-playbook", "--dry" }, nil)
  local text = table.concat(rendered, "\n")

  eq(text:find("  [0]  /opt/wrapper/ansible-playbook", 1, true) ~= nil, true)
  eq(text:find("  [1]  --dry", 1, true) ~= nil, true)
  eq(text:find("plays/site_upgrade.yml\n  [", 1, true), nil)
end

T["argv"]["never renders a command line"] = function()
  -- §15.3. The array does not pass through a shell, and a line joined with
  -- spaces misrepresents any argument with a space or a quote in it — which is
  -- the line somebody would copy.
  local run = prepared({ limit = "webservers:&production" })

  eq(shown(run):find("ansible-playbook -", 1, true), nil)
end

T["argv"]["keeps an argument that holds a newline on one line"] = function()
  local rendered = preview.render(prepared(), { "/usr/bin/ansible-playbook", "one\ntwo" }, nil)

  eq(rendered[#rendered], "  [1]  one\\ntwo")
end

T["argv"]["lines its indices up when there are more than ten"] = function()
  local command = { "/usr/bin/ansible-playbook" }
  for index = 1, 12 do
    table.insert(command, ("--flag%d"):format(index))
  end

  local rendered = preview.render(prepared(), command, nil)
  local text = table.concat(rendered, "\n")

  eq(text:find("  [ 0]  /usr/bin/ansible-playbook", 1, true) ~= nil, true)
  eq(text:find("  [12]  --flag12", 1, true) ~= nil, true)
end

-- ---------------------------------------------------------------------------
-- The question

T["the question"] = new_set()

T["the question"]["defaults to no, and a dismissed dialog is no"] = function()
  local saw
  local confirm = vim.fn.confirm
  vim.fn.confirm = function(question, choices, default)
    saw = { question = question, choices = choices, default = default }
    return 0
  end

  local answered = preview.confirm({ "ANSIBLE EXECUTION" })
  vim.fn.confirm = confirm

  eq(answered, false)
  eq(saw.choices, "&No\n&Yes")
  eq(saw.default, 1)
  eq(saw.question:find("Run?", 1, true) ~= nil, true)
end

T["the question"]["starts the run only on an explicit yes"] = function()
  local confirm = vim.fn.confirm
  vim.fn.confirm = function()
    return 2
  end

  local answered = preview.confirm({ "ANSIBLE EXECUTION" })
  vim.fn.confirm = confirm

  eq(answered, true)
end

return T
