# Tooling manifests

These files are not installed into `$HOME` by chezmoi. Use the manifest that
matches the target machine:

- `packages/arch/common.txt`: the baseline terminal tools.
- `packages/arch/terminal-enhanced.txt`: optional tools such as zoxide and
  btop.
- `packages/arch/development.txt`: optional development tools such as Neovim.
- `packages/arch/ghost-desktop.txt`: graphical tools for the `ghost` host.
- `packages/private.example.txt`: a template for a local private manifest.
