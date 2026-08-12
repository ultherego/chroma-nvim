-- What `ansible-playbook --list-tags` and `--list-hosts` printed, read back.
--
-- The second parser for somebody else's text, and it touches nothing: handed
-- the exact stdout of one subprocess, it answers with names. It starts no
-- process, reads no file and knows no Ansible semantics beyond the shape of
-- this output. The rules are `doc/chroma-ansible-design.md`, section 8.
--
-- It is a module of its own for the same reason `graph.lua` is: a parser that
-- can be handed a string and asked what it means is a parser that can be
-- tested against captured output, and `inspect.lua` is about processes.
-- §17.1's file list predates it and does not name it.
--
-- Measured against ansible-core 2.21.2:
--
--     playbook: plays/site_upgrade.yml
--
--       play #1 (webservers): webservers	TAGS: [common]
--           TASK TAGS: [common, site_upgrade, packages, security]
--
-- Four properties of that output decide the code below.
--
-- **Only the `TASK TAGS` line is read.** A play's own tags reach it: a play
-- tagged `common` whose tasks carry other tags lists `common` among them, and
-- so does a play with tags and no tasks at all. Reading the play line as well
-- would add nothing and would add a way to be lied to — a play *name* may
-- contain a tab, and `name: "deploy\tTAGS: [injected]"` prints a field that
-- looks exactly like the real one.
--
-- **That line cannot be forged.** A newline inside a play name is flattened to
-- a space before printing, so nothing a playbook contains can produce a second
-- line at this indentation.
--
-- **Names are split on `", "` and never trimmed.** Ansible joins with a comma
-- and a space, and a tag's own spaces are part of it: `[ leading, trailing ]`
-- is two tags, one starting with a space and one ending with one. Trimming
-- would rename both.
--
-- **A tag containing `", "` is therefore unrecoverable, and that costs
-- nothing.** A tag named `a, b` prints inside `[a, b, c]`, which is exactly
-- what three tags look like. It also cannot be asked for: `--tags` splits its
-- own argument on commas, and requesting `a, b` matched no task. The same
-- measurement clears the narrower case — a tag named `comma,tag` survives the
-- split intact, and is equally unselectable. What this parser cannot recover is
-- a name Ansible would not accept back.
--
-- Unrecognised lines are ignored rather than fatal, which is the opposite of
-- `graph.lua` and deliberate. A partial inventory tree looks like a small
-- inventory and misleads; a partial tag list is what §8.1 already promises —
-- the tags Ansible reported, never "all tags" — and `Custom tag…` is always
-- there for the rest.

local M = {}

--- The line every play prints, at exactly this indentation. Anchored rather
--- than searched for: if a future ansible indents differently, the result is
--- "no tags line was found", which is reported, rather than a quiet half-read.
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
      -- Found, even when the play has none. Every play prints this line on a
      -- successful listing, including one with no tasks and no tags, so its
      -- complete absence means this is not the output that was asked for.
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
--- number of them. Measured on 2.21.2:
---
---     play #1 (webservers): webservers	TAGS: [common]
---       pattern: ['webservers']
---       hosts (2):
---         web02
---         web01
---
--- A play whose pattern matched nothing prints `hosts (0):` and no names.
local HOSTS = "^    hosts %((%d+)%):$"

--- One host, at the only indentation a host is printed at. The name is the rest
--- of the line: `host with space` is a real inventory answer, and taking the
--- next word instead would silently rename it — the same property `graph.lua`
--- is built around.
local HOST = "^      (.+)$"

---The hosts `--list-hosts` reported, deduplicated, in the order it named them.
---
---Unlike the tag listing, this one is all or nothing. §9.4 shows the operator a
---count, and a count assembled from a listing that was only partly understood
---is a wrong number wearing the authority of Ansible's own answer. Reporting
---nothing is honest and §16 allows it; reporting three of four is not.
---
---A host addressed by two plays is one target. Ansible prints it under each
---play, because each play really does address it, but the question the preview
---asks is which machines this run reaches.
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
      -- The block ended: anything that is not a host closes it — a blank line,
      -- the next play's header, a warning a callback plugin wrote. Its promise
      -- is checked here rather than at the next header, so a listing that stops
      -- after the block is checked too.
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
    -- Ansible said how many it found; this parser found a different number. One
    -- of the two is wrong about the output, and it is not Ansible.
    return nil, "the target listing did not name as many hosts as it reported"
  end

  return hosts, nil
end

return M
