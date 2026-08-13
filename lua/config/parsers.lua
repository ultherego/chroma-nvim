-- The treesitter parser list, in its own module because both the plugin spec
-- and CI need it: CI installs them up front so the silent-startup check is not
-- racing an async download. Which ones are wanted follows the components.

return require("chroma.components").contributions("parsers", require("chroma.state").enabled_ids())
