# Neovim C++ setup script: spec and plan

Tier: Small (one script, one Lua file, no security surface beyond a user-run `sudo pacman`).

## Problem

Omarchy ships LazyVim with no C++ support turned on. Setting it up by hand means picking
LazyVim extras, pointing clangd at the right C++ standard, swapping LazyVim's default
debugger (codelldb) for gdb, and adding a way to build and run a file. A script should do
this in one run and be safe to run again.

## Requirements

1. Target: Omarchy (Arch, `pacman`), Neovim with LazyVim, g++ as the compiler.
2. Check for these binaries. List the missing Arch packages, ask, then run
   `sudo pacman -S --needed <pkgs>`. This matches Omarchy's own `omarchy-pkg-add`. It is
   not a full guard against a partial upgrade: if the package database was refreshed
   without a system upgrade, pacman can pull newer packages than the rest of the system.
   So the prompt says "run `sudo pacman -Syu` first if you have not upgraded recently",
   and a failed install tells the user to run it and rerun. The script never runs `-Syu`
   itself: a whole-system upgrade is too big a side effect for a setup script. The user
   may decline; the script then goes on.

   | Binary | Package |
   |---|---|
   | `g++` | `gcc` |
   | `gdb` | `gdb` |
   | `clangd` (also at `/usr/bin/clangd`, the path the LSP uses), `clang-format` | `clang` |
   | `cmake` | `cmake` |
   | `bear` | `bear` |

   `nvim` (`neovim`) and `jq` (`jq`) are hard dependencies. The script checks them before
   the sudo prompt and exits if either is missing.
3. Turn on LazyVim extras `lazyvim.plugins.extras.lang.clangd`,
   `lazyvim.plugins.extras.lang.cmake` and `lazyvim.plugins.extras.dap.core` in
   `lazyvim.json` (full module names, as LazyVim stores them). Keep every existing key and
   extra, in order. Write only when an extra is missing
   (`jq -e --argjson w '[...]' '($w - .extras) == []'`); append with
   `.extras += ($w - .extras)`. LazyVim rewrites this file in its own format, so a byte
   compare would cause needless writes.
