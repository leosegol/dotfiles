-- Swift / Objective-C support for Xcode projects.
-- LSP: sourcekit-lsp (Swift) + clangd (ObjC/C/C++).
-- Compile flags come from buildServer.json, generated per-project with:
--   xcode-build-server config -project <Foo.xcodeproj> -scheme <Foo>

local sourcekit_path = "/usr/bin/sourcekit-lsp"
if vim.fn.executable("xcrun") == 1 then
  local resolved = vim.fn.system({ "xcrun", "--find", "sourcekit-lsp" })
  if vim.v.shell_error == 0 then
    sourcekit_path = vim.trim(resolved)
  end
end

return {
  -- Treesitter parsers
  {
    "nvim-treesitter/nvim-treesitter",
    opts = function(_, opts)
      opts.ensure_installed = opts.ensure_installed or {}
      vim.list_extend(opts.ensure_installed, { "swift", "objc" })
    end,
  },

  -- LSP servers
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        sourcekit = {
          mason = false,
          cmd = { sourcekit_path },
          filetypes = { "swift", "objc", "objcpp" },
          root_dir = function(bufnr, on_dir)
            local util = require("lspconfig.util")
            local fname = vim.api.nvim_buf_get_name(bufnr)
            on_dir(
              util.root_pattern("buildServer.json", ".bsp")(fname)
                or util.root_pattern("*.xcodeproj", "*.xcworkspace")(fname)
                or util.root_pattern("compile_commands.json", "Package.swift")(fname)
                or vim.fs.dirname(vim.fs.find(".git", { path = fname, upward = true })[1])
            )
          end,
          capabilities = {
            workspace = {
              didChangeWatchedFiles = { dynamicRegistration = true },
            },
          },
        },
        clangd = {
          cmd = {
            "clangd",
            "--background-index",
            "--clang-tidy",
            "--header-insertion=iwyu",
            "--completion-style=detailed",
            "--function-arg-placeholders=1",
          },
          filetypes = { "c", "cpp" },
          root_markers = {
            "compile_commands.json",
            "compile_flags.txt",
            "buildServer.json",
            ".clangd",
            ".git",
          },
        },
      },
    },
  },

  -- swiftformat via conform.nvim (LazyVim's default formatter manager).
  {
    "stevearc/conform.nvim",
    optional = true,
    opts = {
      formatters_by_ft = {
        swift = { "swiftformat" },
        objc = { "clang-format" },
        objcpp = { "clang-format" },
        c = { "clang-format" },
        cpp = { "clang-format" },
      },
      formatters = {
        ["clang-format"] = {
          command = "xcrun",
          prepend_args = { "clang-format" },
        },
      },
    },
  },

  -- Build/run/test Xcode projects from inside nvim.
  {
    "wojciech-kulik/xcodebuild.nvim",
    dependencies = {
      "nvim-telescope/telescope.nvim",
      "MunifTanjim/nui.nvim",
    },
    cmd = {
      "XcodebuildSetup",
      "XcodebuildPicker",
      "XcodebuildBuild",
      "XcodebuildRun",
      "XcodebuildTest",
      "XcodebuildTestClass",
      "XcodebuildSelectScheme",
      "XcodebuildSelectDestination",
      "XcodebuildSelectDevice",
      "XcodebuildToggleLogs",
      "XcodebuildCleanBuild",
    },
    keys = {
      { "<leader>X",  "",                                  desc = "+Xcode" },
      { "<leader>Xb", "<cmd>XcodebuildBuild<cr>",          desc = "Build project" },
      { "<leader>Xr", "<cmd>XcodebuildRun<cr>",            desc = "Run project" },
      { "<leader>Xt", "<cmd>XcodebuildTest<cr>",           desc = "Run tests" },
      { "<leader>XT", "<cmd>XcodebuildTestClass<cr>",      desc = "Run current test class" },
      { "<leader>Xs", "<cmd>XcodebuildSelectScheme<cr>",   desc = "Select scheme" },
      { "<leader>Xd", "<cmd>XcodebuildSelectDestination<cr>", desc = "Select destination" },
      { "<leader>Xl", "<cmd>XcodebuildToggleLogs<cr>",     desc = "Toggle build logs" },
      { "<leader>Xp", "<cmd>XcodebuildPicker<cr>",         desc = "Xcodebuild action picker" },
    },
    opts = {
      logs = {
        auto_open_on_failed_tests = true,
        auto_open_on_failed_build = true,
      },
      code_coverage = { enabled = false },
    },
  },
}
