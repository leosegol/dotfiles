-- Directory picker used by ~/.local/scripts/tmux-sessionizer.sh.
--
-- Reads newline-separated absolute paths from $TMUX_SESSIONIZER_LIST, writes
-- the chosen one to $TMUX_SESSIONIZER_OUT, then quits nvim. Writing nothing
-- means "cancelled", which the caller treats as a no-op.

local M = {}

local function lines_of(path)
  local out = {}
  local fd = path and io.open(path, "r")
  if not fd then
    return out
  end
  for line in fd:lines() do
    if line ~= "" then
      out[#out + 1] = line
    end
  end
  fd:close()
  return out
end

local function quit(out_path, choice)
  if out_path and choice and choice ~= "" then
    local fd = io.open(out_path, "w")
    if fd then
      fd:write(choice, "\n")
      fd:close()
    end
  end
  vim.cmd("qa!")
end

-- Show paths relative to the root; the ~/dev/ prefix is noise on every line.
local function label(dir, root)
  if root ~= "" and dir:sub(1, #root + 1) == root .. "/" then
    return dir:sub(#root + 2)
  end
  return dir
end

local function with_snacks(items, opts)
  local ok, snacks = pcall(require, "snacks")
  if not ok or not snacks.picker then
    return false
  end

  -- `picker:close()` runs on_close synchronously, so confirm has to claim
  -- `done` *before* closing or the cancel path would overwrite the selection.
  local done = false

  return pcall(snacks.picker.pick, {
    items = items,
    format = function(item)
      return { { item.text } }
    end,
    title = opts.title,
    layout = { preset = "select" },
    confirm = function(picker, item)
      if done then
        return
      end
      done = true
      picker:close()
      vim.schedule(function()
        quit(opts.out, item and item.dir)
      end)
    end,
    on_close = function()
      if done then
        return
      end
      done = true
      vim.schedule(function()
        quit(opts.out, nil)
      end)
    end,
  })
end

local function with_telescope(items, opts)
  local ok, pickers = pcall(require, "telescope.pickers")
  if not ok then
    return false
  end
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  return pcall(function()
    pickers
      .new({}, {
        prompt_title = opts.title,
        finder = finders.new_table({
          results = items,
          entry_maker = function(item)
            return { value = item.dir, display = item.text, ordinal = item.text }
          end,
        }),
        sorter = conf.generic_sorter({}),
        attach_mappings = function(bufnr)
          actions.select_default:replace(function()
            local entry = action_state.get_selected_entry()
            actions.close(bufnr)
            vim.schedule(function()
              quit(opts.out, entry and entry.value)
            end)
          end)
          return true
        end,
      })
      :find()
  end)
end

local function with_ui_select(items, opts)
  vim.ui.select(items, {
    prompt = opts.title,
    format_item = function(item)
      return item.text
    end,
  }, function(item)
    quit(opts.out, item and item.dir)
  end)
end

function M.pick()
  local opts = {
    out = vim.env.TMUX_SESSIONIZER_OUT,
    title = "dev sessions",
  }
  local root = vim.env.TMUX_SESSIONIZER_ROOT or ""
  local dirs = lines_of(vim.env.TMUX_SESSIONIZER_LIST)
  if #dirs == 0 then
    return quit(opts.out, nil)
  end

  local items = {}
  for i, dir in ipairs(dirs) do
    items[i] = { dir = dir, text = label(dir, root), idx = i }
  end

  -- Deferred so lazy-loaded pickers are available by the time we ask for them.
  vim.schedule(function()
    if with_snacks(items, opts) then
      return
    end
    if with_telescope(items, opts) then
      return
    end
    with_ui_select(items, opts)
  end)
end

return M
