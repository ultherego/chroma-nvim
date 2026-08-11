-- Whether Neovim's trust database authorises this project's task definitions.
--
-- The security boundary of the task runner is here, and it is narrower than it
-- looks: this module decides nothing about tasks, runs nothing, and reads no
-- file except the one discovery pointed at and Neovim's own trust database.
-- What it produces is a state and, in exactly one of those states, the bytes
-- that were authorised.
--
--     trusted     the file hashes to the decision recorded for it;
--                 its exact bytes come back, and Neovim is not consulted
--     untrusted   no decision, or one for different contents; Neovim's own
--                 question is put on screen and nothing is loaded this time
--     denied      somebody chose deny; Neovim would return nil and ask
--                 nothing, so it is not called at all
--     unknown     the trust database could not be understood
--     refused     the file discovery found is no longer usable
--
-- **One snapshot is authoritative, and it is this one.** Hashing a file and
-- then letting `vim.secure.read()` read it again leaves a window in which the
-- contents change between the two, so a trusted answer would authorise one
-- byte string and hand back another. The bytes hashed, the bytes authorised
-- and the bytes parsed are the same bytes — see concept.md §4.
--
-- Measured on Neovim 0.12.4, `runtime/lua/vim/secure.lua`: the database is
-- `$XDG_STATE_HOME/nvim/trust`, one entry per line as a token, a space and the
-- path; a file's decision is a `sha256` of its exact bytes, and a denial is
-- the token `!`. For a file the prompt offers ignore, view and deny — there is
-- no allow — so trusting one means viewing it and running `:trust`, and this
-- module's part in that is to call `read()` once and load nothing.

local M = {}

--- What a consultation answers with.
---@class chroma.tasks.Decision
---@field state "trusted"|"untrusted"|"denied"|"unknown"|"refused"
---@field path string the path the decision is about, with symlinks resolved
---@field bytes string|nil the authorised snapshot, and only when trusted
---@field problem string|nil why, when the state is refused or unknown

---Where Neovim keeps its decisions.
---@return string
local function database()
  return vim.fs.joinpath(vim.fn.stdpath("state"), "trust")
end

---The exact bytes of a file, read the way Neovim reads them to hash them.
---
---Binary, and whole. `readfile()` would give lines, and joining lines is a
---second representation of the file: it can differ in its line endings and in
---whether a final newline survives, and then this module would be hashing
---something other than what the trust database recorded.
---@param path string
---@return string|nil bytes
local function contents(path)
  local file = io.open(path, "rb")
  if not file then
    return nil
  end
  local bytes = file:read("*a")
  file:close()
  return bytes
end

---Every decision Neovim has recorded, or nil when the file cannot be read as
---one.
---
---A missing database is not a problem: it means nobody has decided anything
---yet, which is exactly "untrusted". A database that exists and does not parse
---is a different answer, because guessing at it would mean guessing at a
---security state.
---
---Each line is a token, a space, and the rest of the line. The path is the
---rest of the line rather than the next word: a project under a directory with
---a space in its name is somebody's ordinary Documents folder, and a parser
---that split on whitespace would read a different path and answer confidently
---about the wrong file.
---@param token string
---@return boolean
local function recognised(token)
  -- The two tokens Neovim writes: a denial, or the `sha256` of the contents
  -- the decision was taken for. Anything else is a format this does not
  -- understand, and understanding it badly is the one outcome worth avoiding.
  return token == "!"
    or token:match(
        "^%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x$"
      )
      ~= nil
end

---@return table<string, string>|nil decisions, string|nil problem
local function decisions()
  local path = database()

  -- "Nobody has decided anything yet" and "I could not read the decisions" are
  -- two answers, and only the first is untrusted. `lstat` first, as in
  -- discovery and for the same reason: a trust database that is a broken
  -- symlink exists, and treating a failed open as absence would quietly
  -- downgrade an unreadable security state to "not decided yet". Neovim's own
  -- reader does treat them alike — this adapter exists in order not to.
  local entry, failure, code = vim.uv.fs_lstat(path)
  if not entry then
    if code == "ENOENT" or code == "ENOTDIR" then
      return {}, nil
    end
    return nil, ("%s cannot be inspected: %s"):format(path, failure or code or "unknown filesystem error")
  end

  local file = io.open(path, "r")
  if not file then
    return nil, ("%s exists and cannot be opened"):format(path)
  end

  -- One read, then split. Reading a directory opens without complaint and
  -- fails at the read — measured on 0.12.4 — so the failure has an answer here
  -- rather than escaping from a line iterator part-way through.
  local blob = file:read("*a")
  file:close()
  if not blob then
    return nil, ("%s could not be read"):format(path)
  end

  local recorded = {}
  for line in vim.gsplit(blob, "\n") do
    if line ~= "" then
      local token, decided = line:match("^(%S+) (.+)$")
      if not token then
        return nil, ("%s could not be read"):format(path)
      end
      recorded[decided] = token
    end
  end

  return recorded, nil
end

---Consults the trust database about the task file discovery found.
---
---`explain` is called immediately before Neovim's modal appears, and only when
---it is going to appear. The wording belongs to the caller — the modal says
---"exrc: Found untrusted code", which names a feature nobody asked for — but
---the ordering belongs here, so that nothing can announce a question that is
---not coming.
---@param source chroma.tasks.Source
---@param explain fun(path: string)|nil
---@return chroma.tasks.Decision
function M.consult(source, explain)
  -- Resolved again, now. The path discovery reported was true when it looked,
  -- and a symlink can be pointed somewhere else between then and here; the
  -- decision has to be about the file this call is looking at.
  local path = vim.uv.fs_realpath(source.path)
  if not path then
    return { state = "refused", path = source.path, problem = ("%s is no longer there"):format(source.path) }
  end

  local entry = vim.uv.fs_stat(path)
  if not entry or entry.type ~= "file" then
    return {
      state = "refused",
      path = path,
      problem = ("%s is no longer a file"):format(source.path),
    }
  end

  local bytes = contents(path)
  if not bytes then
    return { state = "refused", path = path, problem = ("%s cannot be read"):format(source.path) }
  end

  -- Nothing is remembered between calls, for the same reason discovery
  -- remembers nothing: `:trust` between two Run Tasks has to be visible to the
  -- second one, and so does an edit that invalidates a decision.
  local recorded, problem = decisions()
  if not recorded then
    return { state = "unknown", path = path, problem = problem }
  end

  local decision = recorded[path]

  -- An entry about this file written in a token this does not recognise. Other
  -- files' entries are none of Chroma's business, but its own has to be
  -- understood or admitted to be ununderstood.
  if decision ~= nil and not recognised(decision) then
    return {
      state = "unknown",
      path = path,
      problem = ("%s records a decision for this file that Chroma does not understand"):format(database()),
    }
  end

  if decision == "!" then
    -- Neovim sees the same `!`, returns nil and asks nothing, so calling it
    -- here would announce a question that never appears.
    return { state = "denied", path = path }
  end

  if decision == vim.fn.sha256(bytes) then
    return { state = "trusted", path = path, bytes = bytes }
  end

  -- No decision, or one taken for contents that have changed since. Both are
  -- untrusted, and both are Neovim's question to ask.
  if explain then
    explain(path)
  end
  vim.secure.read(path)

  return { state = "untrusted", path = path }
end

return M
