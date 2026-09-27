#!/usr/bin/env bash
# Tests for setup-nvim-cpp.sh. Run: ./test/test-setup.sh
# Each case runs in a subshell with its own temp HOME and XDG dirs, so the real Neovim
# config is never touched. Needs bash, coreutils, jq and nvim.
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
setup_script=$repo_dir/setup-nvim-cpp.sh
repo_cpp=$repo_dir/nvim/cpp.lua
all_extras='["lazyvim.plugins.extras.lang.neotree","lazyvim.plugins.extras.lang.clangd","lazyvim.plugins.extras.lang.cmake","lazyvim.plugins.extras.dap.core"]'
failures=0

# Run one test function in a subshell with fresh temp dirs. The EXIT trap removes them.
# errexit stays on inside the case (an `if` condition would turn it off), so a broken
# fixture fails the case. Commands expected to fail must be guarded with || or !.
run_case() {
  local name=$1 status
  shift
  set +e
  (
    set -e
    trap 'rm -rf -- "${CASE_DIR:-}"' EXIT
    new_case
    "$@"
  )
  status=$?
  set -e
  if ((status == 0)); then
    printf 'PASS: %s\n' "$name"
  else
    printf 'FAIL: %s\n' "$name" >&2
    failures=$((failures + 1))
  fi
}

new_case() {
  CASE_DIR=$(mktemp -d)
  export HOME=$CASE_DIR/home
  export XDG_CONFIG_HOME=$CASE_DIR/config
  export XDG_DATA_HOME=$CASE_DIR/data
  export XDG_STATE_HOME=$CASE_DIR/state
  export XDG_CACHE_HOME=$CASE_DIR/cache
  unset NVIM_APPNAME
  NVIM_DIR=$XDG_CONFIG_HOME/nvim
  mkdir -p "$HOME" "$NVIM_DIR/lua/plugins"
}

# Fail the current case with a reason and the script's output.
die() {
  printf '  %s\n' "$1" >&2
  cat -- "$CASE_DIR/out" "$CASE_DIR/err" 2>/dev/null | sed 's/^/    | /' >&2
  printf '\n' >&2
  exit 1
}

# Run the setup script, keeping stdout and stderr apart.
run_setup() {
  "$setup_script" "$@" >"$CASE_DIR/out" 2>"$CASE_DIR/err"
}

output_has() {
  grep -qE -- "$1" "$CASE_DIR/out" "$CASE_DIR/err"
}

count_files() {
  find "$NVIM_DIR" -name "$1" | wc -l
}

snapshot() {
  find "$NVIM_DIR" -printf '%P %i %s %T@\n' | sort
}

make_lazyvim_json() {
  printf '%s\n' '{"extras":["lazyvim.plugins.extras.lang.neotree"],"news":{"foo":true},"other":{"keep":42}}' > "$NVIM_DIR/lazyvim.json"
}

# A config the script already set up, plus a lock file.
make_configured() {
  jq -n --argjson e "$all_extras" '{extras: $e}' > "$NVIM_DIR/lazyvim.json"
  cp -- "$repo_cpp" "$NVIM_DIR/lua/plugins/cpp.lua"
  printf '{}\n' > "$NVIM_DIR/lazy-lock.json"
}

