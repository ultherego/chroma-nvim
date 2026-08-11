-- Consulting Neovim's trust database about a project's task file.
--
-- Two things are measured here that are easy to get right by accident and
-- wrong for good: which bytes a "trusted" answer authorises, and how often
-- Neovim's own trust question is put on screen. The second is counted rather
-- than described, because "we never call it for a denied file" is the kind of
-- claim that stays true only until somebody moves a line.

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local trust = require("chroma.tasks.trust")

local DOCUMENT = [[{ "schema": 1, "tasks": [] }]]

local saved = {}
local asked = {}

---A project with a task file in it, and the source discovery would produce.
---@param root string|nil
---@return table source, string path
local function project(root)
  root = root or vim.fn.tempname()
  vim.fn.mkdir(vim.fs.joinpath(root, ".chroma"), "p")

  local path = vim.fs.joinpath(root, ".chroma", "tasks.json")
  vim.fn.writefile({ DOCUMENT }, path)

  return { root = root, path = path, resolved = vim.uv.fs_realpath(path) }, path
end

---Writes the trust database verbatim.
---@param lines string[]
local function database(lines)
  local dir = vim.fs.joinpath(vim.fn.stdpath("state"))
  vim.fn.mkdir(dir, "p")
  vim.fn.writefile(lines, vim.fs.joinpath(dir, "trust"))
end

---The hash Neovim would record for a file: sha256 of its exact bytes.
---@param path string
---@return string
local function hashed(path)
  local file = assert(io.open(path, "rb"))
  local bytes = file:read("*a")
  file:close()
  return vim.fn.sha256(bytes)
end

local T = new_set({
  hooks = {
    pre_case = function()
      -- A throwaway state directory, so no case reads or writes the trust
      -- decisions of whoever is running the suite.
      saved.state = vim.env.XDG_STATE_HOME
      vim.env.XDG_STATE_HOME = vim.fn.tempname()

      asked = {}
      saved.read = vim.secure.read
      vim.secure.read = function(path)
        table.insert(asked, path)
        return nil
      end
    end,
    post_case = function()
      vim.env.XDG_STATE_HOME = saved.state
      vim.secure.read = saved.read
    end,
  },
})

-- ---------------------------------------------------------------------------
-- The four answers

T["states"] = new_set()

T["states"]["a file whose hash matches its decision is trusted"] = function()
  local source, path = project()
  database({ ("%s %s"):format(hashed(path), vim.uv.fs_realpath(path)) })

  local decision = trust.consult(source)

  eq(decision.state, "trusted")
  eq(decision.bytes, DOCUMENT .. "\n")
  eq(asked, {})
end

T["states"]["a file nobody has decided on is untrusted, and Neovim is asked once"] = function()
  local source, path = project()

  local decision = trust.consult(source)

  eq(decision.state, "untrusted")
  eq(decision.bytes, nil)
  eq(asked, { vim.uv.fs_realpath(path) })
end

T["states"]["a database that does not exist means untrusted, not unknown"] = function()
  -- Nobody has decided anything yet. That is the ordinary first run, and
  -- reporting it as a broken trust database would be alarming and wrong.
  local source = project()

  eq(trust.consult(source).state, "untrusted")
end

T["states"]["a database with no entry for this path is untrusted"] = function()
  local source = project()
  database({ ("%s /somewhere/else/tasks.json"):format(("a"):rep(64)) })

  eq(trust.consult(source).state, "untrusted")
end

