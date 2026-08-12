-- Reading `--list-tags` back, including the parts that cannot be read.
--
-- The output is a report, not a data format, so the cases here are mostly
-- about what it is honest to claim from it: which line may be believed, which
-- separator means what, and where a name stops being recoverable. Every string
-- below came from a real `ansible-core 2.21.2` run.
--
-- `doc/chroma-ansible-design.md`, section 8.

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local listing = require("chroma-ansible.listing")

local T = new_set()

---One play's worth of `--list-tags`, as Ansible prints it.
---@param name string
---@param play_tags string
---@param task_tags string
---@return string
local function play(name, play_tags, task_tags)
  return ("  play #1 (%s): %s\tTAGS: [%s]\n      TASK TAGS: [%s]\n"):format(name, name, play_tags, task_tags)
end

---A whole listing for one playbook.
---@param body string
---@return string
local function listed(body)
  return "\nplaybook: plays/site_upgrade.yml\n\n" .. body
end

-- ---------------------------------------------------------------------------
-- Reading

T["reading"] = new_set()

T["reading"]["answers the tags of one play, in Ansible's order"] = function()
  local tags = listing.tags(listed(play("webservers", "common", "common, site_upgrade, packages, security")))

  eq(tags, { "common", "site_upgrade", "packages", "security" })
end

T["reading"]["answers nothing for a play that has none"] = function()
  local tags, problem = listing.tags(listed(play("all", "", "")))

  eq(tags, {})
  eq(problem, nil)
end

T["reading"]["merges the plays, first seen first"] = function()
  local tags = listing.tags(listed(play("web", "", "common, deploy") .. "\n" .. play("db", "", "backup, common")))

  eq(tags, { "common", "deploy", "backup" })
end

T["reading"]["keeps a tag that Ansible printed with a space in it"] = function()
  -- Real, and not a curiosity: a tag's own spaces are part of its name, so the
  -- separator is a comma *and* a space and nothing is trimmed afterwards.
  -- `[ leading, trailing ]` came back from a playbook tagged `" leading"` and
  -- `"trailing "`.
  local tags = listing.tags(listed(play("all", "", " leading, trailing ")))

  eq(tags, { " leading", "trailing " })
end

T["reading"]["reads a tag with a colon in it"] = function()
  eq(listing.tags(listed(play("all", "", "role:common, weird:tag"))), { "role:common", "weird:tag" })
end

-- ---------------------------------------------------------------------------
-- What it refuses to be told

T["what it does not believe"] = new_set()

T["what it does not believe"]["a play name that looks like the tags line"] = function()
  -- A play name may contain a tab, so `name: "deploy\tTAGS: [injected]"` prints
  -- a field that looks exactly like the real one. Only the `TASK TAGS` line is
  -- read, and a play name cannot produce one: a newline inside a name is
  -- flattened to a space before printing.
  local output = listed("  play #1 (all): deploy\tTAGS: [injected]\tTAGS: [real]\n      TASK TAGS: [real]\n")

  eq(listing.tags(output), { "real" })
end

T["what it does not believe"]["a name pretending to be a second tags line"] = function()
  local output = listed("  play #1 (all): deploy TASK TAGS: [injected]\tTAGS: [real]\n      TASK TAGS: [real]\n")

  eq(listing.tags(output), { "real" })
end

T["what it does not believe"]["output with no play in it"] = function()
  -- Every play prints a `TASK TAGS` line on a successful listing, including one
  -- with no tasks and no tags. None at all is therefore not "no tags" — it is
  -- output this parser does not recognise, and saying "no tags" would send the
  -- operator to `Custom tag…` believing the playbook has none.
  local tags, problem = listing.tags("\nplaybook: plays/site_upgrade.yml\n\n")

  eq(tags, nil)
  eq(problem ~= nil, true)
end

T["what it does not believe"]["anything that is not output"] = function()
  eq(select(2, listing.tags(nil)) ~= nil, true)
end

T["what it does not believe"]["a tags line at the wrong indentation"] = function()
  -- Anchored on purpose. An ansible that indents differently produces "no plays
  -- were named", which is reported, rather than a listing quietly read in half.
  eq(listing.tags(listed("  play #1 (all): all\tTAGS: []\n  TASK TAGS: [common]\n")), nil)
end

-- ---------------------------------------------------------------------------
-- Ambiguity that costs nothing

T["ambiguity"] = new_set()

T["ambiguity"]["a tag holding a comma survives it"] = function()
  -- The separator is a comma *and* a space, so this one is not ambiguous at
  -- all: `comma,tag` comes back whole.
  eq(listing.tags(listed(play("all", "", "comma,tag, other"))), { "comma,tag", "other" })
end

T["ambiguity"]["a tag holding a comma and a space cannot be told from two"] = function()
  -- This one genuinely cannot be recovered: a tag named `a, b` prints inside
  -- `[a, b, c]`, which is what three tags look like. Measured, and it costs
  -- nothing — asking for `a, b` matched no task, because `--tags` splits its own
  -- argument on commas. What is unrecoverable here is unusable there.
  eq(listing.tags(listed(play("all", "", "a, b, c"))), { "a", "b", "c" })
end

-- ---------------------------------------------------------------------------
-- Unrecognised lines

T["unrecognised lines"] = new_set()

T["unrecognised lines"]["are ignored rather than fatal"] = function()
  -- The opposite of `graph.lua`, and deliberate: §8.1 already promises the tags
  -- Ansible *reported* rather than all of them, so an unreadable line changes
  -- nothing about what the list claims. A half-read inventory tree, by
  -- contrast, looks exactly like a small inventory.
  local output = listed("[WARNING]: Could not match supplied host pattern\n" .. play("all", "", "common"))

  eq(listing.tags(output), { "common" })
end

T["unrecognised lines"]["do not stop the plays after them"] = function()
  local output = listed(play("web", "", "deploy") .. "some line from a callback plugin\n" .. play("db", "", "backup"))

  eq(listing.tags(output), { "deploy", "backup" })
end

return T
