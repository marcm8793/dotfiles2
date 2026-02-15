#!/bin/zsh

# PREREQUISITES:
# 1. Install oh-my-zsh: sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
# 2. Clone this repo:   git clone <your-repo-url> ~/code/dotfiles2
# 3. Run this script:   cd ~/code/dotfiles2 && zsh install.sh
# 4. Set up git:         zsh git_setup.sh
#
# WHAT IT DOES:
# - Backs up your existing ~/.gitconfig and ~/.zshrc (if they exist)
# - Symlinks gitconfig and zshrc from this repo to your home directory
# - Installs zsh-syntax-highlighting, zsh-autosuggestions, and history-substring-search plugins
# - Installs zoxide (via brew on macOS, curl on Linux)
# - Symlinks keybindings.json to your VS Code config folder
# - Reloads your terminal

# Define a function which rename a `target` file to `target.backup` if the file
# exists and if it's a 'real' file, ie not a symlink
backup() {
  target=$1
  if [ -e "$target" ]; then
    if [ ! -L "$target" ]; then
      mv "$target" "$target.backup"
      echo "-----> Moved your old $target config file to $target.backup"
    fi
  fi
}

symlink() {
  file=$1
  link=$2
  if [ ! -e "$link" ]; then
    echo "-----> Symlinking your new $link"
    ln -s $file $link
  fi
}

# For each dotfile, backup the target file located at `~/.$name` and symlink `$name` to `~/.$name`
for name in gitconfig zshrc; do
  if [ ! -d "$name" ]; then
    target="$HOME/.$name"
    backup $target
    symlink $PWD/$name $target
  fi
done

# Install zsh plugins
CURRENT_DIR=`pwd`
ZSH_PLUGINS_DIR="$HOME/.oh-my-zsh/custom/plugins"
mkdir -p "$ZSH_PLUGINS_DIR" && cd "$ZSH_PLUGINS_DIR"
if [ ! -d "$ZSH_PLUGINS_DIR/zsh-syntax-highlighting" ]; then
  echo "-----> Installing zsh plugin 'zsh-syntax-highlighting'..."
  git clone https://github.com/zsh-users/zsh-syntax-highlighting
fi
if [ ! -d "$ZSH_PLUGINS_DIR/zsh-autosuggestions" ]; then
  echo "-----> Installing zsh plugin 'zsh-autosuggestions'..."
  git clone https://github.com/zsh-users/zsh-autosuggestions
fi
if [ ! -d "$ZSH_PLUGINS_DIR/zsh-history-substring-search" ]; then
  echo "-----> Installing zsh plugin 'zsh-history-substring-search'..."
  git clone https://github.com/zsh-users/zsh-history-substring-search
fi
cd "$CURRENT_DIR"

# Install zoxide
if ! command -v zoxide &> /dev/null; then
  echo "-----> Installing zoxide..."
  if [[ `uname` =~ "Darwin" ]]; then
    brew install zoxide
  else
    curl -sSfL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | sh
  fi
fi

# Symlink VS Code keybindings.json
# If it's a macOS
if [[ `uname` =~ "Darwin" ]]; then
  CODE_PATH=~/Library/Application\ Support/Code/User
# Else, it's a Linux
else
  CODE_PATH=~/.config/Code/User
  # If this folder doesn't exist, it's a WSL
  if [ ! -e $CODE_PATH ]; then
    CODE_PATH=~/.vscode-server/data/Machine
  fi
fi

target="$CODE_PATH/keybindings.json"
backup $target
symlink $PWD/keybindings.json $target

# Refresh the current terminal with the newly installed configuration
exec zsh

echo "Carry on with git setup!"
