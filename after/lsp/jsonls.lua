-- jsonls override.
--
-- Merged over nvim-lspconfig's lsp/jsonls.lua. Adds the SchemaStore catalogue
-- so that package.json, tsconfig, GitHub workflows and — relevant here —
-- Terraform state and provider lock files validate against real schemas.

return {
  settings = {
    json = {
      schemas = require("schemastore").json.schemas(),
      validate = { enable = true },
    },
  },
}
