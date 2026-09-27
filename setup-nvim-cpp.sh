#!/usr/bin/env bash
# Configure LazyVim for C++ with g++, clangd and gdb on Omarchy (Arch).
# Safe to rerun: it changes only what is missing and backs up any file it replaces.
set -euo pipefail
shopt -s inherit_errexit
# Stop on Ctrl-C, even when a child such as headless nvim handles the signal itself.
trap 'exit 130' INT

usage() {
  cat <<'USAGE'
Usage: setup-nvim-cpp.sh [--no-packages] [--no-install] [-h]

Configure LazyVim for C++ development. Missing system packages are offered for
installation with sudo pacman. lazy.nvim plugins are installed unless disabled.

  --no-packages  Skip checking or installing system packages
  --no-install   Skip lazy.nvim plugin installation
  -h             Show this help
USAGE
}

no_packages=false
no_install=false
while (($# > 0)); do
  case $1 in
    --no-packages) no_packages=true ;;
    --no-install) no_install=true ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Error: unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

for required in nvim jq; do
  if ! command -v "$required" >/dev/null 2>&1; then
    printf 'Error: required command %s is missing. Install it before continuing.\n' "$required" >&2
    exit 1
  fi
done

# nvim names its config and state dirs after NVIM_APPNAME.
app=${NVIM_APPNAME:-nvim}
config_dir=${XDG_CONFIG_HOME:-$HOME/.config}/$app
lazyvim_json=$config_dir/lazyvim.json
plugins_dir=$config_dir/lua/plugins
installed_cpp=$plugins_dir/cpp.lua
script_dir=$(dirname -- "$(realpath -- "${BASH_SOURCE[0]}")")
source_cpp=$script_dir/nvim/cpp.lua

if [[ ! -d $config_dir ]]; then
  printf 'Error: Neovim config directory is missing: %s\n' "$config_dir" >&2
  exit 1
fi
if [[ ! -f $lazyvim_json ]]; then
  printf 'Error: LazyVim config is missing: %s\n' "$lazyvim_json" >&2
  exit 1
fi
if ! jq -e -s 'length==1 and (.[0]|type=="object") and (.[0].extras|type=="array")' "$lazyvim_json" >/dev/null 2>&1; then
  printf 'Error: %s must contain one JSON object with an extras array. Refusing to change files.\n' "$lazyvim_json" >&2
  exit 1
fi

if [[ ! -f $source_cpp ]]; then
  printf 'Error: bundled C++ plugin file is missing: %s\n' "$source_cpp" >&2
  exit 1
fi

