-- Whether Neovim's trust database authorises this project's task definitions.
-- Five states, of which only `trusted` returns bytes; `denied` skips Neovim
-- entirely, since it would return nil and ask nothing.
--
-- **One snapshot is authoritative, and it is this one.** Hashing a file and
-- letting `vim.secure.read()` read it again leaves a window in which a trusted
-- answer authorises one byte string and hands back another. See DECISIONS.md.
--
-- Measured on 0.12.4: the database is `$XDG_STATE_HOME/nvim/trust`, one entry
-- per line as a token, a space and the path; a decision is a `sha256` of the
-- exact bytes and a denial is `!`.

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
---Binary and whole: `readfile()` gives lines, and rejoining them is a second
---representation that can differ in line endings and in the final newline.
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
---one. A missing database means nobody has decided anything yet, which is
---"untrusted"; one that does not parse is a different answer, because guessing
---at it means guessing at a security state.
---
---The path is the rest of the line rather than the next word: a directory with
---a space in its name is somebody's ordinary Documents folder, and splitting on
---whitespace would answer confidently about the wrong file.
---@param token string
---@return boolean
local function recognised(token)
  -- The two tokens Neovim writes: a denial, or the `sha256` of the contents
  -- the decision was taken for.
  return token == "!"
    or token:match(
        "^%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x$"
      )
      ~= nil
end

---@return table<string, string>|nil decisions, string|nil problem
local function decisions()
  local path = database()

  -- "Nobody has decided yet" and "I could not read the decisions" are two
  -- answers and only the first is untrusted. `lstat` first: a trust database
  -- that is a broken symlink exists, and reading a failed open as absence
  -- downgrades an unreadable security state. Neovim's own reader treats them
  -- alike, which is why this adapter exists.
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

  -- One read, then split: reading a directory opens without complaint and
  -- fails at the read (measured on 0.12.4).
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
---it is going to appear — the modal says "exrc: Found untrusted code", which
---names a feature nobody asked for. The wording is the caller's; the ordering
---is here, so nothing announces a question that is not coming.
---@param source chroma.tasks.Source
---@param explain fun(path: string)|nil
---@return chroma.tasks.Decision
function M.consult(source, explain)
  -- Resolved again, now: a symlink can be pointed elsewhere between discovery
  -- and here, and the decision has to be about the file this call is looking at.
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

  -- Nothing is remembered between calls: `:trust` between two Run Tasks has to
  -- be visible to the second, and so does an edit that invalidates a decision.
  local recorded, problem = decisions()
  if not recorded then
    return { state = "unknown", path = path, problem = problem }
  end

  local decision = recorded[path]

  -- Other files' entries are none of Chroma's business; its own has to be
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
    -- would announce a question that never appears.
    return { state = "denied", path = path }
  end

  if decision == vim.fn.sha256(bytes) then
    return { state = "trusted", path = path, bytes = bytes }
  end

  -- No decision, or one taken for contents that have changed since. Both are
  -- Neovim's question to ask.
  if explain then
    explain(path)
  end
  vim.secure.read(path)

  return { state = "untrusted", path = path }
end

return M
