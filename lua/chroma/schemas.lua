-- The schema registry: what a component means when it names a schema.
--
-- `components/*.json` carries logical names — `"schemas": ["kubernetes"]` — and
-- nothing else. This file knows which document that is, where it lives and
-- which files it applies to. The same split as `cli/internal/toolver`, and for
-- the same reason: the contract says what, an implementation registry knows
-- how, and a product contract that a web page or a different editor is also
-- meant to read does not fill up with one language server's settings shape.
--
-- What belongs here is narrow. This is for mappings Chroma adds deliberately —
-- "these paths hold Kubernetes manifests". It is not a filter over what
-- SchemaStore can recognise on its own: a workflow file matching the GitHub
-- Actions schema from the shared catalogue is core YAML support doing its job,
-- and switching the github-actions component off does not make it Chroma's
-- business to prevent that.

local M = {}

--- Every schema a component may name, and how to resolve it. Each entry is a
--- function because some of them read a setting that can change while Neovim is
--- running.
---@type table<string, fun(): { url: string, files: string[] }>
M.KNOWN = {
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
  --   vim.g.chroma_k8s_version = "v1.31.4"
  --
  -- For a repository that must match one exact version, a modeline at the top
  -- of the file still wins over everything here:
  --   # yaml-language-server: $schema=<url>
  kubernetes = function()
    local version = vim.g.chroma_k8s_version or "v1.34.10"
    return {
      url = ("https://raw.githubusercontent.com/yannh/kubernetes-json-schema/master/%s-standalone-strict/all.json"):format(
        version
      ),
      -- Both extensions: .yml is at least as common as .yaml for Kubernetes
      -- manifests, and an earlier version of this list silently covered only
      -- half of them.
      files = {
        "k8s/**/*.yaml",
        "k8s/**/*.yml",
        "kubernetes/**/*.yaml",
        "kubernetes/**/*.yml",
        "manifests/**/*.yaml",
        "manifests/**/*.yml",
        "**/*.k8s.yaml",
        "**/*.k8s.yml",
      },
    }
  end,
}

---The explicit mappings the enabled components ask for, in the shape
---yaml-language-server takes: url to file patterns.
---
---A name with no entry here is dropped rather than guessed at. It cannot happen
---in a shipped tree — a test walks every component and refuses one this does
---not know — so the only way to reach it is a component file from somewhere
---else, and inventing a URL for it would be worse than ignoring it.
---@param enabled string[]|nil component ids; defaults to what is enabled now
---@return table<string, string[]>
function M.yaml(enabled)
  enabled = enabled or require("chroma.state").enabled_ids()

  local mapped = {}
  for _, name in ipairs(require("chroma.components").contributions("schemas", enabled)) do
    local resolve = M.KNOWN[name]
    if resolve then
      local schema = resolve()
      mapped[schema.url] = schema.files
    end
  end

  return mapped
end

return M
