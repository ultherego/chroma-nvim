-- yamlls override, merged over nvim-lspconfig's, which already disables Red Hat
-- telemetry and enables formatting. What this adds is schemas.
--
-- Two sources, and the difference is the component boundary: the SchemaStore
-- catalogue recognises documents on its own and is Core, while "these paths
-- hold Kubernetes manifests" is Chroma's own decision and disappears with the
-- component that makes it. See lua/chroma/schemas.lua.

return {
  settings = {
    yaml = {
      -- The server's own fetch, off in favour of the SchemaStore.nvim
      -- catalogue, which that plugin keeps current.
      schemaStore = {
        enable = false,
        url = "",
      },
      schemas = vim.tbl_extend("force", require("schemastore").yaml.schemas(), require("chroma.schemas").yaml()),
      -- Kubernetes and Ansible both rely on conventional key order
      -- (apiVersion, kind, metadata, spec), so alphabetical ordering stays off.
      keyOrdering = false,
    },
  },
}
