-- What a component means when it names a schema. `components/*.json` carries
-- the logical name, this file knows the document, the URL and the paths — the
-- same split as `cli/internal/toolver`.
--
-- Only for mappings Chroma adds deliberately. It is not a filter over what
-- SchemaStore recognises on its own.

local M = {}

--- Every schema a component may name, and how to resolve it. Each entry is a
--- function because some of them read a setting that can change while Neovim is
--- running.
---@type table<string, fun(): { url: string, files: string[] }>
M.KNOWN = {
  -- Not part of the SchemaStore catalogue, so it is mapped explicitly, and
  -- deliberately not over every *.yaml: playbooks and pipelines are valid YAML
  -- that this schema would light up with false errors.
  --
  -- Pinned to a version rather than rolling, so diagnostics correspond to a
  -- cluster. Override with `vim.g.chroma_k8s_version`, or per file with a
  -- `# yaml-language-server: $schema=<url>` modeline.
  kubernetes = function()
    local version = vim.g.chroma_k8s_version or "v1.34.10"
    return {
      url = ("https://raw.githubusercontent.com/yannh/kubernetes-json-schema/master/%s-standalone-strict/all.json"):format(
        version
      ),
      -- Both extensions: an earlier list had only .yaml and silently covered
      -- half the manifests in the wild.
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
---A name with no entry here is dropped rather than guessed at. A test walks
---every shipped component, so the only way to reach that is a component file
---from somewhere else.
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
