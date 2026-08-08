-- The treesitter parsers this configuration installs.
--
-- Its own module because two things need the same list: the plugin spec, which
-- installs what is missing at startup, and CI, which installs them and waits so
-- that the "startup is silent" check is not racing an async download.

return {
  -- Infrastructure as code
  "terraform",
  "hcl",
  -- Kubernetes, Helm, CI
  "yaml",
  "helm",
  "gotmpl",
  "dockerfile",
  -- Scripting and config formats
  "bash",
  "python",
  "lua",
  "json",
  "toml",
  "ini",
  "xml",
  "sql",
  "make",
  "ssh_config",
  -- Go, for reading operators and controllers
  "go",
  "gomod",
  -- Git
  "git_config",
  "gitcommit",
  "gitignore",
  "diff",
  -- Editor and docs
  "markdown",
  "markdown_inline",
  "regex",
  "query",
  "vim",
  "vimdoc",
}
