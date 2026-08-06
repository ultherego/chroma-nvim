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
--
-- The schema is pinned to a Kubernetes version rather than following the
-- repository's rolling `master-standalone-strict`. Validating against
-- whatever the schema repository happened to publish today means the
-- diagnostics need not correspond to the cluster being deployed to — a field
-- can be flagged as unknown because it is newer than the pin, or accepted
-- because it is newer than the cluster.
--
-- Override per machine in init.lua, or per project, when the cluster differs:
--   vim.g.devops_k8s_version = "v1.31.4"
--
-- For a repository that must match one exact version, a modeline at the top
-- of the file still wins over everything here:
--   # yaml-language-server: $schema=<url>
local k8s_version = vim.g.devops_k8s_version or "v1.34.10"
local k8s = ("https://raw.githubusercontent.com/yannh/kubernetes-json-schema/master/%s-standalone-strict/all.json"):format(
  k8s_version
)

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
        -- Both extensions: .yml is at least as common as .yaml for Kubernetes
        -- manifests, and an earlier version of this list silently covered only
        -- half of them.
        [k8s] = {
          "k8s/**/*.yaml",
          "k8s/**/*.yml",
          "kubernetes/**/*.yaml",
          "kubernetes/**/*.yml",
          "manifests/**/*.yaml",
          "manifests/**/*.yml",
          "**/*.k8s.yaml",
          "**/*.k8s.yml",
        },
      }),
      -- yaml-language-server can enforce alphabetical key order. Kubernetes
      -- and Ansible both rely on conventional key order (apiVersion, kind,
      -- metadata, spec), so this stays off.
      keyOrdering = false,
    },
  },
}
