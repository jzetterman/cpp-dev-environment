-- Live check for acceptance criterion 5. Run inside a LazyVim config that has
-- setup-nvim-cpp.sh applied (a sandbox copy, or the real config):
--   nvim --headless "+luafile test/live-check.lua"
-- Prints PASS/FAIL per check. Quits with qa! when all pass, cq on any failure or
-- Lua error, and os.exit(1) from a watchdog on timeout.

local failures = 0

local function report(ok, name, detail)
  if not ok then
    failures = failures + 1
  end
  local line = (ok and "PASS " or "FAIL ") .. name
  if detail and detail ~= "" then
    line = line .. " (" .. detail .. ")"
  end
  io.stdout:write(line .. "\n")
  io.stdout:flush()
end

-- Hard stop in case a synchronous call hangs the main loop.
local watchdog = vim.uv.new_timer()
watchdog:start(300000, 0, function()
  io.stdout:write("FAIL watchdog: live check took longer than 300s\n")
  io.stdout:flush()
  os.exit(1)
end)

local function write_file(path, lines)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  assert(vim.fn.writefile(lines, path) == 0, "could not write " .. path)
end

local hello_lines = {
  "#include <print>",
  "",
  "int main() {",
  '  std::println("hello from live check");',
  "  return 0;",
  "}",
}
local break_line = 4 -- the println line inside main

-- Wait for the terminal job in buf to exit; return its exit code, or nil on timeout.
-- TermClose is registered before the event loop runs again, so it cannot be missed.
local function wait_for_terminal(buf, timeout)
  local code
  vim.api.nvim_create_autocmd("TermClose", {
    buffer = buf,
    once = true,
    callback = function()
      code = vim.v.event.status
    end,
  })
  vim.wait(timeout, function()
    return code ~= nil
  end, 100)
  vim.wait(500) -- let the terminal draw the last output
  return code
end

-- Run a buffer-local mapping's Lua callback in buf; return the terminal buffer it opens.
local function run_mapping(buf, lhs)
  vim.api.nvim_set_current_buf(buf)
  local map = vim.fn.maparg(lhs, "n", false, true)
  assert(map.buffer == 1 and type(map.callback) == "function", lhs .. " has no buffer-local Lua callback")
  map.callback()
  local term = vim.api.nvim_get_current_buf()
  assert(vim.bo[term].buftype == "terminal", lhs .. " did not open a terminal")
  return term
end

