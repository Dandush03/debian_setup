#!/bin/bash
set -euo pipefail

# Initial checks
if [ "$(id -u)" = "0" ]; then
    echo "This script should not be run as root" >&2
    exit 1
fi

if ! grep -qi 'debian\|ubuntu' /etc/os-release; then
    echo "This script only supports Debian/Ubuntu systems" >&2
    exit 1
fi

if ! ping -c 1 google.com >/dev/null 2>&1; then
    echo "No internet connection available" >&2
    exit 1
fi

# Logging functions
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"; }
warn() { echo "$(date '+%Y-%m-%d %H:%M:%S') - WARNING: $1" >&2; }
error() { echo "$(date '+%Y-%m-%d %H:%M:%S') - ERROR: $1" >&2; exit 1; }

# Create temporary directory and setup cleanup
TEMP_DIR=$(mktemp -d)
cleanup() {
    local ret=$?
    rm -rf "$TEMP_DIR"
    if [ $ret -ne 0 ]; then
        warn "Installation did not complete successfully"
    fi
    exit $ret
}
trap cleanup EXIT ERR

# Helper functions
install_package() {
    log "Installing packages: $*..."
    if ! sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"; then
        error "Failed to install: $*"
    fi
}

get_current_user() { id -un || error "Failed to determine current user"; }

update_shell_profile() {
    local profile_files=("$HOME/.profile" "$HOME/.bash_profile" "$HOME/.bashrc")
    local rbenv_init='export PATH="$HOME/.rbenv/bin:$PATH"\neval "$(rbenv init -)"\nexport PATH="$HOME/.rbenv/plugins/ruby-build/bin:$PATH"'
    local updated=0

    for profile in "${profile_files[@]}"; do
        if [ ! -f "$profile" ] || ! grep -q "rbenv init" "$profile"; then
            log "Updating $profile with rbenv configuration..."
            echo -e "\n# rbenv configuration\n$rbenv_init" >> "$profile"
            updated=1
        fi
    done
    
    if [ "$updated" -eq 0 ]; then
        warn "rbenv configuration already exists in shell profiles"
    fi

    source ~/.bashrc
}

install_ruby_versions() {
    if ! command -v rbenv >/dev/null; then
        error "rbenv not found in PATH"
    fi

    local versions=("2.6.10" "3.3.5" "3.4.1")
    local default_version="3.4.1"
    
    export PATH="$HOME/.rbenv/bin:$PATH"
    eval "$(rbenv init -)"
    
    for version in "${versions[@]}"; do
        if ! rbenv versions | grep -q "$version"; then
            log "Installing Ruby $version..."
            rbenv install -v "$version" || error "Failed to install Ruby $version"
            rbenv shell "$version"
            gem install bundler --no-document || warn "Failed to install bundler for Ruby $version"
            gem install rake --no-document || warn "Failed to install rake for Ruby $version"
            rbenv rehash
        else
            log "Ruby $version is already installed"
        fi
    done
    
    rbenv global "$default_version"
    log "Ruby versions installed and configured successfully"
}

install_rbenv() {
    log "Installing rbenv and Ruby versions..."
    if [ ! -d "$HOME/.rbenv" ]; then
        git clone https://github.com/rbenv/rbenv.git "$HOME/.rbenv"
        log "rbenv installed successfully"
    else
        log "rbenv is already installed"
    fi

    if [ ! -d "$HOME/.rbenv/plugins/ruby-build" ]; then
        git clone https://github.com/rbenv/ruby-build.git "$HOME/.rbenv/plugins/ruby-build"
        log "ruby-build plugin installed successfully"
    else
        log "ruby-build plugin is already installed"
    fi

    update_shell_profile
    install_ruby_versions
}

install_docker() {
    log "Installing Docker..."
    if command -v docker >/dev/null; then
        log "Docker is already installed"
        return
    fi

    local current_user
    current_user=$(get_current_user)

    # Uninstall all conflicting packages
    for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do sudo apt-get remove $pkg; done
    
    # Ensure the keyrings directory exists
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo mkdir -p /etc/apt/keyrings
    
    # Add Docker repository
    if [ ! -f /etc/apt/keyrings/docker.asc ]; then
        sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
        sudo chmod a+r /etc/apt/keyrings/docker.asc

        # Add the repository to Apt sources:
        echo \
          "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \
          $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
          sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
        sudo apt-get update
    fi
    
    install_package docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    
    if ! groups "$current_user" | grep -qw docker; then
        sudo usermod -aG docker "$current_user"
        warn "Please log out and back in for Docker group changes to take effect"
    fi
}

