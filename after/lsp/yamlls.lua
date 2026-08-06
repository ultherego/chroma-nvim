-- yamlls override.
--
-- Merged over nvim-lspconfig's lsp/yamlls.lua, which already disables Red Hat
-- telemetry and enables formatting — neither is repeated here.
--
-- What this adds is schemas. Without them YAML editing is just a syntax check;
-- with them, GitHub Actions workflows, docker-compose files, Ansible metadata
-- and Kubernetes manifests get completion and validation against the real
-- specification.

-- Kubernetes is special-cased by yaml-language-server and is not part of the
-- SchemaStore catalogue, so it is mapped explicitly. It is deliberately NOT
-- applied to every *.yaml file: Ansible playbooks and CI pipelines are valid
-- YAML that does not match the Kubernetes schema, and would light up with
-- false errors.
local k8s = "https://raw.githubusercontent.com/yannh/kubernetes-json-schema/master/master-standalone-strict/all.json"

return {
  settings = {
    yaml = {
      -- The server's own SchemaStore fetch is switched off in favour of the
      -- SchemaStore.nvim catalogue, which is kept current by that plugin.
      schemaStore = {
        enable = false,
        url = "",
      },
      schemas = vim.tbl_extend("force", require("schemastore").yaml.schemas(), {
        [k8s] = {
          "k8s/**/*.yaml",
          "kubernetes/**/*.yaml",
          "manifests/**/*.yaml",
          "*.k8s.yaml",
        },
      }),
      -- yaml-language-server can enforce alphabetical key order. Kubernetes
      -- and Ansible both rely on conventional key order (apiVersion, kind,
      -- metadata, spec), so this stays off.
      keyOrdering = false,
    },
  },
}
