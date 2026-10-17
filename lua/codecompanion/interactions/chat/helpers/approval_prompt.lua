local Icons = require("codecompanion.interactions.chat.ui.icons")
local config = require("codecompanion.config")
local labels = require("codecompanion.interactions.chat.tools.labels")
local log = require("codecompanion.utils.log")
local markdown = require("codecompanion.utils.markdown")
local ui_utils = require("codecompanion.utils.ui")
local utils = require("codecompanion.utils")

local fmt = string.format

local ANCHOR_NS = vim.api.nvim_create_namespace("CodeCompanion-approval_anchor")
local NOTICE_NS = vim.api.nvim_create_namespace("CodeCompanion-approval_notice")

local NOTICE_HL = {
  info = "CodeCompanionChatApprovalInfo",
  warning = "CodeCompanionChatApprovalWarning",
}

local M = {}

---@param notice CodeCompanion.ACPAdapter.SandboxNotice
---@return string
local function format_notice(notice)
  local icon = notice.level == "warning" and config.display.icons.warning or ""
  return icon .. notice.text
end

---Build the markdown content for the approval prompt
---@param opts table
---@return string
local function build_message(opts)
  local title = opts.title or "Approval Required"
  local lines = { "", "", "---", "**" .. title .. "**" }
  if opts.notice then
    table.insert(lines, format_notice(opts.notice))
  end
  table.insert(lines, "")

  if opts.prompt then
    table.insert(lines, opts.prompt)
    table.insert(lines, "")
  end

  table.insert(lines, "Please select an option:")
  for _, choice in ipairs(opts.choices) do
    table.insert(lines, fmt("- `%s` - %s", choice.keymap, choice.label))
  end

  table.insert(lines, "")
  -- table.insert(lines, "---")
  table.insert(lines, "")

  return table.concat(lines, "\n")
end

---Clean up keymaps set for the approval prompt
---@param bufnr number
---@param choices table
local function cleanup_keymaps(bufnr, choices)
  for _, choice in ipairs(choices) do
    pcall(vim.keymap.del, "n", choice.keymap, { buffer = bufnr })
  end
end

---@class CodeCompanion.Chat.ApprovalChoice
---@field keymap string The keymap to trigger this choice
---@field label string Display label (e.g. "Always accept")
---@field callback function Called when the user selects this choice
---@field preview? boolean When true, the callback fires but the approval prompt stays active (e.g. "View")

