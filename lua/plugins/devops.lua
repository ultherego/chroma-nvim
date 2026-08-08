-- DevOps layer.

return {
  {
    "ramilito/kubectl.nvim",
    enabled = function()
      return require("chroma.state").is_enabled("kubernetes")
    end,
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
      vim.api.nvim_create_autocmd("FileType", {
        group = vim.api.nvim_create_augroup("chroma_kubectl_keys", { clear = true }),
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
    enabled = function()
      return require("chroma.state").is_enabled("ansible")
    end,
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
