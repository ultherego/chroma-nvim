-- Whether project tasks can run on this Neovim, in one place because
-- `:checkhealth` and Run Task both ask.
--
-- Chroma's own floor is 0.12. This asks for more because it is the only feature
-- that puts Neovim's trust prompt on screen, and `vim.secure.read()` reaches
-- the `view` path whose command-injection fix landed in 799cbfff8 (2026-05-20)
-- — checked at each release, absent up to v0.12.2, present from v0.12.3.

local M = {}

--- The Neovim project tasks need.
M.FLOOR = { 0, 12, 3 }

---A variable because a test cannot be several Neovims, and what this says on
---the versions it is not running on is the whole point of it.
---@type fun(): table
M.version = vim.version

---@return boolean
function M.available()
  -- Not string or major/minor comparison: 0.12.10 is newer than 0.12.3 and no
  -- textual ordering agrees. A prerelease of the floor is below it, which is
  -- semver and also honest — the fix may or may not be in that build.
  return vim.version.ge(M.version(), M.FLOOR)
end

---Why not, in two parts: the sentence, and the argument behind it. A floor with
---no argument reads as an arbitrary demand to upgrade.
---@return string summary, string advice
function M.reason()
  return ("Project tasks need Neovim 0.12.3 or newer, and this is %s"):format(M.version()),
    "They are the only part of Chroma that puts Neovim's trust prompt on screen, and it "
      .. "reaches `vim.secure.read()`, whose command-injection fix (upstream 799cbfff8, "
      .. "2026-05-20) is absent from 0.12.0 to 0.12.2 and present from 0.12.3. Everything "
      .. "else in Chroma works on this version."
end

return M
