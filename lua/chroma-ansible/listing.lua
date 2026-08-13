-- What `ansible-playbook --list-tags` and `--list-hosts` printed, read back:
-- handed the exact stdout of one subprocess, this answers with names. Its own
-- module for the same reason as `graph.lua` — a parser that can be handed a
-- string is a parser that can be tested. The rules are
-- `doc/chroma-ansible-design.md` §8.
--
-- Measured against ansible-core 2.21.2, and four properties of that output
-- decide the code below.
--
-- **Only the `TASK TAGS` line is read.** A play's own tags reach it anyway, and
-- reading the play line would add a way to be lied to: a play *name* may
-- contain a tab, so `name: "deploy\tTAGS: [injected]"` prints a field that
-- looks exactly like the real one. **That line cannot be forged**, because a
-- newline inside a play name is flattened to a space before printing.
--
-- **Names are split on `", "` and never trimmed**, since a tag's own spaces are
-- part of it: `[ leading, trailing ]` is two tags. **A tag containing `", "` is
-- therefore unrecoverable, and that costs nothing** — `--tags` splits its own
-- argument on commas, so such a tag cannot be asked for either.
--
-- Unrecognised lines are ignored rather than fatal, the opposite of
-- `graph.lua`: a partial tag list is what §8.1 already promises, and
-- `Custom tag…` is always there for the rest.

local M = {}

--- The line every play prints, at exactly this indentation. Anchored rather
--- than searched for, so a future ansible that indents differently produces
--- "no tags line was found" rather than a quiet half-read.
local TASK_TAGS = "^      TASK TAGS: %[(.*)%]$"

--- What Ansible joins names with.
local BETWEEN = ", "

---The tags `--list-tags` reported, in the order it reported them.
---
---@param output string the exact stdout of `ansible-playbook --list-tags`
---@return string[]|nil tags, string|nil problem
function M.tags(output)
  if type(output) ~= "string" then
    return nil, "tag inspection produced no output"
  end

  local tags, seen, found = {}, {}, false

  for _, line in ipairs(vim.split(output, "\n", { plain = true })) do
    local listed = line:match(TASK_TAGS)
    if listed then
      -- Every play prints this line on a successful listing, including one
      -- with no tasks and no tags, so its complete absence means this is not
      -- the output that was asked for.
      found = true

      if listed ~= "" then
        for _, tag in ipairs(vim.split(listed, BETWEEN, { plain = true })) do
          if not seen[tag] then
            seen[tag] = true
            table.insert(tags, tag)
          end
        end
      end
    end
  end

  if not found then
    return nil, "the tag listing named no plays, so the output could not be read"
  end

  return tags, nil
end

--- The header every play prints before the hosts it addresses, carrying the
--- number of them. Measured on 2.21.2, a play whose pattern matched nothing
--- prints `hosts (0):` and no names.
local HOSTS = "^    hosts %((%d+)%):$"

--- One host, at the only indentation a host is printed at. The name is the rest
--- of the line: `host with space` is a real inventory answer.
local HOST = "^      (.+)$"

---The hosts `--list-hosts` reported, deduplicated, in the order it named them.
---
---All or nothing, unlike the tag listing: §9.4 shows a count, and a count
---assembled from a listing only partly understood is a wrong number wearing
---Ansible's authority. A host addressed by two plays is one target.
---@param output string the exact stdout of `ansible-playbook --list-hosts`
---@return string[]|nil hosts, string|nil problem
function M.targets(output)
  if type(output) ~= "string" then
    return nil, "target inspection produced no output"
  end

  local hosts, seen, plays = {}, {}, 0
  local expected, counted = nil, 0

  ---Whether the play just finished named as many hosts as it promised.
  ---@return boolean
  local function play_agreed()
    return expected == nil or expected == counted
  end

  for _, line in ipairs(vim.split(output, "\n", { plain = true })) do
    local promised = line:match(HOSTS)
    local host = expected and line:match(HOST) or nil

    if promised then
      if not play_agreed() then
        break
      end
      plays = plays + 1
      expected, counted = tonumber(promised), 0
    elseif host then
      counted = counted + 1
      if not seen[host] then
        seen[host] = true
        table.insert(hosts, host)
      end
    elseif expected then
      -- Anything that is not a host closes the block — a blank line, the next
      -- header, a warning a callback wrote. Checked here rather than at the
      -- next header, so a listing that stops after the block is checked too.
      if expected ~= counted then
        break
      end
      expected = nil
    end
  end

  if plays == 0 then
    return nil, "the target listing named no plays, so the output could not be read"
  end
  if not play_agreed() then
    -- Ansible said how many it found and this parser found a different number.
    -- One of the two is wrong about the output, and it is not Ansible.
    return nil, "the target listing did not name as many hosts as it reported"
  end

  return hosts, nil
end

return M
