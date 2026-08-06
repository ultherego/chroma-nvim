-- DevOps layer.
--
-- kubectl.nvim replaces the `kube.nvim` the contract originally planned to
-- write; see CONTRACT.md for the survey that settled that. It downloads a
-- prebuilt Rust binary through blink.download, so no cargo toolchain is
-- needed — the blink ecosystem is already present through blink.cmp.
--
-- nvim-ansible is what finally makes the lint layer's `yaml.ansible` entry
-- fire: it ships the ftdetect rules that recognise playbooks and roles. Its
-- canonical home is Codeberg; the GitHub repository is the author's mirror.
-- Note it publishes no licence.

return {
  {
    "ramilito/kubectl.nvim",
    -- A release tag selects the prebuilt binaries rather than a source build.
    version = "2.*",
    dependencies = { "saghen/blink.download" },
    cmd = { "Kubectl", "Kubectx", "Kubens" },
    keys = {
      {
        "<leader>kk",
        function()
          require("kubectl").toggle()
        end,
        desc = "Kubernetes",
      },
      {
        "<leader>kt",
        function()
          require("kubectl").toggle({ tab = true })
        end,
        desc = "Kubernetes in a new tab",
      },
      { "<leader>kx", "<cmd>Kubectx<cr>", desc = "Switch context" },
      { "<leader>kn", "<cmd>Kubens<cr>", desc = "Switch namespace" },
    },
    config = function()
      require("kubectl").setup()

      -- Three of kubectl's default mappings never arrive: Zellij captures
      -- <C-p> (pane mode), <C-n> (resize mode) and <M-h> (move focus left).
      -- In kubectl those are the picker, the namespace view and the header
      -- toggle. Remapped onto keys free in both, using the <Plug> mappings
      -- the plugin exposes for exactly this.
      --
      -- <C-e> for the picker is upstream's own example of an override.
      vim.api.nvim_create_autocmd("FileType", {
        group = vim.api.nvim_create_augroup("devops_kubectl_keys", { clear = true }),
        pattern = "k8s_*",
        callback = function(ev)
          local opts = { buffer = ev.buf }
          vim.keymap.set("n", "<C-e>", "<Plug>(kubectl.picker_view)", opts)
          vim.keymap.set("n", "gn", "<Plug>(kubectl.namespace_view)", opts)
          vim.keymap.set("n", "gH", "<Plug>(kubectl.toggle_headers)", opts)
        end,
      })
    end,
  },

  {
    "mfussenegger/nvim-ansible",
    -- ft alone is not enough: the plugin's own ftdetect has to load before a
    -- file can be detected as yaml.ansible in the first place.
    lazy = false,
    keys = {
      {
        "<leader>ar",
        function()
          require("ansible").run()
        end,
        mode = { "n", "v" },
        desc = "Run playbook or role",
      },
    },
  },
}
