-- File operations whose failures this plugin has to see.
--
-- The synchronous libuv calls report ordinary failures by returning `nil, err`
-- rather than raising, so `pcall` around one of them is not error handling: it
-- answers true whether or not the call did anything.

local M = {}

---Removes a file and says whether it is gone.
---@param path string
---@return boolean removed, string|nil err
function M.unlink_checked(path)
  local ok, err = vim.uv.fs_unlink(path)
  if ok then
    return true
  end

  -- Already gone is what this was for.
  if not vim.uv.fs_stat(path) then
    return true
  end

  return false, err or "unlink failed"
end

return M
