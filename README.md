<div align="center">

# DevOps nVim

**The best Neovim environment for DevOps.**

🚀 fast · 🧩 modular · 🔧 easy to extend · 📦 maintained plugins only · 📝 documented · 🎨 Catppuccin Mocha

</div>

---

> **Status:** contract v1.0 agreed. Implementation has not started yet.
> Scope, structure and rules live in [`CONTRACT.md`](./CONTRACT.md).

## Who it is for

People who live in the terminal and work with Terraform, Terragrunt, Kubernetes,
Ansible, Helm, Docker and YAML. This is not a general-purpose config with a
DevOps garnish — DevOps is the starting point.

## Workflow

```
Kitty → Zellij → Yazi → Neovim
```

Not VS Code.

## Requirements

- **Neovim ≥ 0.12** — the config is built on the native LSP API (`vim.lsp.config` / `vim.lsp.enable`)
- `git`, `rg`, `fd`, `fzf`
- `lazygit`, `yazi`
- DevOps tooling as needed: `terraform` / `terragrunt`, `kubectl`, `helm`, `ansible`

## Installation

> Filled in once implementation starts.

## Custom plugins

Three real plugins are built as part of this project:

| Plugin | Scope |
|---|---|
| `ansible-vault.nvim` | Ansible Vault handling inside the editor |
| `kube.nvim` | context, namespace, pods, logs, describe, exec |
| `terraform.nvim` | init, fmt, validate, plan, apply, destroy |

## The rule this rests on

**Zero code from memory.** For every plugin: read the documentation → check
breaking changes → only then configure.

## License

[MIT](./LICENSE)
