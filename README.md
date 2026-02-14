# Dotfiles

## Setup

### 1. Install oh-my-zsh

```bash
sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
```

### 2. Clone this repo

```bash
git clone <your-repo-url> ~/code/dotfiles2
```

### 3. Run the install script

This will:
- Back up your existing `~/.gitconfig` and `~/.zshrc` (renamed to `.backup`)
- Symlink `gitconfig` and `zshrc` from this repo to your home directory
- Install zsh-autosuggestions and zsh-syntax-highlighting plugins
- Symlink `keybindings.json` to your VS Code config folder
- Reload your terminal

```bash
cd ~/code/dotfiles2 && zsh install.sh
```

### 4. Set up git

This will ask for your name and email to configure your git identity.

```bash
zsh git_setup.sh
```
