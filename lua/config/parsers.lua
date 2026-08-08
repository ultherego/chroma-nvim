-- The treesitter parsers this configuration installs.
--
-- Its own module because two things need the same list: the plugin spec, which
-- installs what is missing at startup, and CI, which installs them and waits so
-- that the "startup is silent" check is not racing an async download.

-- Which of them are wanted comes from the enabled components: a selection
-- without Docker does not compile the dockerfile grammar, and one without Helm
-- does not build helm and gotmpl.
return require("chroma.components").contributions("parsers", require("chroma.state").enabled_ids())