T["states"]["a decision taken for different contents is untrusted"] = function()
  -- The case a `!`-only parser gets wrong: the path is in the database, so it
  -- looks decided, but the hash belongs to a file that has since been edited.
  local source, path = project()
  database({ ("%s %s"):format(hashed(path), vim.uv.fs_realpath(path)) })
  vim.fn.writefile({ DOCUMENT, "" }, path)

  local decision = trust.consult(source)

  eq(decision.state, "untrusted")
  eq(#asked, 1)
end

T["states"]["a denied file is denied, and Neovim is not asked"] = function()
  -- Neovim would see the same `!`, return nil and ask nothing, so calling it
  -- would announce a question that never appears.
  local source, path = project()
  database({ ("! %s"):format(vim.uv.fs_realpath(path)) })

  local decision = trust.consult(source)

  eq(decision.state, "denied")
  eq(decision.bytes, nil)
  eq(asked, {})
end

T["states"]["a database whose lines are not decisions is unknown, and asks nothing"] = function()
  local source = project()
  database({ "nonsense" })

  local decision = trust.consult(source)

  eq(decision.state, "unknown")
  eq(asked, {})
  eq(decision.problem ~= nil, true)
end

T["states"]["a decision in a token Chroma does not recognise is unknown"] = function()
  -- The database belongs to Neovim, and a Chroma that reads a token it does
  -- not know and carries on has guessed at a security state. Other files'
  -- entries are none of its business; its own has to be understood.
  local source, path = project()
  database({ ("maybe %s"):format(vim.uv.fs_realpath(path)) })

  local decision = trust.consult(source)

  eq(decision.state, "unknown")
  eq(asked, {})
end

T["states"]["another file's unrecognised entry is not this file's problem"] = function()
  local source, path = project()
  database({
    "maybe /somewhere/else/tasks.json",
    ("%s %s"):format(hashed(path), vim.uv.fs_realpath(path)),
  })

  eq(trust.consult(source).state, "trusted")
end

-- ---------------------------------------------------------------------------
-- The snapshot

T["snapshot"] = new_set()

T["snapshot"]["authorises the bytes it hashed, not a second reading"] = function()
  -- The whole reason the trusted branch never calls `vim.secure.read()`: the
  -- file can change between two readings, and a trusted answer that hands back
  -- the later one has authorised bytes nobody decided about.
  local source, path = project()
  database({ ("%s %s"):format(hashed(path), vim.uv.fs_realpath(path)) })

  local decision = trust.consult(source)

  eq(decision.state, "trusted")
  eq(vim.fn.sha256(decision.bytes), hashed(path))
end

T["snapshot"]["hands back the first reading when the file changes under it"] = function()
  -- The window the whole rule exists for, forced open: the file is rewritten
  -- between the byte snapshot and anything that might read it again. Whatever
  -- else happens, what comes back is what was hashed and authorised — a second
  -- reading would return contents nobody decided about.
  local source, path = project()
  database({ ("%s %s"):format(hashed(path), vim.uv.fs_realpath(path)) })

  local original = DOCUMENT .. "\n"

  -- The edit is hung on the hash, because that is the one moment guaranteed to
  -- fall between the snapshot and anything the adapter returns. From here on,
  -- every reading of this file gives `{}`.
  local real_sha256 = vim.fn.sha256
  local hashes = 0
  vim.fn.sha256 = function(bytes)
    hashes = hashes + 1
    if hashes == 1 then
      vim.fn.writefile({ "{}" }, path)
    end
    return real_sha256(bytes)
  end

  local ok, decision = pcall(trust.consult, source)
  vim.fn.sha256 = real_sha256

  eq(ok, true)
  eq(decision.state, "trusted")
  eq(decision.bytes, original)
end

T["snapshot"]["reads bytes rather than lines"] = function()
  -- A file with CRLF endings and no final newline hashes to something a
  -- line-based read would never produce, and Neovim recorded the byte hash.
  local source, path = project()
  local file = assert(io.open(path, "wb"))
  file:write('{ "schema": 1,\r\n  "tasks": [] }')
  file:close()

  database({ ("%s %s"):format(hashed(path), vim.uv.fs_realpath(path)) })
  local decision = trust.consult(source)

  eq(decision.state, "trusted")
  eq(decision.bytes, '{ "schema": 1,\r\n  "tasks": [] }')
end

T["snapshot"]["keeps a path that has a space in it"] = function()
  -- `token + space + rest of the line`, not two words: somebody's project
  -- under "My Documents" must not be read as a decision about "My".
  local root = vim.fs.joinpath(vim.fn.tempname(), "My Infrastructure")
  local source, path = project(root)
  database({ ("%s %s"):format(hashed(path), vim.uv.fs_realpath(path)) })

  eq(trust.consult(source).state, "trusted")
end

-- ---------------------------------------------------------------------------
-- What changed since discovery looked

T["after discovery"] = new_set()

T["after discovery"]["refuses a file that has gone, without looking elsewhere"] = function()
  local source, path = project()
  vim.fn.delete(path)

  local decision = trust.consult(source)

  eq(decision.state, "refused")
  eq(asked, {})
end

T["after discovery"]["refuses when the path is no longer a file"] = function()
  local source, path = project()
  vim.fn.delete(path)
  vim.fn.mkdir(path, "p")

  eq(trust.consult(source).state, "refused")
end

T["after discovery"]["decides about the file the symlink points at now"] = function()
  -- Discovery resolved the link when it looked. If it has been pointed
  -- somewhere else since, the decision must be about the new target, not the
  -- identity that was authorised for the old one.
  local root = vim.fn.tempname()
  vim.fn.mkdir(vim.fs.joinpath(root, ".chroma"), "p")

  local first = vim.fs.joinpath(root, "first.json")
  local second = vim.fs.joinpath(root, "second.json")
  vim.fn.writefile({ DOCUMENT }, first)
  vim.fn.writefile({ DOCUMENT, "" }, second)

  local link = vim.fs.joinpath(root, ".chroma", "tasks.json")
  eq(vim.uv.fs_symlink(first, link), true)

  local source = { root = root, path = link, resolved = vim.uv.fs_realpath(link) }
  database({ ("%s %s"):format(hashed(first), vim.uv.fs_realpath(first)) })
  eq(trust.consult(source).state, "trusted")

  vim.fn.delete(link)
  eq(vim.uv.fs_symlink(second, link), true)

  local decision = trust.consult(source)

  eq(decision.state, "untrusted")
  eq(decision.path, vim.uv.fs_realpath(second))
end

-- ---------------------------------------------------------------------------
-- What it remembers

T["remembering"] = new_set()

T["remembering"]["sees a decision taken since the last call"] = function()
  local source, path = project()

  eq(trust.consult(source).state, "untrusted")

  database({ ("%s %s"):format(hashed(path), vim.uv.fs_realpath(path)) })

  eq(trust.consult(source).state, "trusted")
end

T["remembering"]["sees an edit that invalidates a decision"] = function()
  local source, path = project()
  database({ ("%s %s"):format(hashed(path), vim.uv.fs_realpath(path)) })

  eq(trust.consult(source).state, "trusted")

  vim.fn.writefile({ DOCUMENT, "-- changed" }, path)

  eq(trust.consult(source).state, "untrusted")
end

-- ---------------------------------------------------------------------------
-- The explanation

T["explanation"] = new_set()

T["explanation"]["comes immediately before the modal, and only then"] = function()
  local source = project()
  local order = {}

  local real = vim.secure.read
  vim.secure.read = function(path)
    table.insert(order, "modal")
    return real(path)
  end

  trust.consult(source, function()
    table.insert(order, "explanation")
  end)

  vim.secure.read = real
  eq(order, { "explanation", "modal" })
end

T["explanation"]["is not given when no modal is coming"] = function()
  local source, path = project()
  database({ ("! %s"):format(vim.uv.fs_realpath(path)) })

  local explained = false
  trust.consult(source, function()
    explained = true
  end)

  eq(explained, false)
end

return T