if [[ $no_packages == false ]]; then
  missing_packages=()
  # Add the package for a missing binary to missing_packages, once.
  check_binary() {
    local binary=$1
    local package=$2
    if ! command -v "$binary" >/dev/null 2>&1; then
      [[ " ${missing_packages[*]} " == *" $package "* ]] || missing_packages+=("$package")
    fi
  }
  check_binary g++ gcc
  check_binary gdb gdb
  check_binary clangd clang
  # The LSP config pins this path, so a clangd elsewhere on PATH is not enough.
  check_binary /usr/bin/clangd clang
  check_binary clang-format clang
  check_binary cmake cmake
  check_binary bear bear

  if ((${#missing_packages[@]} > 0)); then
    printf 'Missing Arch packages: %s\n' "${missing_packages[*]}"
    printf 'Run sudo pacman -Syu first if you have not upgraded recently.\n'
    printf 'Install missing packages with sudo pacman -S --needed? [y/N] '
    answer=''
    read -r answer || true
    if [[ $answer == [yY] ]]; then
      if ! sudo pacman -S --needed "${missing_packages[@]}"; then
        printf 'Package installation failed. Run sudo pacman -Syu, then rerun this script.\n' >&2
        exit 1
      fi
      printf 'Installed missing system packages.\n'
    else
      printf 'Skipped system package installation; continuing.\n'
    fi
  else
    printf 'System packages are already in place.\n'
  fi
fi

timestamp=$(date +%Y%m%d-%H%M%S)
# Copy a file to <file>.bak.<timestamp> and print the backup path. If that name is
# taken (two runs in one second), cp fails and the run stops rather than overwrite it.
backup_file() {
  local file=$1
  local backup="$file.bak.$timestamp"
  cp -p --update=none-fail -- "$file" "$backup"
  printf '%s' "$backup"
}

atomic_temp=''
lockfile=$config_dir/lazy-lock.json
lock_backup=''
# Runs on exit from here on: removes a half-written temp file, keeps the lazy-lock.json
# backup only if the file changed, and says so if the run stopped early.
cleanup() {
  local status=$?
  rm -f -- "$atomic_temp"
  if [[ -n $lock_backup ]]; then
    if cmp -s -- "$lockfile" "$lock_backup"; then
      rm -f -- "$lock_backup"
    else
      printf 'lazy-lock.json changed. Backup: %s\n' "$lock_backup"
    fi
  fi
  if ((status != 0)); then
    printf 'Stopped before finishing (exit %d). Changes made so far are listed above. Rerun is safe.\n' "$status" >&2
  fi
}
trap cleanup EXIT

# Usage: atomic_write <dest> <command...>. Writes the command's output to a temp file
# beside dest, copies dest's mode (0644 for a new file), then renames it over dest.
# A symlinked dest keeps its link; the link's target gets the new content.
atomic_write() {
  local dest
  dest=$(realpath -m -- "$1")
  shift
  atomic_temp=$(mktemp "$dest.XXXXXX")
  "$@" > "$atomic_temp"
  if [[ -e $dest ]]; then
    chmod --reference="$dest" -- "$atomic_temp"
  else
    chmod 0644 -- "$atomic_temp"
  fi
  mv -f -- "$atomic_temp" "$dest"
  atomic_temp=''
}

wanted_extras='["lazyvim.plugins.extras.lang.clangd","lazyvim.plugins.extras.lang.cmake","lazyvim.plugins.extras.dap.core"]'
if jq -e --argjson w "$wanted_extras" '($w - .extras) == []' "$lazyvim_json" >/dev/null; then
  printf 'LazyVim C++ extras are already in place.\n'
else
  lazy_backup=$(backup_file "$lazyvim_json")
  # shellcheck disable=SC2016 # $w is a jq variable, not a shell one.
  atomic_write "$lazyvim_json" jq --argjson w "$wanted_extras" '.extras += ($w - .extras)' "$lazyvim_json"
  printf 'Enabled the clangd, cmake and DAP LazyVim extras. Backup: %s\n' "$lazy_backup"
fi

mkdir -p -- "$plugins_dir"
if [[ -f $installed_cpp ]] && cmp -s -- "$source_cpp" "$installed_cpp"; then
  printf 'C++ plugin config is already in place.\n'
else
  cpp_message='Installed C++ plugin config.'
  if [[ -e $installed_cpp ]]; then
    cpp_backup=$(backup_file "$installed_cpp")
    cpp_message="Updated C++ plugin config. Backup: $cpp_backup"
  fi
  atomic_write "$installed_cpp" cat -- "$source_cpp"
  printf '%s\n' "$cpp_message"
fi

if [[ $no_install == false ]]; then
  state_dir=${XDG_STATE_HOME:-$HOME/.local/state}/$app
  install_log=$state_dir/cpp-setup-install.log
  mkdir -p -- "$state_dir"
  if [[ -f $lockfile ]]; then
    lock_backup=$(backup_file "$lockfile")
  fi
  printf 'Installing lazy.nvim plugins. This may take a few minutes. Log: %s\n' "$install_log"

  # After the install, the same nvim asks lazy.nvim which plugins are still missing.
  # The trailing "-c cq" quits with an error if this Lua fails, so nvim cannot hang.
  check_code='
    local missing = {}
    for _, plugin in ipairs(require("lazy").plugins()) do
      if not plugin._.installed then
        missing[#missing + 1] = plugin.name
      end
    end
    if #missing > 0 then
      table.sort(missing)
      io.stderr:write("\nPlugins not installed: " .. table.concat(missing, ", ") .. "\n")
      vim.cmd("cq")
    end
    vim.cmd("qa")'
  if ! nvim --headless '+Lazy! install' "+lua $check_code" -c cq > "$install_log" 2>&1; then
    grep -h '^Plugins not installed:' "$install_log" >&2 || true
    printf 'Error: lazy.nvim plugin install failed. Fix the cause (for example, network). Log: %s\n' "$install_log" >&2
    exit 1
  fi
  printf 'lazy.nvim plugins are installed.\n'
fi

cat <<'NEXT'
Next steps:
  Restart any open Neovim session.
  CMake: configure with -DCMAKE_EXPORT_COMPILE_COMMANDS=ON.
  Make: generate compile_commands.json with bear -- make.
  Build: <leader>cb. Build and run: <leader>ce.
  Debug: <leader>db sets a breakpoint; <leader>dc starts or continues.
NEXT
