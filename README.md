# Dotfiles

This repository contains the user-level configuration managed with
[chezmoi](https://www.chezmoi.io/).

The source directory is normally located at
`~/.local/share/chezmoi`, and the target directory is the user's home
directory.

## Initialize an existing machine

From the chezmoi source directory, review and apply the current state:

```sh
chezmoi diff
chezmoi apply
```

To preview the complete operation:

```sh
chezmoi apply --dry-run --verbose
```

The desktop configuration is selected for the host named `ghost`. Other hosts
receive the shared terminal configuration and skip the desktop files.

## Initialize a new machine

Install Git and chezmoi on the new machine, then initialize the repository:

```sh
chezmoi init <repository-url>
chezmoi diff
chezmoi apply
```

For a machine where the repository has already been reviewed, initialization
and application can be combined:

```sh
chezmoi init --apply <repository-url>
```

After initialization, install the package groups required by the machine and
apply the configuration again:

```sh
chezmoi apply
```

## Package groups

The files under `packages/` are package inventories. They are not copied to
the home directory and are not installed automatically by chezmoi.

| Manifest | Contents |
| --- | --- |
| `packages/arch/common.txt` | Baseline terminal tools, including Fish, Starship, vfox, tmux, Git, and bat |
| `packages/arch/terminal-enhanced.txt` | Optional terminal tools, including zoxide and btop |
| `packages/arch/development.txt` | Optional development tools, including Neovim and tree-sitter-cli |
| `packages/arch/ghost-desktop.txt` | Graphical tools for the `ghost` host |
| `packages/private.example.txt` | Example entries for a local private manifest |

On Arch Linux, install the entries from the selected manifests with an Arch
package manager or AUR helper. For example:

```sh
awk '!/^[[:space:]]*(#|$)/' packages/arch/common.txt \
  | xargs yay -S --needed
```

Add `terminal-enhanced.txt`, `development.txt`, or `ghost-desktop.txt` when
the corresponding layer is needed.

## Shell usage

Fish is the preferred interactive shell. Its configuration is stored at
`dot_config/private_fish/config.fish` and is applied to
`~/.config/fish/config.fish`.

Bash is the fallback shell. Its startup files are:

```text
dot_bashrc       -> ~/.bashrc
dot_bash_profile -> ~/.bash_profile
```

When the corresponding commands are installed, the Shell configurations
provide these command mappings:

```text
vim -> nvim
cat -> bat --paging=never --style=plain
$EDITOR and $VISUAL -> nvim
```

The Fish, Bash, and minimal Zsh configurations also initialize zoxide when
the `zoxide` command is available. Zoxide's database remains runtime data in
the user's home directory.

Zsh is an optional compatibility shell. The repository does not install Oh
My Zsh or Zsh plugins.

## Neovim and plugins

Neovim is installed from `packages/arch/development.txt`. Its configuration
is stored under:

```text
dot_config/nvim/
├── init.lua
├── lua/
│   ├── options.lua
│   ├── keymaps.lua
│   ├── plugins.lua
│   └── lsp.lua
└── lazy-lock.json           # generated after the first plugin sync
```

The Neovim layer uses Lazy.nvim:

1. chezmoi applies `~/.config/nvim`.
2. The first Neovim start bootstraps Lazy.nvim if necessary.
3. Plugin declarations in `plugins.lua` are synchronized by Lazy.nvim.
4. `lazy-lock.json` records the exact plugin revisions after the first sync.
5. `:Lazy sync` installs declared plugins and updates the local runtime.
6. `:Lazy update` updates plugins and the lock file for a deliberate change.

The downloaded plugin directory is runtime data and is not stored in this
repository:

```text
~/.local/share/nvim/lazy/
```

Mason manages language servers and related development tools. Their desired
package list is declared in the Neovim configuration, while the installed
servers are stored under:

```text
~/.local/share/nvim/mason/
```

Treesitter parsers follow the same model: their language list is configured in
Neovim and the downloaded parsers remain in Neovim's runtime data.

To initialize the Neovim runtime on a new machine:

```sh
chezmoi apply
nvim
```

Inside Neovim, run:

```vim
:Lazy sync
```

After the first successful sync, add the generated lock file to the chezmoi
source directory:

```sh
chezmoi re-add ~/.config/nvim/lazy-lock.json
```

Once Neovim is installed, changes to the Neovim configuration also trigger
the repository's `run_onchange_` synchronization script during `chezmoi
apply`.

After changing the plugin declaration or lock file, apply the configuration,
run `:Lazy sync`, test Neovim, and commit the source changes.

## Repository layout

```text
.
├── .chezmoidata.toml
├── .chezmoiignore
├── dot_bashrc
├── dot_bash_profile
├── dot_zshrc
├── dot_tmux.conf
├── dot_config/
│   ├── private_fish/
│   ├── nvim/
│   ├── hypr/
│   ├── waybar/
│   ├── rofi/
│   ├── kitty/
│   └── ...
├── dot_local/bin/
└── packages/
    ├── arch/
    └── private.example.txt
```

Chezmoi source names use these path conventions:

```text
dot_         -> a leading dot in the target path
private_     -> restrictive target permissions
executable_  -> executable target permissions
.tmpl        -> render the file as a chezmoi template
```

## Update and commit workflow

Pull repository changes and apply them:

```sh
chezmoi update
```

Review and apply changes manually:

```sh
chezmoi diff
chezmoi apply
chezmoi status
```

When editing the source repository directly:

```sh
cd "$(chezmoi source-path)"
git status
git diff
git add <files>
git commit
git push
```

When an intended change was made directly in the home directory, bring it
back into the source repository with:

```sh
chezmoi re-add <target-file>
```

After `chezmoi apply`, an empty `chezmoi diff` means that the target home
directory matches the source state.
