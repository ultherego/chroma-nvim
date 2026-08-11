-- DevOps layer.

return {
  {
    "ramilito/kubectl.nvim",
    -- Which component brings this is `components/kubernetes.json`'s to say, and
    -- it says it. Naming the component here as well would be the same fact in
    -- two files, free to disagree.
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

    -- No keys, and that is the change rather than an omission. This plugin can
    -- run a playbook by inferring the command from the buffer, and Chroma no
    -- longer offers that: how a repository runs Ansible is what its own task
    -- file says, and two execution models in one editor — one declared, one
    -- guessed — is the thing the task runner exists to end.
    --
    -- What is left is what only this plugin does: detecting `yaml.ansible`,
    -- which is what activates ansible-lint and ansiblels, pointing `K` at
    -- `ansible-doc`, and extending `path` so `gf` follows a role.
  },
}