4. Install one plugin file, `lua/plugins/cpp.lua`. It layers on the extras through
   **opts functions only** for nvim-lspconfig, nvim-dap and mason.nvim, never a `config`
   key (a `config` on nvim-dap would replace dap.core's setup). User specs load after
   extras, so these functions run last. The nvim-dap and cmake-tools.nvim specs set
   `optional = true`, so turning off their extras does not make this file install them
   alone. The file:
   - uses the system clangd, not a Mason copy: `servers.clangd.mason = false`, and the
     opts function sets `opts.servers.clangd.cmd[1] = "/usr/bin/clangd"` in place (Mason
     puts its bin dir first on `PATH`, so a bare `clangd` could still find a Mason copy).
     It changes only that element: a table spec for `cmd` would replace the whole list
     and drop the extra's flags. No `--query-driver`: clangd already finds g++'s
     libstdc++ headers;
   - sets clangd `init_options.fallbackFlags = { "-std=c++23" }` for files with no build
     system;
   - points nvim-dap at gdb's native DAP mode: adapter `gdb` =
     `{ type = "executable", command = "gdb", args = { "--interpreter=dap", "-q" } }`
     (`-q` drops gdb's banner from the REPL), one
     "Launch" entry for C and C++ (keys `program`, `cwd`), with the current file's binary
     (`%:p:r`) as the default path. It overwrites the configurations the clangd extra sets;
   - stops codelldb from being installed: sets `dap.adapters.codelldb = nil` (otherwise
     mason-nvim-dap's automatic install picks it up from the adapter table) and filters
     `codelldb` out of mason.nvim `ensure_installed`;
   - sets cmake-tools.nvim's `cmake_dap_configuration` to type `gdb` (plain opts table),
     since the cmake extra's cmake-tools defaults to codelldb;
   - adds buffer-local keymaps in C++ buffers through a `FileType cpp` autocmd in an
     augroup created with `clear = true`: `<leader>cb` builds the current file,
     `<leader>ce` builds and runs it. Both save the buffer, open a `botright new` split
     and call `vim.fn.jobstart({ "sh", "-c", 'g++ <flags> "$1" -o "$2" [&& "$2"]', "sh",
     src, out }, { term = true })`, so paths pass as argv and never get interpolated.
     Flags: `-std=c++23 -Wall -Wextra -g -O0`. Output sits next to the source without the
     extension. The standard lives in one constant shared with `fallbackFlags`. Each
     press opens a new split; close old ones with `:q` (YAGNI, noted in the README).
     The keymaps warn and build nothing for an unnamed buffer, a header (`.h`, `.hh`,
     `.hpp`, `.hxx`, `.ipp`, `.inl`, `.tpp`), a file with no extension (its binary
     would overwrite the source), or when the output path holds anything but a readable
     ELF program (`-o` would overwrite it; `fs_stat` first, so a FIFO is never opened).
5. Run `nvim --headless "+Lazy! install"` to fetch the new plugins. Use `install`, not
   `sync`, so no existing plugin gets updated. Send its output to a log file (it prints
   hundreds of git lines and exits 0 on a failed clone). Then ask lazy.nvim itself: the
   same headless nvim then checks every plugin in `require("lazy").plugins()` whose
   `_.installed` is false, writes `Plugins not installed: ...` to the log and exits
   non-zero if any; a trailing `-c cq` makes a Lua error exit too. (A second nvim would
   rerun the whole install, since LazyVim installs missing plugins at startup.) On
   failure, show the user only the `Plugins not installed:` line and the log path. This covers every plugin the extras pull in (nvim-dap-ui,
   nvim-nio, cmake-tools.nvim and so on) without a hard-coded list.
6. Print next steps: restart any open nvim; CMake needs
   `-DCMAKE_EXPORT_COMPILE_COMMANDS=ON`; Make projects use `bear -- make`; the keymaps;
   the debug keys (`<leader>db`, `<leader>dc`).

## Safety and constraints

- Idempotent: a second run changes nothing and makes no backups.
- Back up any file before changing it (`<file>.bak.<YYYYmmdd-HHMMSS>`; never ending in
  `.lua`, so lazy.nvim does not load it). The nvim config is not under git, so backups
  are the only undo. `Lazy! install` may rewrite `lazy-lock.json` (add new pins, drop
  stale ones), so the script backs it up before the install and deletes that backup
  afterward if the file did not change.
- Write `lazyvim.json` and `cpp.lua` the same way: back up the original, write
  `mktemp "$dir/<name>.XXXXXX"` (same filesystem, so `mv` is atomic; the `XXXXXX` suffix
  means lazy.nvim never loads a stray temp file), copy the original mode onto it (0644
  for a new file), then `mv`. A `trap` removes the temp
  file if the script dies first.
- "Valid" means
  `jq -e -s 'length==1 and (.[0]|type=="object") and (.[0].extras|type=="array")'` exits
  0. Any non-zero exit refuses. This rejects an empty file, `{}`, and a file holding two
  JSON documents; `jq empty` would pass all three.
  Only after that does the script run the "extras missing?" check, so its exit 1 means
  "missing" and nothing else.
- Order: check `nvim`, `jq`, the config dir and a valid `lazyvim.json` first; then the
  package step; then file changes. Refuse with a clear message and leave files untouched
  if the config dir or `lazyvim.json` is missing, or the JSON is invalid.
- The config dir is `${XDG_CONFIG_HOME:-$HOME/.config}/nvim` and the lazy dir is
  `${XDG_DATA_HOME:-$HOME/.local/share}/nvim/lazy`, the same paths nvim uses, so the
  headless install always loads the config the script edited and the plugin check looks
  where lazy.nvim installed. The install log goes to
  `${XDG_STATE_HOME:-$HOME/.local/state}/nvim/cpp-setup-install.log`; `mkdir -p` its
  directory first, since a fresh state dir may lack `nvim/`. Tests set both
  `XDG_CONFIG_HOME` and `HOME` to a temp dir, so a bug that ignores XDG still cannot
  touch the real config. Every `nvim` in these paths becomes `$NVIM_APPNAME` when that
  is set, as nvim itself does.
- `set -euo pipefail`; shellcheck clean.
- Flags: `--no-packages`, `--no-install`, `-h`.

## Known limits

- `fallbackFlags` apply to every file clangd opens without a build system, so a lone `.c`
  file gets a "`-std=c++23` not allowed with C" diagnostic. Fix: add a
  `compile_flags.txt` or build system. Accepted, since this setup is for C++.
- Under the debugger, the program's stdin is `/dev/null` (gdb's DAP mode does this, and it
  has no run-in-terminal). Programs that read `std::cin` should run with `<leader>ce`.
  Program output shows in the dap REPL.
- No "attach to process": Omarchy's `ptrace_scope` is 1, so gdb can only debug programs
  it starts.
- If nvim is open during the run, a later `:LazyExtras` toggle there can save its stale
  extras list over the script's edit. Restart nvim after running.

## Acceptance criteria

1. On a fresh LazyVim config, one run leaves `lazyvim.json` with the old extras (in
   order), the three new ones, and every other key; `lua/plugins/cpp.lua` matches the
   repo copy.
2. A second run reports no changes and creates no backups. This also holds when
   `lazyvim.json` already has all three extras in a different layout (sorted keys, no
   trailing newline).
3. A changed `cpp.lua` gets backed up, then replaced.
3a. Package step, with `sudo` replaced by a stub on `PATH` that logs its args: a missing
   binary plus "n" at the prompt → no `sudo` call, run continues; "y" → exactly one call,
   `pacman -S --needed <that package>`; an invalid `lazyvim.json` → exit before any
   prompt or `sudo` call.
4. Missing config dir, missing `lazyvim.json`, invalid JSON, an empty file, `{}`, or two
   JSON documents in one file →
   non-zero exit, clear message, file untouched.
5. Live, in Neovim on a scratch copy of the real config and plugin dir (see Phase 3):
   - opening a `.cpp` file attaches clangd with `cmd[1]` resolving to `/usr/bin/clangd`,
     the extra's flags intact, and `fallbackFlags` = `{ "-std=c++23" }`;
   - a gdb Launch session on a `-g` hello-world stops at a breakpoint. Headless, the
     check loads nvim-dap with `require("lazy").load`, then calls `dap.run` on
     `dap.configurations.cpp[1]` with `program` filled in (the config's `vim.fn.input`
     would exit headless nvim), and waits on `dap.listeners.after.event_stopped`;
   - `LazyVim.opts("mason.nvim").ensure_installed` lacks `codelldb`, and after nvim-dap
     loads, `dap.adapters.gdb` is set and `dap.adapters.codelldb` is nil (other extras may
     add their own adapters). As a second check,
     after a wait, neither Mason's `packages/codelldb` nor `staging/codelldb` exists;
   - `<leader>cb` builds the hello-world and `<leader>ce` prints its output, including
     for a path with a space.
6. `shellcheck` passes.

## Files

| File | Purpose |
|---|---|
| `setup-nvim-cpp.sh` | The script. |
| `nvim/cpp.lua` | Plugin file the script copies to `lua/plugins/cpp.lua`. Kept apart so Lua is not buried in a heredoc. |
| `test/test-setup.sh` | Plain-bash tests for criteria 1–4, 3a and the install/check step (real nvim with a fake lazy.nvim) in a `mktemp -d` `XDG_CONFIG_HOME` and `HOME`. No bats; it is not installed. |
| `test/live-check.lua` | Criterion 5 checks, run with `nvim --headless "+luafile test/live-check.lua"`. Prints each result and quits with `qa!` when all pass, and with `cq` or a watchdog `os.exit(1)` (non-zero exit) on any failure or timeout. The checks run inside `xpcall`, so a Lua error also ends in `cq` rather than a hung headless nvim. Kept so it can rerun after LazyVim updates. |
| `README.md` | Usage, flags, keymaps, known limits. |

## Phases

1. **Tests first.** Write `test/test-setup.sh`. It builds fixture configs in a temp
   `XDG_CONFIG_HOME` and `HOME`: a `lazyvim.json` holding the neo-tree extra and a `news`
   key, with an empty `lua/plugins`; a sorted, no-newline variant already holding all
   extras; and the invalid cases from criterion 4. It must fail before the script exists.
   - Config cases (criteria 1–4) run with `--no-packages --no-install` and assert the
     exact full extra names.
   - Package cases (criterion 3a) run with `--no-install` only. `PATH` is a stub dir
     holding a logging `sudo` plus symlinks to every other tool the script needs, minus
     the one binary the test hides.
2. **Script and Lua file.** Write both until the tests pass and shellcheck is clean.
   Check the Lua parses with
   `nvim --clean -l /dev/stdin nvim/cpp.lua <<< 'assert(loadfile(arg[1]))'`
   (exit 0 on good Lua, 1 on a syntax error; it parses without running the file).
3. **Live check (criterion 5).** In a scratchpad sandbox `$S`, copy `~/.config/nvim` to
   `$S/config/nvim` and `~/.local/share/nvim/lazy` to `$S/data/nvim/lazy`. Set
   `XDG_CONFIG_HOME=$S/config`, `XDG_DATA_HOME=$S/data`, `XDG_STATE_HOME=$S/state`,
   `XDG_CACHE_HOME=$S/cache`. Run the script with `--no-packages`, then
   `test/live-check.lua`, and the keymaps by hand in the same sandbox. The real config
   stays untouched. John runs the script on his real config himself (it has no git, and
   the run needs sudo for `bear`).

## Review log

| Gate | Stage | Round | Findings |
|---|---|---|---|
| plan | a | 1 (full) | 14 (1 blocker, 8 should-fix, 5 nits); all integrated |
| plan | a | 2 (full, after heavy round 1) | 10 (6 should-fix, 4 nits); all integrated |
| plan | a | 3 (delta) | 3 (1 should-fix, 2 nits); all integrated |
| plan | a | 4 (delta) | 5 (1 should-fix, 4 nits), all implementation detail; integrated, stage closed |
| plan | b | 1 | 4 (1 blocker → wording confirmed, severity disputed; 2 should-fix; 1 nit); all integrated |
| plan | b | 2 | 2 (2 should-fix: lockfile backup, garbled Phase 1 flags); both integrated |
| plan | b | 3 (cap) | 3 (3 should-fix: pin clangd path, atomic cpp.lua, relax adapter check); all integrated |

John adjudicated the disputed b1 blocker: keep `pacman -S --needed` (Omarchy convention), with the `-Syu` hint in the prompt.

| Gate | Stage | Round | Findings |
|---|---|---|---|
| diff | a | 1 (full, 5-lens panel) | ~30 unique after dedup (0 blockers; ~18 should-fix, rest nits); 27 items integrated, 2 declined (same-second backup collision, cd before install) |
| diff | a | 2 (full, 3 merged-lens panel) | 7 should-fix + ~15 nits after dedup, 0 blockers; 17 items integrated (clangd path check done as a warning), 1 declined (dangling-symlink precheck) |
| diff | a | 3 (delta) | 2 nits (uppercase header extensions; NVIM_APPNAME/staging doc drift); both fixed, stage closed |
| diff | b | 1 | 2 should-fix (clang not offered when /usr/bin/clangd missing; errexit off inside test cases); both confirmed and fixed |
| diff | b | 2 | 3 should-fix (same-second backup overwrite; build output overwriting unrelated file; install command unasserted in tests); all confirmed and fixed |
| diff | b | 3 (cap) | 2 should-fix (output guard failed open on unreadable/FIFO paths; save-before-build untested); both confirmed and fixed; fixes not re-reviewed by Codex |

John accepted the diff gate at the Codex cap (2026-09-26), with the round-3 fixes not re-reviewed by Codex.
