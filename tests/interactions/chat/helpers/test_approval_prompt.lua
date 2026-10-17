local h = require("tests.helpers")

local new_set = MiniTest.new_set
local child = MiniTest.new_child_neovim()

local T = new_set({
  hooks = {
    pre_case = function()
      h.child_start(child)
      child.lua([[
        h = require("tests.helpers")
        _G.chat = h.setup_chat_buffer()
        _G.approval_prompt = require("codecompanion.interactions.chat.helpers.approval_prompt")
        _G.chat:add_buf_message({ role = "llm", content = "Execute: ls" })

        ---Ask for approval, with the choices the chat offers for a command
        ---@param opts? { notice?: { text: string, level: "warning"|"info" } }
        _G.request = function(opts)
          opts = opts or {}
          return approval_prompt.request(chat, {
            id = 1,
            notice = opts.notice,
            prompt = "Execute:\n```bash\nls\n```",
            choices = {
              { keymap = "g2", label = "Accept", callback = function() end },
              { keymap = "g3", label = "Reject", callback = function() end },
            },
          })
        end
      ]])
    end,
    post_case = function()
      child.lua([[h.teardown_chat_buffer()]])
    end,
    post_once = child.stop,
  },
})

T["Approval prompt"] = new_set()

T["Approval prompt"]["shows the sandbox notice under the title, highlighted for its level"] = function()
  local result = child.lua([[
    request({ notice = { text = "Runs outside the sandbox", level = "warning" } })
    local lines = vim.api.nvim_buf_get_lines(chat.bufnr, 0, -1, false)
    for i, line in ipairs(lines) do
      if line:find("Runs outside the sandbox", 1, true) then
        local groups = {}
        for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(chat.bufnr, -1, { i - 1, 0 }, { i - 1, -1 }, { details = true })) do
          table.insert(groups, mark[4].hl_group)
        end
        local title_groups = {}
        for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(chat.bufnr, -1, { i - 2, 0 }, { i - 2, -1 }, { details = true })) do
          table.insert(title_groups, mark[4].hl_group)
        end
        return { above = lines[i - 1], groups = groups, title_groups = title_groups }
      end
    end
  ]])

  h.eq("**Approval Required**", result.above)
  h.eq(true, vim.tbl_contains(result.groups, "CodeCompanionChatApprovalWarning"))
  -- a warning colors the title too
  h.eq(true, vim.tbl_contains(result.title_groups, "CodeCompanionChatApprovalWarning"))
end

return T
