-- lua_ls override.
--
-- Loaded after nvim-lspconfig's lsp/lua_ls.lua and merged over it
-- (:help lsp-config-merge). Upstream documents this on_init in a comment but
-- does not apply it, so it is applied here.
--
-- Purpose: make the server aware of the Neovim runtime, so editing this config
-- gets completion and go-to-definition for the vim API instead of a wall of
-- "undefined global vim".

---@type vim.lsp.Config
return {
  on_init = function(client)
    -- A project with its own .luarc.json knows better; leave it alone.
    if client.workspace_folders then
      local path = client.workspace_folders[1].name
      if
        path ~= vim.fn.stdpath("config")
        and (vim.uv.fs_stat(path .. "/.luarc.json") or vim.uv.fs_stat(path .. "/.luarc.jsonc"))
      then
        return
      end
    end

    client.config.settings.Lua = vim.tbl_deep_extend("force", client.config.settings.Lua or {}, {
      runtime = {
        version = "LuaJIT",
        path = { "lua/?.lua", "lua/?/init.lua" },
      },
      workspace = {
        checkThirdParty = false,
        -- Only VIMRUNTIME, not the whole runtimepath: pulling in every
        -- installed plugin makes the server noticeably slower and is called
        -- out upstream as a problem when editing your own config.
        library = { vim.env.VIMRUNTIME },
      },
    })
  end,
  settings = {
    Lua = {},
  },
}
