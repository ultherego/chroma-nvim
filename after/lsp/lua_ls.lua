-- lua_ls override, merged over nvim-lspconfig's (:help lsp-config-merge). Makes
-- the server aware of the Neovim runtime, so editing this config gets the vim
-- API instead of a wall of "undefined global vim". Upstream documents this
-- on_init in a comment but does not apply it.

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
        -- Only VIMRUNTIME: the whole runtimepath makes the server noticeably
        -- slower, which upstream calls out.
        library = { vim.env.VIMRUNTIME },
      },
    })
  end,
  settings = {
    Lua = {},
  },
}