install_deb_package() {
    local url="$1"
    local name="$2"
    log "Installing $name..."
    
    if dpkg-query -W -f='${Status}' "$name" 2>/dev/null | grep -q "install ok installed"; then
        log "$name is already installed"
        return
    fi

    wget -q "$url" -O "$TEMP_DIR/$name.deb" || error "Failed to download $name"

    if ! sudo dpkg -i "$TEMP_DIR/$name.deb"; then
        log "Fixing missing dependencies..."
        sudo apt-get install -f -y || error "Failed to fix dependencies for $name"
        
        # Only re-run dpkg if required
        if ! sudo dpkg -i "$TEMP_DIR/$name.deb"; then
            error "Failed to install $name"
        fi
    fi
    
    log "$name installed successfully"
}

setup_bashrc_additions() {
    log "Adding custom configurations to .bashrc..."
    
    # Create backup
    cp "$HOME/.bashrc" "$HOME/.bashrc.backup.$(date +%Y%m%d_%H%M%S)"
    
    # Append the custom configurations
    cat >> "$HOME/.bashrc" << 'EOL'

##
## Add Git Branch Name
##
parse_git_branch() {
  git branch 2> /dev/null | sed -e '/^[^*]/d' -e 's/* \(.*\)/ (\1)/'
}

function ps1() {
  Cyan="\[\033[0;36m\]"
  Yellow="\[\033[0;33m\]"
  BrightRed="\[\033[0;33m\]"
  BrightMagenta="\[\033[0;95m\]"
  BrightGreen="\[\033[0;92m\]"
  Green="\[\033[0;32m\]"
  Magenta="\[\033[0;35m\]"
  White="\[\033[00m\]"
  PS1="$Cyan\u@\h $BrightGreen\w$BrightMagenta$(parse_git_branch) $Cyan$\n $Green└─> $White"
}

export PROMPT_COMMAND=ps1

if [ -f ~/.git-prompt.sh ]; then
  GIT_PS1_SHOWDIRTYSTATE=true
  GIT_PS1_SHOWSTASHSTATE=true
  GIT_PS1_SHOWUNTRACKEDFILES=true
  GIT_PS1_SHOWUPSTREAM="auto"
  GIT_PS1_HIDE_IF_PWD_IGNORED=true
  GIT_PS1_SHOWCOLORHINTS=true
  . ~/.git-prompt.sh
fi

##
## Set Title
##
function set_title() {
  PROMPT_COMMAND="echo -ne '\033]0;${PWD##*/}\007'"
}

##
## Git Macros
##
function git_add(){
  git add . && git commit -m "$*"
}

##
## Aliases
##
alias overide='sudo chown -R $USER:$USER .' # Overide permissions
alias gita='git_add'
alias dc='docker compose' # Docker Compose (Alias)
alias dce='docker compose exec' # Docker Compose Exec (Execute)
alias dcr='docker compose run --rm --no-deps' # Docker Compose Run (Run Remove No Dependencies)
alias title='set_title' # Set Title of Terminal

EOL
    
    log "Custom configurations added to .bashrc"
    
    # Source the updated .bashrc
    source "$HOME/.bashrc" || true
}

main() {
    # System update
    log "Updating system packages..."
    sudo apt-get update && sudo apt-get upgrade -y
    
    # Install prerequisites
    install_package curl git wget gnupg lsb-release software-properties-common ca-certificates \
                    gcc make libssl-dev libreadline-dev zlib1g-dev libsqlite3-dev libyaml-dev bzip2
    
    # Install applications
    install_deb_package "https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb" "google-chrome-stable"
    setup_bashrc_additions
    install_docker
    install_rbenv
    
    log "Installation completed successfully!"
    log "Please restart your session for all changes to take effect."
}

main "$@"
