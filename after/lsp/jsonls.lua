-- jsonls override, merged over nvim-lspconfig's. Adds the SchemaStore
-- catalogue, so Terraform state and provider lock files validate too.

return {
  settings = {
    json = {
      schemas = require("schemastore").json.schemas(),
      validate = { enable = true },
    },
  },
}
