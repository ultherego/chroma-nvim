-- Whether project tasks can run on this Neovim, and why not.
--
-- One answer in one place, because two things ask it: `:checkhealth chroma`,
-- which says so before anybody tries, and Run Task, which refuses. A floor
-- copied into both is a floor that can be raised in one of them.
--
-- Chroma's own floor is 0.12 and stays there. This is the only feature that
-- asks for more, and it asks because it is the only one that puts Neovim's
-- trust prompt on screen: `vim.secure.read()` reaches the `view` path whose
-- command-injection fix landed upstream in 799cbfff8 (2026-05-20). Checked at
-- each release: absent from v0.12.0, v0.12.1 and v0.12.2, present from v0.12.3.
-- A security boundary is not built on an implementation without the fix.

local M = {}

--- The Neovim project tasks need.
M.FLOOR = { 0, 12, 3 }

---Which Neovim this is. A variable because a test cannot be several of them,
---and the whole value of this module is what it says on the ones it is not
---running on.
---@type fun(): table
M.version = vim.version

---@return boolean
function M.available()
  -- `vim.version.ge`, not a comparison of strings or of major and minor: 0.12.10
  -- is newer than 0.12.3 and no textual ordering agrees, and a prerelease of the
  -- floor is below it, which is what semver says and the honest answer — the fix
  -- may or may not be in that build.
  return vim.version.ge(M.version(), M.FLOOR)
end

---Why not, in two parts: the sentence, and what stands behind it.
---
---The second half is not decoration. A version floor with no argument behind it
---reads as an arbitrary demand to upgrade, and this one is a security fix that
---can be looked up.
---@return string summary, string advice
function M.reason()
  return ("Project tasks need Neovim 0.12.3 or newer, and this is %s"):format(M.version()),
    "They are the only part of Chroma that puts Neovim's trust prompt on screen, and it "
      .. "reaches `vim.secure.read()`, whose command-injection fix (upstream 799cbfff8, "
      .. "2026-05-20) is absent from 0.12.0 to 0.12.2 and present from 0.12.3. Everything "
      .. "else in Chroma works on this version."
end

return M