# PATH dir with exit-0 stubs for the C++ tools (minus the ones named in the arguments),
# a logging sudo, and links to the real tools the script needs, so results do not
# depend on host packages.
make_package_path() {
  local bin
  mkdir -p "$CASE_DIR/path"
  for bin in g++ gdb clangd clang-format cmake bear; do
    [[ " $* " == *" $bin "* ]] || printf '#!/bin/sh\nexit 0\n' > "$CASE_DIR/path/$bin"
  done
  cat > "$CASE_DIR/path/sudo" <<'SUDO'
#!/bin/sh
printf '%s\n' "$*" >> "$SUDO_LOG"
SUDO
  chmod +x "$CASE_DIR/path"/*
  for bin in bash nvim jq dirname date mktemp realpath cp chmod mv rm mkdir cat cmp; do
    ln -s "$(command -v "$bin")" "$CASE_DIR/path/$bin"
  done
  export SUDO_LOG=$CASE_DIR/sudo.log
}

# The sudo args expected for a package list. The script also needs clang when the host
# lacks /usr/bin/clangd (the LSP's pinned path), which the stub PATH cannot hide.
expected_sudo() {
  local packages=$1
  [[ -x /usr/bin/clangd || " $packages " == *" clang "* ]] || packages="clang $packages"
  printf 'pacman -S --needed %s' "$packages"
}

# A fake lazy.nvim in the temp config, run by the real nvim. Each ":Lazy" call appends
# its bang and args to $LAZY_CALLS. FAKE_LAZY=lock makes it change lazy-lock.json;
# FAKE_LAZY=missing reports plugin "foo" as not installed.
make_fake_lazy() {
  export LAZY_CALLS=$CASE_DIR/lazy-calls
  cat > "$NVIM_DIR/init.lua" <<'LUA'
vim.api.nvim_create_user_command("Lazy", function(call)
  vim.fn.writefile({ (call.bang and "!" or "") .. call.args }, vim.env.LAZY_CALLS, "a")
  if vim.env.FAKE_LAZY == "lock" then
    vim.fn.writefile({ '{"new":true}' }, vim.fn.stdpath("config") .. "/lazy-lock.json")
  end
end, { bang = true, nargs = "*" })
LUA
  cat > "$NVIM_DIR/lua/lazy.lua" <<'LUA'
return {
  plugins = function()
    local plugins = { { name = "present", _ = { installed = true } } }
    if vim.env.FAKE_LAZY == "missing" then
      plugins[#plugins + 1] = { name = "foo", _ = { installed = false } }
    end
    return plugins
  end,
}
LUA
}

test_fresh_and_idempotent() {
  make_lazyvim_json
  chmod 640 "$NVIM_DIR/lazyvim.json"
  run_setup --no-packages --no-install || die 'first run failed'
  jq -e --argjson e "$all_extras" '.extras == $e and .news.foo == true and .other.keep == 42' \
    "$NVIM_DIR/lazyvim.json" >/dev/null || die 'extras or other keys are wrong'
  cmp -s "$repo_cpp" "$NVIM_DIR/lua/plugins/cpp.lua" || die 'cpp.lua differs from the repo copy'
  [[ $(stat -c %a "$NVIM_DIR/lazyvim.json") == 640 ]] || die 'lazyvim.json lost its mode'
  [[ $(stat -c %a "$NVIM_DIR/lua/plugins/cpp.lua") == 644 ]] || die 'new cpp.lua is not 644'
  ! output_has 'Missing Arch packages|System packages' || die '--no-packages still checked packages'
  [[ $(count_files 'lazyvim.json.bak.*') -eq 1 ]] || die 'changed lazyvim.json has no backup'
  local before
  before=$(snapshot)
  run_setup --no-packages --no-install || die 'second run failed'
  [[ $(snapshot) == "$before" ]] || die 'second run changed files'
  output_has 'already in place' || die 'second run did not report no changes'
}

test_sorted_no_newline() {
  printf '%s' '{"extras":["lazyvim.plugins.extras.dap.core","lazyvim.plugins.extras.lang.cmake","lazyvim.plugins.extras.lang.clangd","lazyvim.plugins.extras.lang.neotree"],"news":{"enabled":false}}' > "$NVIM_DIR/lazyvim.json"
  local before
  before=$(sha256sum "$NVIM_DIR/lazyvim.json")
  run_setup --no-packages --no-install || die 'run failed'
  [[ $(sha256sum "$NVIM_DIR/lazyvim.json") == "$before" ]] || die 'lazyvim.json changed'
  [[ $(count_files '*.bak.*') -eq 0 ]] || die 'backup created'
}

test_cpp_backup() {
  make_lazyvim_json
  printf 'old cpp config\n' > "$NVIM_DIR/lua/plugins/cpp.lua"
  run_setup --no-packages --no-install || die 'run failed'
  local backup
  backup=$(find "$NVIM_DIR/lua/plugins" -name 'cpp.lua.bak.*' -print -quit)
  [[ -n $backup && $(cat "$backup") == 'old cpp config' ]] || die 'no backup of the old cpp.lua'
  cmp -s "$repo_cpp" "$NVIM_DIR/lua/plugins/cpp.lua" || die 'cpp.lua not replaced'
  output_has "Backup: $backup" || die 'backup not announced'
}

test_failed_backup_stops() {
  make_configured
  printf 'old cpp config\n' > "$NVIM_DIR/lua/plugins/cpp.lua"
  chmod 000 "$NVIM_DIR/lua/plugins/cpp.lua"
  ! run_setup --no-packages --no-install || die 'unexpected success'
  chmod 600 "$NVIM_DIR/lua/plugins/cpp.lua"
  [[ $(cat "$NVIM_DIR/lua/plugins/cpp.lua") == 'old cpp config' ]] || die 'cpp.lua replaced without a backup'
  ! output_has 'Backup:' || die 'claimed a backup that failed'
}

# Backups that already exist for this second (and the next few, in case the clock ticks)
# must never be overwritten; the run must stop instead.
test_backup_name_taken() {
  make_configured
  printf 'old cpp config\n' > "$NVIM_DIR/lua/plugins/cpp.lua"
  local now i backup
  now=$(date +%s)
  for i in 0 1 2 3 4 5; do
    printf 'earlier backup\n' > "$NVIM_DIR/lua/plugins/cpp.lua.bak.$(date -d "@$((now + i))" +%Y%m%d-%H%M%S)"
  done
  ! run_setup --no-packages --no-install || die 'unexpected success'
  [[ $(cat "$NVIM_DIR/lua/plugins/cpp.lua") == 'old cpp config' ]] || die 'cpp.lua replaced'
  for backup in "$NVIM_DIR/lua/plugins/"cpp.lua.bak.*; do
    [[ $(cat "$backup") == 'earlier backup' ]] || die "backup overwritten: $backup"
  done
}

test_failed_write_cleans_up() {
  make_configured
  rm "$NVIM_DIR/lua/plugins/cpp.lua"
  mkdir -p "$CASE_DIR/stub"
  cat > "$CASE_DIR/stub/cat" <<STUB
#!/bin/sh
[ "\$1" != -- ] || exit 1
exec $(command -v cat) "\$@"
STUB
  chmod +x "$CASE_DIR/stub/cat"
  ! PATH=$CASE_DIR/stub:$PATH run_setup --no-packages --no-install || die 'unexpected success'
  [[ -z $(find "$NVIM_DIR/lua/plugins" -type f) ]] || die "temp file left: $(ls "$NVIM_DIR/lua/plugins")"
}

test_symlinked_script() {
  make_lazyvim_json
  mkdir -p "$CASE_DIR/bin"
  ln -s "$setup_script" "$CASE_DIR/bin/setup"
  "$CASE_DIR/bin/setup" --no-packages --no-install >"$CASE_DIR/out" 2>"$CASE_DIR/err" \
    || die 'run through a symlink failed'
  cmp -s "$repo_cpp" "$NVIM_DIR/lua/plugins/cpp.lua" || die 'cpp.lua not installed'
}

test_nvim_appname() {
  mkdir -p "$XDG_CONFIG_HOME/lazyvim"
  NVIM_DIR=$XDG_CONFIG_HOME/lazyvim make_lazyvim_json
  NVIM_APPNAME=lazyvim run_setup --no-packages --no-install || die 'run failed'
  jq -e --argjson e "$all_extras" '.extras == $e' "$XDG_CONFIG_HOME/lazyvim/lazyvim.json" >/dev/null \
    || die 'lazyvim/lazyvim.json lacks the extras'
  cmp -s "$repo_cpp" "$XDG_CONFIG_HOME/lazyvim/lua/plugins/cpp.lua" || die 'cpp.lua not in lazyvim/'
  [[ -z $(find "$NVIM_DIR" -type f) ]] || die 'wrote to nvim/ instead'
}

test_symlinks_kept() {
  make_lazyvim_json
  mkdir -p "$CASE_DIR/dotfiles"
  mv "$NVIM_DIR/lazyvim.json" "$CASE_DIR/dotfiles/lazyvim.json"
  ln -s "$CASE_DIR/dotfiles/lazyvim.json" "$NVIM_DIR/lazyvim.json"
  printf 'old cpp config\n' > "$CASE_DIR/dotfiles/cpp.lua"
  ln -s ../../../../dotfiles/cpp.lua "$NVIM_DIR/lua/plugins/cpp.lua"
  run_setup --no-packages --no-install || die 'run failed'
  [[ -L $NVIM_DIR/lazyvim.json && -L $NVIM_DIR/lua/plugins/cpp.lua ]] || die 'a symlink was replaced'
  jq -e --argjson e "$all_extras" '.extras == $e' "$CASE_DIR/dotfiles/lazyvim.json" >/dev/null \
    || die 'link target lacks the extras'
  cmp -s "$repo_cpp" "$CASE_DIR/dotfiles/cpp.lua" || die 'cpp.lua link target not updated'
  [[ $(find "$CASE_DIR/dotfiles" -type f | wc -l) -eq 2 ]] || die "stray files: $(ls "$CASE_DIR/dotfiles")"
}

test_refusal() {
  case $1 in
    no_config) rm -rf "$NVIM_DIR" ;;
    no_json) ;;
    invalid) printf '{broken' > "$NVIM_DIR/lazyvim.json" ;;
    empty) : > "$NVIM_DIR/lazyvim.json" ;;
    object) printf '{}' > "$NVIM_DIR/lazyvim.json" ;;
    two_docs) printf '{"extras":[]}\n{"extras":[]}' > "$NVIM_DIR/lazyvim.json" ;;
  esac
  local before=missing after=missing
  [[ ! -f $NVIM_DIR/lazyvim.json ]] || before=$(sha256sum "$NVIM_DIR/lazyvim.json")
  ! run_setup --no-packages --no-install || die 'unexpected success'
  output_has 'Refusing to change files|is missing' || die 'no clear error message'
  [[ ! -f $NVIM_DIR/lazyvim.json ]] || after=$(sha256sum "$NVIM_DIR/lazyvim.json")
  [[ $before == "$after" ]] || die 'lazyvim.json changed'
  [[ -z $(find "$NVIM_DIR/lua/plugins" -mindepth 1 2>/dev/null) ]] || die 'lua/plugins changed'
}

# $1 is the exact text piped into the prompt; $2 is "none" or the packages sudo installs.
test_package_prompt() {
  make_lazyvim_json
  make_package_path bear
  printf '%s' "$1" | PATH=$CASE_DIR/path run_setup --no-install || die 'setup did not continue'
  output_has 'Missing Arch packages: .*bear' || die 'no package prompt'
  if [[ $2 == none ]]; then
    [[ ! -e $SUDO_LOG ]] || die "sudo called: $(cat "$SUDO_LOG")"
    jq -e --argjson e "$all_extras" '.extras == $e' "$NVIM_DIR/lazyvim.json" >/dev/null \
      || die 'extras missing after declining'
    cmp -s "$repo_cpp" "$NVIM_DIR/lua/plugins/cpp.lua" || die 'cpp.lua missing after declining'
  else
    [[ $(cat "$SUDO_LOG" 2>/dev/null) == "$(expected_sudo "$2")" ]] || die "wrong sudo args: $(cat "$SUDO_LOG" 2>/dev/null)"
  fi
}

test_package_dedupe() {
  make_lazyvim_json
  make_package_path clangd clang-format
  printf 'y\n' | PATH=$CASE_DIR/path run_setup --no-install || die 'run failed'
  [[ $(cat "$SUDO_LOG" 2>/dev/null) == "$(expected_sudo clang)" ]] \
    || die "wrong sudo args: $(cat "$SUDO_LOG" 2>/dev/null)"
}

test_invalid_package_precheck() {
  printf '{bad' > "$NVIM_DIR/lazyvim.json"
  make_package_path bear
  ! printf 'y\n' | PATH=$CASE_DIR/path run_setup --no-install || die 'unexpected success'
  [[ ! -e $SUDO_LOG ]] || die 'sudo ran before validation'
  ! output_has 'Missing Arch packages' || die 'prompt shown before validation'
}

# $1 is the FAKE_LAZY mode (see make_fake_lazy).
test_plugin_install() {
  make_configured
  make_fake_lazy
  local status=0
  FAKE_LAZY=$1 run_setup --no-packages </dev/null || status=$?
  local backup
  backup=$(find "$NVIM_DIR" -name 'lazy-lock.json.bak.*' -print -quit)
  [[ $(cat "$LAZY_CALLS" 2>/dev/null) == '!install' ]] \
    || die "expected one ':Lazy! install' call, got: $(cat "$LAZY_CALLS" 2>/dev/null)"
  case $1 in
    ok)
      [[ $status -eq 0 ]] || die "exit $status"
      [[ $(count_files '*.bak.*') -eq 0 ]] || die 'backup left behind'
      ;;
    lock)
      [[ $status -eq 0 ]] || die "exit $status"
      [[ -n $backup ]] || die 'lock backup not kept'
      output_has "lazy-lock.json changed. Backup: $backup" || die 'lock backup not announced'
      ;;
    missing)
      [[ $status -ne 0 ]] || die 'unexpected success'
      grep -q 'Plugins not installed: foo' "$CASE_DIR/err" || die 'missing plugin not named on stderr'
      grep -q 'Plugins not installed: foo' "$XDG_STATE_HOME/nvim/cpp-setup-install.log" \
        || die 'missing plugin not in the install log'
      grep -q 'Stopped before finishing (exit 1).*Rerun is safe' "$CASE_DIR/err" || die 'no stop message'
      ;;
  esac
}

# With no init.lua, require("lazy") fails in the check. The script must not hang.
test_plugin_check_fails_fast() {
  make_configured
  local status=0
  timeout 60 "$setup_script" --no-packages >"$CASE_DIR/out" 2>"$CASE_DIR/err" </dev/null || status=$?
  [[ $status -ne 124 ]] || die 'plugin check hung'
  [[ $status -ne 0 ]] || die 'unexpected success'
}

if [[ ! -x $setup_script ]]; then
  printf 'FAIL: setup script exists and is executable\n' >&2
  exit 1
fi

run_case 'fresh config gets only the missing extras; second run changes nothing' test_fresh_and_idempotent
run_case 'complete sorted JSON without newline stays untouched' test_sorted_no_newline
run_case 'changed cpp.lua is backed up before replacement' test_cpp_backup
if ((EUID == 0)); then
  printf 'SKIP: failed backup stops the run (root can read mode 000 files)\n'
else
  run_case 'failed backup stops the run' test_failed_backup_stops
fi
run_case 'failed write leaves no temp file' test_failed_write_cleans_up
run_case 'existing backup name stops the run instead of being overwritten' test_backup_name_taken
run_case 'symlinked lazyvim.json and cpp.lua stay symlinks' test_symlinks_kept
run_case 'script run through a symlink finds its files' test_symlinked_script
run_case 'NVIM_APPNAME picks the config dir' test_nvim_appname
run_case 'refuses a missing config dir' test_refusal no_config
run_case 'refuses a missing lazyvim.json' test_refusal no_json
run_case 'refuses invalid JSON' test_refusal invalid
run_case 'refuses an empty file' test_refusal empty
run_case 'refuses {} without extras' test_refusal object
run_case 'refuses two JSON documents' test_refusal two_docs
run_case "missing bear, answer 'n'" test_package_prompt $'n\n' none
run_case "missing bear, answer 'y'" test_package_prompt $'y\n' bear
run_case "missing bear, answer 'y' without newline" test_package_prompt 'y' bear
run_case 'missing bear, bare Enter means no' test_package_prompt $'\n' none
run_case 'missing clangd and clang-format ask for clang once' test_package_dedupe
run_case 'invalid JSON exits before package prompt or sudo' test_invalid_package_precheck
run_case 'plugin install with unchanged lock file leaves no backup' test_plugin_install ok
run_case 'plugin install that changes the lock file keeps and announces the backup' test_plugin_install lock
run_case 'failed plugin check names the plugins on stderr' test_plugin_install missing
run_case 'plugin check fails fast when lazy.nvim cannot load' test_plugin_check_fails_fast

if ((failures > 0)); then
  printf '%d test case(s) failed\n' "$failures" >&2
  exit 1
fi
printf 'All setup tests passed.\n'