local function main()
  local dir = vim.fn.tempname()
  local hello = dir .. "/hello.cpp"
  local std_check = dir .. "/std_check.cpp"
  -- A space, a quote and $HOME: naive shell or Vim interpolation breaks on each.
  local spaced = dir .. "/with space/it's $HOME.cpp"
  write_file(hello, hello_lines)
  write_file(spaced, hello_lines)
  write_file(std_check, {
    'static_assert(__cplusplus == 202302L, "not C++23");',
    "[[deprecated]] void old_fn();",
    "void use_old() { old_fn(); }",
  })

  -- a. clangd attaches with the system binary, the extra's flags and the fallback standard.
  vim.cmd.edit(vim.fn.fnameescape(hello))
  local buf = vim.api.nvim_get_current_buf()
  local client
  vim.wait(30000, function()
    client = vim.lsp.get_clients({ bufnr = buf, name = "clangd" })[1]
    return client ~= nil
  end, 100)
  report(client ~= nil, "a1 clangd attaches to a .cpp buffer")
  if client then
    local cmd = client.config.cmd
    report(type(cmd) == "table" and cmd[1] == "/usr/bin/clangd", "a2 clangd cmd[1] is /usr/bin/clangd",
      "cmd = " .. vim.inspect(cmd))
    local flags = type(cmd) == "table" and cmd or {}
    report(vim.tbl_contains(flags, "--background-index") and vim.tbl_contains(flags, "--clang-tidy"),
      "a3 clangd extra flags kept")
    local fallback = (client.config.init_options or {}).fallbackFlags
    report(vim.deep_equal(fallback, { "-std=c++23" }), "a4 fallbackFlags is { \"-std=c++23\" }",
      "fallbackFlags = " .. vim.inspect(fallback))
  end

  -- a5. End to end: clangd compiles a file with no build system as C++23. The deprecation
  -- warning proves clangd has published diagnostics; the static_assert fails below C++23.
  vim.cmd.edit(vim.fn.fnameescape(std_check))
  local std_buf = vim.api.nvim_get_current_buf()
  local published = vim.wait(30000, function()
    return #vim.diagnostic.get(std_buf) > 0
  end, 100)
  local errors = vim.diagnostic.get(std_buf, { severity = vim.diagnostic.severity.ERROR })
  report(published and #errors == 0, "a5 clangd treats a loose file as C++23",
    published and ("errors: " .. #errors .. (errors[1] and (" first: " .. errors[1].message) or ""))
      or "no diagnostics within 30s")

  -- b. Mason is not asked to install codelldb.
  local ensure = LazyVim.opts("mason.nvim").ensure_installed or {}
  report(not vim.tbl_contains(ensure, "codelldb"), "b mason ensure_installed lacks codelldb",
    table.concat(ensure, ", "))

  -- c. nvim-dap uses gdb and has no codelldb adapter.
  require("lazy").load({ plugins = { "nvim-dap" } })
  local dap = require("dap")
  report(dap.adapters.gdb ~= nil, "c1 dap.adapters.gdb is set", vim.inspect(dap.adapters.gdb))
  report(dap.adapters.codelldb == nil, "c2 dap.adapters.codelldb is nil")
  local cmake_dap = (LazyVim.opts("cmake-tools.nvim").cmake_dap_configuration or {}).type
  report(cmake_dap == "gdb", "c3 cmake-tools debugs with gdb", "type = " .. tostring(cmake_dap))

  -- d. A gdb Launch session stops at a breakpoint in main.
  local binary = dir .. "/hello"
  local build = vim.system({ "g++", "-std=c++23", "-g", "-O0", hello, "-o", binary }):wait()
  report(build.code == 0, "d1 g++ builds the hello-world", build.stderr)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_win_set_cursor(0, { break_line, 0 })
  dap.set_breakpoint()
  local stop_reason
  dap.listeners.after.event_stopped["live-check"] = function(_, body)
    stop_reason = body and body.reason or "unknown"
  end
  local config = vim.tbl_extend("force", dap.configurations.cpp[1], { program = binary })
  dap.run(config)
  vim.wait(20000, function()
    return stop_reason ~= nil
  end, 100)
  report(stop_reason == "breakpoint", "d2 gdb session stops at the breakpoint",
    "reason = " .. tostring(stop_reason))
  local frame_line
  vim.wait(5000, function()
    local session = dap.session()
    frame_line = session and session.current_frame and session.current_frame.line
    return frame_line ~= nil
  end, 100)
  report(frame_line == break_line, "d3 stopped on line " .. break_line, "frame line = " .. tostring(frame_line))
  dap.listeners.after.event_stopped["live-check"] = nil
  if dap.session() then
    dap.terminate()
  end
  local ended = vim.wait(10000, function()
    return dap.session() == nil
  end, 100)
  report(ended, "d4 debug session terminates")

  -- f. The keymaps build and run a file with a tricky path.
  vim.cmd.edit(vim.fn.fnameescape(spaced))
  local spaced_buf = vim.api.nvim_get_current_buf()
  local spaced_binary = vim.fn.fnamemodify(spaced, ":r")
  vim.fn.delete(spaced_binary)
  local term = run_mapping(spaced_buf, "<leader>cb")
  local code = wait_for_terminal(term, 30000)
  report(code == 0 and vim.fn.executable(spaced_binary) == 1, "f1 <leader>cb builds a tricky path",
    "exit = " .. tostring(code))
  term = run_mapping(spaced_buf, "<leader>ce")
  code = wait_for_terminal(term, 30000)
  local text = table.concat(vim.api.nvim_buf_get_lines(term, 0, -1, false), "\n")
  report(code == 0 and text:find("hello from live check", 1, true) ~= nil,
    "f2 <leader>ce prints the program output for a tricky path",
    "exit = " .. tostring(code) .. ", terminal: " .. vim.trim(text):gsub("\n+", " | "))

  -- f3. The keymaps save the buffer first: an unsaved edit is what gets built and run.
  local edited = '  std::println("edited in buffer only");'
  vim.api.nvim_buf_set_lines(spaced_buf, break_line - 1, break_line, false, { edited })
  term = run_mapping(spaced_buf, "<leader>ce")
  code = wait_for_terminal(term, 30000)
  text = table.concat(vim.api.nvim_buf_get_lines(term, 0, -1, false), "\n")
  report(code == 0 and text:find("edited in buffer only", 1, true) ~= nil
    and vim.tbl_contains(vim.fn.readfile(spaced), edited), "f3 <leader>ce saves and runs an unsaved edit",
    "exit = " .. tostring(code) .. ", terminal: " .. vim.trim(text):gsub("\n+", " | "))

  -- g. <leader>cb warns and builds nothing for an unnamed buffer, a header, a file with
  -- no extension (its binary would overwrite the source), or when a non-program file
  -- already sits at the output path.
  local notify = vim.notify
  local function refuses(target, name)
    local warning
    vim.notify = function(msg)
      warning = msg
    end
    vim.api.nvim_set_current_buf(target)
    local ok, err = pcall(vim.fn.maparg("<leader>cb", "n", false, true).callback)
    vim.notify = notify
    report(ok and warning ~= nil and vim.api.nvim_get_current_buf() == target, name, tostring(warning or err))
  end
  vim.cmd.enew()
  vim.api.nvim_buf_set_lines(0, 0, -1, false, hello_lines)
  vim.bo.filetype = "cpp"
  refuses(vim.api.nvim_get_current_buf(), "g1 unnamed buffer")
  local header = dir .. "/hello.hpp"
  write_file(header, { "#pragma once" })
  vim.cmd.edit(vim.fn.fnameescape(header))
  refuses(vim.api.nvim_get_current_buf(), "g2 header file")
  local noext = dir .. "/noext"
  write_file(noext, hello_lines)
  vim.cmd.edit(vim.fn.fnameescape(noext))
  vim.bo.filetype = "cpp"
  refuses(vim.api.nvim_get_current_buf(), "g3 file with no extension")
  -- g4. An unrelated file already at the output path is not overwritten.
  local other = dir .. "/notes.cpp"
  write_file(other, hello_lines)
  write_file(dir .. "/notes", { "my notes" })
  vim.cmd.edit(vim.fn.fnameescape(other))
  refuses(vim.api.nvim_get_current_buf(), "g4 existing non-program at the output path")
  vim.wait(3000) -- give a wrongly started build time to overwrite the file
  report(vim.deep_equal(vim.fn.readfile(dir .. "/notes"), { "my notes" }), "g4 that file is unchanged")
  -- g5. The same for a file that cannot be read (write-only), so it cannot be inspected.
  local locked = dir .. "/locked"
  write_file(locked .. ".cpp", hello_lines)
  write_file(locked, { "locked notes" })
  vim.uv.fs_chmod(locked, tonumber("200", 8))
  vim.cmd.edit(vim.fn.fnameescape(locked .. ".cpp"))
  refuses(vim.api.nvim_get_current_buf(), "g5 unreadable file at the output path")
  vim.wait(3000) -- give a wrongly started build time to overwrite the file
  vim.uv.fs_chmod(locked, tonumber("600", 8))
  report(vim.deep_equal(vim.fn.readfile(locked), { "locked notes" }), "g5 that file is unchanged")

  -- b2. After the slow sections, Mason has neither installed nor started installing codelldb.
  vim.wait(3000)
  local mason = vim.fn.stdpath("data") .. "/mason"
  report(vim.fn.isdirectory(mason .. "/packages/codelldb") == 0
    and vim.fn.isdirectory(mason .. "/staging/codelldb") == 0, "b2 Mason did not install codelldb")
end

local function run()
  local ok, err = xpcall(main, debug.traceback)
  if not ok then
    report(false, "lua error", err)
  end
  watchdog:stop()
  io.stdout:write(failures == 0 and "ALL PASS\n" or ("FAILED: " .. failures .. "\n"))
  io.stdout:flush()
  vim.cmd(failures == 0 and "qa!" or "cq")
end

-- "+luafile" runs before VimEnter. vim.lsp.enable only attaches to buffers opened
-- before VimEnter once startup ends, so wait for it, as a real session would.
if vim.v.vim_did_enter == 1 then
  run()
else
  vim.api.nvim_create_autocmd("VimEnter", { once = true, callback = vim.schedule_wrap(run) })
end
