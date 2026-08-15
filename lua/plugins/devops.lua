-- DevOps layer.

return {
  {
    "ramilito/kubectl.nvim",
    -- Which component brings this is `components/kubernetes.json`'s to say.
    enabled = function()
      return require("chroma.state").contributes("plugins", "kubectl.nvim")
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

      -- What the cluster subprocesses are allowed to see of the environment.
      -- The plugin strips it down to four variables, and a credential helper
      -- needs whatever its provider needs.
      require("chroma.kubernetes").setup()

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
      return require("chroma.state").contributes("plugins", "nvim-ansible")
    end,
    -- ft alone is not enough: the plugin's own ftdetect has to load before a
    -- file can be detected as yaml.ansible in the first place.
    lazy = false,

    -- No keys, deliberately: this plugin runs a playbook by inferring the
    -- command from the buffer, and inference is what was retired. Running one
    -- is `<leader>ar`, which chooses and shows every part, or `<leader>xr` for
    -- a command the repository declared. What is left here is filetype
    -- detection, `K` on `ansible-doc`, and `path` extended so `gf` finds a role.
  },
}
