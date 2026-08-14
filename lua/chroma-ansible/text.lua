-- Showing a value that may hold anything. A path is bytes, and a legal one can
-- carry a newline, a tab or a control byte; a screen where somebody decides
-- whether to run something must not let those draw a line nobody wrote.
--
-- Presentation only. What is escaped here is never what is compared, consented
-- to, or passed to a process — those are the raw bytes, everywhere.
--
-- Its own module rather than `chroma.tasks`': these modules stay liftable
-- (§15.5), and the same rule learned twice in one component is the rule
-- drifting.

local M = {}

---One visible line, whatever the bytes are. The backslash goes first, so a
---literal `\n` and a real newline are not shown identically.
---@param text string
---@return string
function M.visible(text)
  local escaped = text:gsub("[\\\n\r\t]", {
    ["\\"] = "\\\\",
    ["\n"] = "\\n",
    ["\r"] = "\\r",
    ["\t"] = "\\t",
  })
  return (escaped:gsub("%c", function(control)
    return ("\\x%02x"):format(control:byte())
  end))
end

return M
