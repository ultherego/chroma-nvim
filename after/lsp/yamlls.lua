-- yamlls override.
--
-- Merged over nvim-lspconfig's lsp/yamlls.lua, which already disables Red Hat
-- telemetry and enables formatting — neither is repeated here.
--
-- What this adds is schemas. Without them YAML editing is just a syntax check;
-- with them, GitHub Actions workflows, docker-compose files, Ansible metadata
-- and Kubernetes manifests get completion and validation against the real
-- specification.
--
-- Two sources, and the difference between them is the component boundary. The
-- SchemaStore catalogue is a Core capability: it recognises documents on its
-- own, and a component being switched off is not a reason to make yamlls
-- pretend it cannot read a compose file. The explicit mappings are Chroma's
-- own — "these paths hold Kubernetes manifests" is a decision this
-- configuration makes, so it belongs to the component that makes it and
-- disappears with it. See lua/chroma/schemas.lua.

return {
  settings = {
    yaml = {
      -- The server's own SchemaStore fetch is switched off in favour of the
      -- SchemaStore.nvim catalogue, which is kept current by that plugin.
      schemaStore = {
        enable = false,
        url = "",
      },
      schemas = vim.tbl_extend("force", require("schemastore").yaml.schemas(), require("chroma.schemas").yaml()),
      -- yaml-language-server can enforce alphabetical key order. Kubernetes
      -- and Ansible both rely on conventional key order (apiVersion, kind,
      -- metadata, spec), so this stays off.
      keyOrdering = false,
    },
  },
}
