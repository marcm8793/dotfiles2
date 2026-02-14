ZSH=$HOME/.oh-my-zsh
ZSH_THEME="robbyrussell"
plugins=(git gitfast last-working-dir common-aliases zsh-syntax-highlighting zsh-autosuggestions history-substring-search)

export HOMEBREW_NO_ANALYTICS=1
ZSH_DISABLE_COMPFIX=true

source "${ZSH}/oh-my-zsh.sh"
unalias rm
unalias lt

# Load nvm
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"

# Auto nvm use with .nvmrc
autoload -U add-zsh-hook
load-nvmrc() {
  if nvm -v &> /dev/null; then
    local node_version="$(nvm version)"
    local nvmrc_path="$(nvm_find_nvmrc)"
    if [ -n "$nvmrc_path" ]; then
      local nvmrc_node_version=$(nvm version "$(cat "${nvmrc_path}")")
      if [ "$nvmrc_node_version" = "N/A" ]; then
        nvm install
      elif [ "$nvmrc_node_version" != "$node_version" ]; then
        nvm use --silent
      fi
    elif [ "$node_version" != "$(nvm version default)" ]; then
      nvm use default --silent
    fi
  fi
}
type -a nvm > /dev/null && add-zsh-hook chpwd load-nvmrc
type -a nvm > /dev/null && load-nvmrc

# PATH
export PATH="./bin:./node_modules/.bin:${PATH}:/usr/local/sbin"

# Encoding
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

# Editors
export BUNDLER_EDITOR=code
export EDITOR=code

# Python debugger
export PYTHONBREAKPOINT=ipdb.set_trace

# Zoxide
eval "$(zoxide init zsh)"