---Request approval from the user via the chat buffer
---@param chat CodeCompanion.Chat
---@param opts { id: string|number, title?: string, prompt?: string, notice?: CodeCompanion.ACPAdapter.SandboxNotice, name?: string, choices: CodeCompanion.Chat.ApprovalChoice[] }
---@return fun(choice_label: string) on_done Callback to finalize the prompt from external code (e.g. diff keymaps)
function M.request(chat, opts)
  local bufnr = chat.bufnr

  utils.fire("ToolApprovalRequested", { bufnr = bufnr, name = opts.name })

  local content = build_message(opts)
  local prompt_end = chat:add_buf_message({ role = config.constants.LLM_ROLE, content = content })

  if prompt_end and opts.notice then
    local notice_line = format_notice(opts.notice)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, prompt_end, false)
    for row = #lines, 1, -1 do
      if lines[row] == notice_line then
        local hl_group = NOTICE_HL[opts.notice.level]
        vim.api.nvim_buf_set_extmark(bufnr, NOTICE_NS, row - 1, 0, { end_col = #notice_line, hl_group = hl_group })
        -- A warning colors the title above it too
        if opts.notice.level == "warning" then
          vim.api.nvim_buf_set_extmark(bufnr, NOTICE_NS, row - 2, 0, { end_col = #lines[row - 1], hl_group = hl_group })
        end
        break
      end
    end
  end

  -- Anchor the eventual feedback to the prompt block: the agent keeps
  -- streaming (e.g. tool labels of already-approved calls) while the user
  -- decides, so writing the feedback at the buffer end can land it below
  -- unrelated content. The anchor must sit on the last non-blank prompt line
  -- (the choice list): the builder trims trailing blank runs before streamed
  -- writes and merges chunk text into the tail line, so an anchor on a
  -- trailing blank gets deleted or acquires streamed content
  local anchor_id
  if prompt_end then
    local row = prompt_end - 1
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, prompt_end, false)
    while row > 0 and (lines[row + 1] == nil or lines[row + 1] == "") do
      row = row - 1
    end
    anchor_id = vim.api.nvim_buf_set_extmark(bufnr, ANCHOR_NS, row, 0, { right_gravity = false })
  end

  if config.interactions.chat.tools.opts.notify_on_approval and not ui_utils.buf_is_active(bufnr) then
    utils.notify("Tool approval required")
  end

  local resolved = false

  ---Function to call when the user has made a choice
  ---@param choice_label string
  ---@return nil
  local function on_done(choice_label)
    -- Guard against multiple calls
    if resolved then
      return
    end
    resolved = true
    cleanup_keymaps(bufnr, opts.choices)
    local is_rejection = labels.is_rejection(choice_label)
    local icons = config.display.chat.icons
    local icon = is_rejection and icons.tool_failure or icons.tool_success
    local status = is_rejection and "failed" or "completed"
    local insert_at
    if anchor_id then
      local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, ANCHOR_NS, anchor_id, {})
      pcall(vim.api.nvim_buf_del_extmark, bufnr, ANCHOR_NS, anchor_id)
      if pos and pos[1] then
        insert_at = pos[1] + 1
      end
    end
    if insert_at then
      -- Whole-line insert directly below the choice list: `nvim_buf_set_text`
      -- through the builder would splice into the target line and glue the
      -- "---" onto streamed chunk text, so the feedback goes in via
      -- `nvim_buf_set_lines`, which never merges. Content that streamed in
      -- below the prompt stays below the "---", separated by a blank when it
      -- did not bring its own
      insert_at = math.min(insert_at, vim.api.nvim_buf_line_count(bufnr))
      local below = vim.api.nvim_buf_get_lines(bufnr, insert_at, insert_at + 1, false)[1]
      local feedback = { "", fmt("%sYou selected: %s", icon, choice_label), "", "---" }
      if below ~= nil and below ~= "" then
        table.insert(feedback, "")
      end
      chat.ui:unlock_buf()
      vim.api.nvim_buf_set_lines(bufnr, insert_at, insert_at, false, feedback)
      Icons.apply(bufnr, insert_at + 1, status)
      chat.ui:lock_buf()
    else
      chat:add_buf_message(
        { content = fmt("%sYou selected: %s\n\n---\n", icon, choice_label) },
        { _icon_info = { has_icon = true, status = status } }
      )
    end
    utils.fire("ToolApprovalFinished", { bufnr = bufnr, choice = choice_label })
  end

  for _, choice in ipairs(opts.choices) do
    vim.keymap.set("n", choice.keymap, function()
      if resolved then
        return
      end

      if not choice.preview then
        on_done(choice.label)
      end

      log:debug("[approval_prompt] User selected: %s", choice.label)

      choice.callback()
    end, {
      buffer = bufnr,
      desc = choice.label,
      silent = true,
      nowait = true,
    })
  end

  return on_done
end

---Present the diff to the user
---@param opts { chat_bufnr: number, from_lines: string[], to_lines: string[], title: string, approve: fun(prompt_opts: table), open_diff_view: fun() }
function M.present_diff(opts)
  local diff_utils = require("codecompanion.diff.utils")

  local changed_lines = diff_utils.changed_lines(opts.from_lines, opts.to_lines)
  local threshold = config.display.diff.threshold_for_chat
  local threshold_met = threshold and threshold > 0 and changed_lines > 0 and changed_lines <= threshold

  if threshold_met then
    -- Show small diffs in the chat buffer
    local diff_text = diff_utils.unified(opts.from_lines, opts.to_lines)
    local prompt = markdown.form_codeblock(diff_text, { ft = "diff" })
    return opts.approve({ title = opts.title, prompt = prompt })
  elseif ui_utils.buf_is_active(opts.chat_bufnr) then
    -- If the chat is active, show the diff in the floating window
    opts.approve({ title = opts.title })
    return opts.open_diff_view()
  else
    -- Otherwise, don't force the diff on the user, just show the approval
    return opts.approve({ title = opts.title })
  end
end

return M
