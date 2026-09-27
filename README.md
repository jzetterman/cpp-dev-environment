# Neovim C++ setup

This setup enables LazyVim's clangd, CMake and DAP extras. It configures clangd to
use the system binary and C++23. It configures gdb for debugging. It adds build and
run keymaps for the current C++ file.

Run `./setup-nvim-cpp.sh` on Omarchy. The script offers to install missing Arch
packages, then installs the lazy.nvim plugins. Restart Neovim when it finishes.

Use `--no-packages` to skip system package checks. Use `--no-install` to skip
lazy.nvim plugin installation. Use `--help` (or `-h`) for help.

## What it changes

The script needs `nvim` and `jq`. It may offer to install `gcc`, `gdb`, `clang`,
`cmake` and `bear` with `sudo pacman`.

It changes these files in `~/.config/nvim` (or `~/.config/$NVIM_APPNAME` if you set
`NVIM_APPNAME`):

- `lazyvim.json`: adds the three extras. Other extras and keys stay.
- `lua/plugins/cpp.lua`: the C++ config from `nvim/cpp.lua`.
- `lazy-lock.json`: only if the plugin install adds or drops pins.

Before it changes a file, it copies it to `<file>.bak.<YYYYmmdd-HHMMSS>` next to the
original. If your config is not under git, these backups are the only undo: copy one
back over the file.

You can rerun the script. It changes only what is missing. It replaces a hand-edited
`cpp.lua` with the repo copy, after a backup. The plugin install log is at
`~/.local/state/nvim/cpp-setup-install.log` (`nvim` becomes `$NVIM_APPNAME` when set).

The debugger is gdb. The setup stops Mason from installing codelldb, LazyVim's
default.

## Keys

- `<leader>cb` saves and builds the current file.
- `<leader>ce` saves, builds and runs the current file.
- `<leader>db` sets or clears a breakpoint.
- `<leader>dc` starts or continues debugging.

`<leader>cb` and `<leader>ce` work only in C++ buffers. They skip headers and files
with no extension. The binary lands next to the source file, with the same name and
no extension. If a file that is not a program already has that name, they warn and
do not build. Each build or run press opens a new split. Close old build splits with
`:q`.

For CMake, configure with `-DCMAKE_EXPORT_COMPILE_COMMANDS=ON`. For Make projects,
run `bear -- make` to create `compile_commands.json`.

## Known limits

- clangd uses `-std=c++23` only for files with no build system. It applies that
  flag to every such file, so a lone C file may report the flag as invalid. Add
  `compile_flags.txt` or a build system to provide the right flags.
- Under the debugger, the program's stdin is `/dev/null`. Programs that read
  `std::cin` should run with `<leader>ce`. Program output appears in the DAP REPL.
- The setup does not attach to running processes. Omarchy's `ptrace_scope` is 1, so
  gdb can debug only programs it starts.
- If Neovim stays open while the script runs, a later `:LazyExtras` action in that
  session can overwrite the updated extras list. Restart Neovim after setup.
- Building, debugging, or saving CMake files in an untrusted repo runs that repo's
  code. cmake-tools regenerates on save, and `<leader>dc` can offer a repo's
  `.vscode/launch.json`.

## Tests

`./test/test-setup.sh` tests the script in temp dirs. It never touches your config.

`test/live-check.lua` checks clangd, gdb and the keymaps inside Neovim. Run it in a
sandbox copy of your config: set `XDG_CONFIG_HOME`, `XDG_DATA_HOME`,
`XDG_STATE_HOME` and `XDG_CACHE_HOME` to dirs holding copies of your config and
plugins, run the script with `--no-packages`, then
`nvim --headless "+luafile test/live-check.lua"`. It exits non-zero on any failure.
