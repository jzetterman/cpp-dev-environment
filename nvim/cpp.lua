-- C++ setup for LazyVim, installed by setup-nvim-cpp.sh as lua/plugins/cpp.lua.
-- Rerunning the script replaces local edits to this file (it keeps a backup first).
-- It layers on the clangd, cmake and dap.core extras through opts functions only:
-- a `config` key on nvim-dap would replace dap.core's own setup.

-- README.md and test/live-check.lua also name C++23; change them together.
local cpp_standard = "c++23"
local build_flags = { "-Wall", "-Wextra", "-g", "-O0" }

-- Extend LazyVim's clangd extra while keeping its command-line flags.
local function configure_lsp(_, opts)
  opts.servers = opts.servers or {}
  opts.servers.clangd = opts.servers.clangd or {}
  local clangd = opts.servers.clangd
  clangd.mason = false
  clangd.cmd = clangd.cmd or { "clangd" }
  -- Absolute path, because Mason puts its bin dir first on PATH. Only element 1
  -- changes, so the extra's flags stay.
  clangd.cmd[1] = "/usr/bin/clangd"
  clangd.init_options = clangd.init_options or {}
  clangd.init_options.fallbackFlags = { "-std=" .. cpp_standard }
end

-- Replace the clangd extra's adapter with gdb's native DAP mode.
local function configure_dap()
  local dap = require("dap")
  dap.adapters.gdb = {
    type = "executable",
    command = "gdb",
    args = { "--interpreter=dap", "-q" },
  }
  -- Otherwise mason-nvim-dap sees the adapter and installs codelldb.
  dap.adapters.codelldb = nil
  for _, language in ipairs({ "c", "cpp" }) do
    dap.configurations[language] = {
      {
        type = "gdb",
        request = "launch",
        name = "Launch",
        program = function()
          return vim.fn.input("Path to executable: ", vim.fn.expand("%:p:r"), "file")
        end,
        cwd = "${workspaceFolder}",
      },
    }
  end
end

-- Exclude codelldb from Mason's automatic installation list.
local function configure_mason(_, opts)
  opts.ensure_installed = vim.tbl_filter(function(package)
    return package ~= "codelldb"
  end, opts.ensure_installed or {})
end

-- Files these keymaps will not build: headers (they would compile to a precompiled
-- header) and files with no extension (the binary would overwrite the source).
local skip_extensions = {
  [""] = true, h = true, hh = true, hpp = true, hxx = true, ipp = true, inl = true, tpp = true,
}

-- Save the buffer and build or run it in a fresh terminal split.
local function build_and_run(run)
  local source = vim.fn.expand("%:p")
  if source == "" then
    vim.notify("Save this buffer to a file before building it.", vim.log.levels.WARN)
    return
  end
  if skip_extensions[vim.fn.expand("%:e"):lower()] then
    vim.notify("Only source files like .cpp build here, not headers or files with no extension.",
      vim.log.levels.WARN)
    return
  end
  local output = vim.fn.expand("%:p:r")
  -- g++ -o overwrites whatever sits at the output path. Only replace a program (ELF).
  -- fs_stat first, so a FIFO is never opened (that would block) and anything we cannot
  -- inspect is refused, not overwritten.
  local stat = vim.uv.fs_stat(output)
  if stat then
    local magic
    local existing = stat.type == "file" and io.open(output, "rb")
    if existing then
      magic = existing:read(4)
      existing:close()
    end
    if magic ~= "\127ELF" then
      vim.notify(vim.fn.fnamemodify(output, ":t") .. " exists and is not a program built here; rename it or the source.",
        vim.log.levels.WARN)
      return
    end
  end
  vim.cmd.update()
  local script = "g++ -std=" .. cpp_standard .. " " .. table.concat(build_flags, " ") .. ' "$1" -o "$2"'
  if run then
    script = script .. ' && "$2"'
  end
  vim.cmd("botright new")
  vim.fn.jobstart({ "sh", "-c", script, "sh", source, output }, { term = true })
end

local cpp_group = vim.api.nvim_create_augroup("CppBuildRun", { clear = true })
vim.api.nvim_create_autocmd("FileType", {
  group = cpp_group,
  pattern = "cpp",
  callback = function(event)
    vim.keymap.set("n", "<leader>cb", function()
      build_and_run(false)
    end, { buffer = event.buf, desc = "Build C++ file" })
    vim.keymap.set("n", "<leader>ce", function()
      build_and_run(true)
    end, { buffer = event.buf, desc = "Build and run C++ file" })
  end,
})

return {
  {
    "neovim/nvim-lspconfig",
    opts = configure_lsp,
  },
  {
    "mfussenegger/nvim-dap",
    optional = true, -- extend it only when the dap.core extra is on; never install it alone
    opts = configure_dap,
  },
  {
    "mason-org/mason.nvim",
    opts = configure_mason,
  },
  {
    -- The cmake extra's cmake-tools.nvim debugs with codelldb by default.
    "Civitasv/cmake-tools.nvim",
    optional = true, -- as for nvim-dap: only when the cmake extra is on
    opts = {
      cmake_dap_configuration = {
        name = "cpp",
        type = "gdb",
        request = "launch",
        stopOnEntry = false,
        runInTerminal = false,
      },
    },
  },
}
