-- Directory picker used by ~/.local/scripts/tmux-sessionizer.sh.
--
-- Reads "<label><TAB><path>" lines from $TMUX_SESSIONIZER_LIST, writes the
-- chosen path to $TMUX_SESSIONIZER_OUT, then quits nvim. Writing nothing means
-- "cancelled", which the caller treats as a no-op.
--
-- In the snacks picker, <Tab> descends into the highlighted directory and
-- <S-Tab> comes back up. The children come from the script itself
-- (`tmux-sessionizer --children <dir>`) so discovery lives in exactly one place.

local M = {}

local state = {
  out = nil,
  root = "",
  self = nil,
  -- The raw candidate lines, kept so walking back up to the root can rebuild
  -- the full list. Stored as text rather than items on purpose: snacks keeps
  -- match state on the item tables, so handing the same tables to a second
  -- picker leaves it unable to match anything (every query returns 0 results).
  top_lines = {},
}

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

local function quit(choice)
  if state.out and choice and choice ~= "" then
    local fd = io.open(state.out, "w")
    if fd then
      fd:write(choice, "\n")
      fd:close()
    end
  end
  vim.cmd("qa!")
end

-- Show paths relative to the root; the ~/dev/ prefix is noise on every line.
local function label(dir)
  local root = state.root
  if root ~= "" and dir:sub(1, #root + 1) == root .. "/" then
    return dir:sub(#root + 2)
  end
  return dir
end

local function parse(lines)
  local items = {}
  for i, line in ipairs(lines) do
    -- Tolerate a bare path, so a stale script and this file can't deadlock.
    local text, dir = line:match("^(.*)\t(.*)$")
    if not dir or dir == "" then
      text, dir = label(line), line
    end
    items[#items + 1] = { dir = dir, text = text, idx = i }
  end
  return items
end

local function under_root(dir)
  if state.root == "" then
    return false
  end
  return dir == state.root or dir:sub(1, #state.root + 1) == state.root .. "/"
end

local function parent_of(dir)
  local trimmed = (dir:gsub("/+$", ""))
  local parent = vim.fn.fnamemodify(trimmed, ":h")
  if parent == trimmed or parent == "" or parent == "." or parent == "/" then
    return nil
  end
  return parent
end

-- nil means the top-level list; anything else is a directory we drilled into.
-- Always returns freshly built items, never a table a previous picker has seen.
local function items_for(dir)
  if not dir then
    return parse(state.top_lines)
  end
  if not state.self or state.self == "" then
    return nil
  end
  local lines = vim.fn.systemlist({ state.self, "--children", dir })
  if vim.v.shell_error ~= 0 then
    return nil
  end
  local items = parse(lines)
  return #items > 0 and items or nil
end

local function title_for(dir)
  if not dir then
    return "dev sessions"
  end
  return "dev › " .. label(dir)
end

local open -- forward declaration: the pickers below reopen through it

local function with_snacks(items, viewdir)
  local ok, snacks = pcall(require, "snacks")
  if not ok or not snacks.picker then
    return false
  end

  -- `picker:close()` runs on_close synchronously, so anything that closes the
  -- picker has to claim `done` *first* or the cancel path overwrites it.
  local done = false

  -- Navigating means closing this picker and opening a fresh one over `dir`.
  -- A directory with nothing in it is a no-op: <Tab> on a leaf does nothing
  -- rather than dropping you into an empty list.
  local function navigate(picker, dir)
    if dir == state.root then
      dir = nil
    end
    local next_items = items_for(dir)
    if not next_items then
      return
    end
    done = true
    picker:close()
    vim.schedule(function()
      open(next_items, dir)
    end)
  end

  return pcall(snacks.picker.pick, {
    items = items,
    format = function(item)
      return { { item.text } }
    end,
    title = title_for(viewdir),
    layout = { preset = "select" },
    confirm = function(picker, item)
      if done then
        return
      end
      done = true
      picker:close()
      vim.schedule(function()
        quit(item and item.dir)
      end)
    end,
    on_close = function()
      if done then
        return
      end
      done = true
      vim.schedule(function()
        quit(nil)
      end)
    end,
    actions = {
      tsz_descend = function(picker, item)
        if item and item.dir then
          navigate(picker, item.dir)
        end
      end,
      tsz_ascend = function(picker)
        -- Bounded at the root: past it there is nothing we know how to list.
        if not viewdir then
          return
        end
        local parent = parent_of(viewdir)
        if parent and under_root(parent) then
          navigate(picker, parent)
        end
      end,
    },
    win = {
      input = {
        keys = {
          ["<Tab>"] = { "tsz_descend", mode = { "n", "i" } },
          ["<S-Tab>"] = { "tsz_ascend", mode = { "n", "i" } },
        },
      },
    },
  })
end

local function with_telescope(items, viewdir)
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
        prompt_title = title_for(viewdir),
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
              quit(entry and entry.value)
            end)
          end)
          return true
        end,
      })
      :find()
  end)
end

local function with_ui_select(items, viewdir)
  vim.ui.select(items, {
    prompt = title_for(viewdir),
    format_item = function(item)
      return item.text
    end,
  }, function(item)
    quit(item and item.dir)
  end)
end

-- Only snacks gets <Tab>/<S-Tab>; the fallbacks show the flat list, which
-- already includes every worktree.
open = function(items, viewdir)
  if with_snacks(items, viewdir) then
    return
  end
  if with_telescope(items, viewdir) then
    return
  end
  with_ui_select(items, viewdir)
end

function M.pick()
  state.out = vim.env.TMUX_SESSIONIZER_OUT
  state.root = vim.env.TMUX_SESSIONIZER_ROOT or ""
  state.self = vim.env.TMUX_SESSIONIZER_SELF
  state.top_lines = lines_of(vim.env.TMUX_SESSIONIZER_LIST)

  if #state.top_lines == 0 then
    return quit(nil)
  end

  -- Deferred so lazy-loaded pickers are available by the time we ask for them.
  vim.schedule(function()
    open(items_for(nil), nil)
  end)
end

return M
