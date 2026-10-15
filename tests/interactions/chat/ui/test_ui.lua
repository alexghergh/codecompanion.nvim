local h = require("tests.helpers")

local new_set = MiniTest.new_set
local child = MiniTest.new_child_neovim()

local T = new_set({
  hooks = {
    pre_case = function()
      h.child_start(child)
      child.lua([[
        h = require('tests.helpers')
        vim.o.columns = 200
        vim.o.lines = 50
        _G.chat = h.setup_chat_buffer({
          display = { chat = { window = { layout = "vertical", width = 0.3, full_height = false } } },
        })
        _G.chat.ui:hide()

        -- Three side by side windows with uneven widths
        vim.cmd("only")
        vim.cmd("vsplit")
        vim.cmd("vsplit")
        _G.wins = vim.api.nvim_tabpage_list_wins(0)
        vim.api.nvim_win_set_width(_G.wins[1], 30)
        vim.api.nvim_win_set_width(_G.wins[2], 50)
        vim.api.nvim_set_current_win(_G.wins[3])

        ---The widths of the windows that are not the chat
        _G.other_widths = function()
          local widths = {}
          for _, winnr in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
            if vim.api.nvim_win_get_buf(winnr) ~= _G.chat.bufnr then
              table.insert(widths, vim.api.nvim_win_get_width(winnr))
            end
          end
          return widths
        end
      ]])
    end,
    post_case = function()
      child.lua([[h.teardown_chat_buffer()]])
    end,
    post_once = child.stop,
  },
})

T["Chat UI"] = new_set()

T["Chat UI"]["takes the space for a full height chat ONLY from the widest window"] = function()
  local widths = child.lua([[
    require("codecompanion.config").display.chat.window.full_height = true
    _G.chat.ui:open()
    return other_widths()
  ]])

  h.eq({ 30, 50 }, vim.list_slice(widths, 1, 2))
end

T["Chat UI"]["restores the layout when a split chat hides"] = function()
  local widths = child.lua([[
    local before = other_widths()
    _G.chat.ui:open()
    _G.chat.ui:hide()
    return { before = before, after = other_widths() }
  ]])

  h.eq(widths.before, widths.after)
end

T["Chat UI"]["reopens a split chat at the size it was left at"] = function()
  local width = child.lua([[
    _G.chat.ui:open()
    vim.api.nvim_win_set_width(_G.chat.ui.winnr, 40)
    _G.chat.ui:hide()
    vim.api.nvim_set_current_win(_G.wins[3])
    _G.chat.ui:open()
    return vim.api.nvim_win_get_width(_G.chat.ui.winnr)
  ]])

  h.eq(40, width)
end

return T
