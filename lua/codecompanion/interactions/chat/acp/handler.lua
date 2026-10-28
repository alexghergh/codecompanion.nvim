local Icons = require("codecompanion.interactions.chat.ui.icons")
local Queue = require("codecompanion.utils.queue")

local ansi = require("codecompanion.utils.ansi")
local async = require("codecompanion.utils.async")
local config = require("codecompanion.config")
local formatter = require("codecompanion.interactions.chat.acp.formatters")
local log = require("codecompanion.utils.log")
local markdown = require("codecompanion.utils.markdown")
local utils = require("codecompanion.utils")
local watch = require("codecompanion.interactions.shared.watch")

---@class CodeCompanion.Chat.ACPHandler
---@field chat CodeCompanion.Chat
---@field output table Standard output message from the Agent
---@field reasoning table Reasoning output from the Agent
---@field tools table<string, table> Cache of tool calls by their ID
---@field edits table<string, { path: string, line?: number }[]> Files each tool call has edited, by tool call ID
---@field ui_state table<string, table> Cache of tool call UI states (line_number, icon_id) by tool call ID
---@field output_blocks table<string, { count: number, folded: boolean }> Output blocks written below tool labels, by tool call ID
---@field _permission { queue: CodeCompanion.Queue, active: boolean, respond: function|nil } Internal state for managing permission requests
local ACPHandler = {}

---@param chat CodeCompanion.Chat
---@return CodeCompanion.Chat.ACPHandler
function ACPHandler.new(chat)
  local self = setmetatable({
    chat = chat,
    output = {},
    reasoning = {},
    tools = {},
    edits = {},
    ui_state = {},
    output_blocks = {},
    subagents = {},
    _permission = {
      active = false,
      queue = Queue.new(),
      respond = nil,
    },
  }, { __index = ACPHandler })

  return self --[[@type CodeCompanion.Chat.ACPHandler]]
end

local OUTPUT_NS = vim.api.nvim_create_namespace("CodeCompanion-acp_tool_output")
local OUTPUT_PREVIEW_LINES = 2
local SUBAGENT_INDENT = "  "

---Indent a tool's output for the chat buffer and turn its terminal escape codes into highlights;
---indented so the output can never read as markdown headings or fences
---@param output string[]
---@param indent string Extra indent, for a sub-agent's tool call
---@return string[] block
---@return { row: number, col: number, end_col: number, hl_group: string }[] colors 0-based, relative to the block
local function build_output_block(output, indent)
  local block, colors = {}, {}
  for i, line in ipairs(output) do
    local prefix = indent .. (i == 1 and "  \u{2514} " or "    ")
    local text, spans = ansi.parse(line)
    table.insert(block, prefix .. text)
    for _, span in ipairs(spans) do
      table.insert(colors, {
        row = i - 1,
        col = #prefix + span.col,
        end_col = #prefix + span.end_col,
        hl_group = span.hl_group,
      })
    end
  end
  return block, colors
end

---Does this update write the tool call's output below its label? Commands show
---their output as it arrives; any other tool only once, when it fails
---@param tool_call table
---@param was_failed boolean
---@return boolean
local function shows_output(tool_call, was_failed)
  return tool_call.kind == "execute" or (tool_call.status == "failed" and not was_failed)
end

---Merge an incoming tool call/update into the cache
---@param existing table|nil
---@param incoming table|nil
---@return table
local function merge_tool_call(existing, incoming)
  local out = vim.deepcopy(existing or {})
  for k, v in pairs(incoming or {}) do
    if v ~= vim.NIL then
      out[k] = v
    end
  end
  return out
end

---The files a tool call update edits, alongside locations and diffs
---@param tool_call table
---@return { path: string, line?: number }[]
local function touched_files(tool_call)
  local touched = {}

  for _, location in ipairs(tool_call.locations or {}) do
    table.insert(touched, { path = location.path, line = location.line })
  end
  for _, content in ipairs(tool_call.content or {}) do
    if content.type == "diff" then
      table.insert(touched, { path = content.path })
    end
  end

  return touched
end

---Submit payload to ACP, registering the request on the chat before connecting
---@param payload table The payload to send to the LLM
---@return nil
function ACPHandler:submit(payload)
  local request = {}
  request.cancel = function()
    request.cancelled = true
    if request.prompt then
      request.prompt.cancel()
    end
  end

  -- IMPORTANT: Registered before the connect below, so a second <CR> can't start a parallel submit
  self.chat.current_request = request

  -- Keep the agent's request off the main loop
  async.sync(function()
    local session_ready = self:ensure_connection() and self:ensure_session()

    -- A stop or a newer submission can replace this request while the agent boots,
    -- reporting from here would clear the handle belonging to that request
    if request.cancelled or self.chat.current_request ~= request then
      return
    end

    if not session_ready then
      self.chat.status = "error"
      return self.chat:done(self.output)
    end

    request.prompt = self:create_and_send_prompt(payload)
  end)()
end

---Ensure the ACP connection is authenticated
---@return boolean
function ACPHandler:ensure_connection()
  -- If the async init already created the connection, check if it's ready
  if self.chat.acp_connection and self.chat.acp_connection:is_ready() then
    return true
  end

  if not self.chat.acp_connection then
    local adapter = self.chat.adapter --[[@as CodeCompanion.ACPAdapter]]
    self.chat.acp_connection = require("codecompanion.acp").new({
      adapter = adapter,
      chat = self.chat,
    })
  end

  local connected = self.chat.acp_connection:connect_and_authenticate()

  if not connected then
    return false
  end

  self.chat:update_metadata()
  watch.enable()
  utils.fire("ACPConnected", { bufnr = self.chat.bufnr })

  return true
end

---Ensure a session exists on the connection or create one if required
---@return boolean success
function ACPHandler:ensure_session()
  local conn = self.chat.acp_connection
  if not conn then
    return false
  end

  if conn.session_id then
    return true
  end

  if not conn:ensure_session() then
    return false
  end

  -- Map bufnr -> session_id so completion providers can look up ACP commands for this buffer
  local acp_commands = require("codecompanion.interactions.chat.acp.commands")
  acp_commands.link_buffer_to_session(self.chat.bufnr, conn.session_id)

  self.chat:update_metadata()

  require("codecompanion.interactions.chat.acp.defaults").apply(self.chat.adapter, conn)

  return true
end

---Transform ACP commands in messages from \command to /command
---@param messages table The messages to transform
---@return table The transformed messages
function ACPHandler:transform_acp_commands(messages)
  if not self.chat.acp_connection or not self.chat.acp_connection.session_id then
    return messages
  end

  -- Get available ACP commands for this session
  local acp_commands = require("codecompanion.interactions.chat.acp.commands")
  local commands = acp_commands.get_commands_for_session(self.chat.acp_connection.session_id)

  if #commands == 0 then
    return messages
  end

  -- Get trigger character
  local trigger = "\\"
  if config.interactions.chat.slash_commands.opts and config.interactions.chat.slash_commands.opts.acp then
    trigger = config.interactions.chat.slash_commands.opts.acp.trigger or "\\"
  end
  local escaped_trigger = vim.pesc(trigger)

  -- Transform messages by replacing each known command
  local transformed = vim.deepcopy(messages)
  for _, message in ipairs(transformed) do
    if message.content and type(message.content) == "string" then
      -- Replace \command with /command for each known ACP command
      for _, cmd in ipairs(commands) do
        local escaped_name = vim.pesc(cmd.name)

        -- Pattern with trailing space
        local pattern_space = escaped_trigger .. escaped_name .. "(%s)"
        message.content = message.content:gsub(pattern_space, "/" .. cmd.name .. "%1")

        -- Pattern at end of string or followed by non-word character
        local pattern_end = escaped_trigger .. escaped_name .. "([^%w])"
        message.content = message.content:gsub(pattern_end, "/" .. cmd.name .. "%1")

        -- Pattern at end of string
        local pattern_eol = escaped_trigger .. escaped_name .. "$"
        message.content = message.content:gsub(pattern_eol, "/" .. cmd.name)
      end
    end
  end

  return transformed
end

---Create and configure the prompt request with all handlers
---@param payload table
---@return table Request object
function ACPHandler:create_and_send_prompt(payload)
  -- Transform ACP commands before sending
  local transformed_payload = vim.deepcopy(payload)
  transformed_payload.messages = self:transform_acp_commands(payload.messages)

  return self.chat.acp_connection
    :session_prompt(transformed_payload.messages)
    :on_message_chunk(function(content, opts)
      self:handle_message_chunk(content, opts)
    end)
    :on_thought_chunk(function(content)
      self:handle_thought_chunk(content)
    end)
    :on_tool_call(function(tool_call, opts)
      self:process_tool_call(tool_call, opts)
    end)
    :on_tool_update(function(tool_call, opts)
      self:process_tool_call(tool_call, opts)
    end)
    :on_permission_request(function(request)
      self:handle_permission_request(request)
    end)
    :on_subagent(function(update)
      self:process_subagent(update)
    end)
    :on_complete(function()
      self:handle_complete()
    end)
    :on_error(function(error)
      self:handle_error(error)
    end)
    :on_cancel(function()
      self:_clear_permission_queue()
    end)
    :on_turn_done(function(stop_reason)
      self.chat:_queued_turn_started(stop_reason)
    end)
    :with_options({ bufnr = self.chat.bufnr, interaction = "chat" })
    :send()
end

---Handle incoming message chunks
---@param content string
---@param opts? { message_id?: string }
---@return nil
function ACPHandler:handle_message_chunk(content, opts)
  opts = opts or {}

  -- Agents can send several messages in one turn (Codex does, around its server-side tools);
  -- without a break the end of one runs straight into the start of the next
  if opts.message_id then
    if self._message_id and self._message_id ~= opts.message_id then
      content = "\n\n" .. content
    end
    self._message_id = opts.message_id
  end

  table.insert(self.output, content)
  self.chat:add_buf_message(
    { role = config.constants.LLM_ROLE, content = content },
    { type = self.chat.MESSAGE_TYPES.LLM_MESSAGE }
  )
end

---Handle incoming thought chunks
---@param content string
---@return nil
function ACPHandler:handle_thought_chunk(content)
  table.insert(self.reasoning, content)
  if config.display.chat.show_reasoning then
    self.chat:add_buf_message(
      { role = config.constants.LLM_ROLE, content = content },
      { type = self.chat.MESSAGE_TYPES.REASONING_MESSAGE }
    )
  end
end

---Remember the files a tool call names, as a later update can arrive without them
---@param id string
---@param tool_call table
---@return nil
function ACPHandler:track_edits(id, tool_call)
  local edits = self.edits[id] or {}

  for _, file in ipairs(touched_files(tool_call)) do
    local existing = vim.iter(edits):find(function(edit)
      return edit.path == file.path
    end)

    if existing then
      existing.line = existing.line or file.line
    elseif type(file.path) == "string" and file.path ~= "" then
      table.insert(edits, file)
    end
  end

  self.edits[id] = edits
end

---Release a finished tool call's files, firing an event for each one it edited
---@param id string
---@param tool_call table
---@return nil
function ACPHandler:flush_edits(id, tool_call)
  if tool_call.status ~= "completed" and tool_call.status ~= "failed" then
    return
  end

  local edits = self.edits[id]
  self.edits[id] = nil

  if tool_call.status == "failed" or tool_call.kind ~= "edit" then
    return
  end

  for _, file in ipairs(edits or {}) do
    utils.fire("FileEdited", { path = file.path, tool = self.chat.adapter.name, line = file.line })
  end
end

---Render a tool call's output below its label: a short preview, then the rest
---in a fold that reads "+N lines" when closed. Written directly to the buffer (not
---through the builder) so the block stays out of the streamed message flow and
---its block/type tracking; each update replaces the previous block
---@param id string
---@param tool_call table
---@param label_line number 1-based line holding the tool label
---@param indent string Extra indent, for a sub-agent's tool call
---@return nil
function ACPHandler:_render_output(id, tool_call, label_line, indent)
  local output = formatter.output_lines(tool_call)
  if #output == 0 then
    return
  end

  local block, colors = build_output_block(output, indent)

  local bufnr = self.chat.bufnr
  local folds = self.chat.ui.folds
  local previous = self.output_blocks[id] or { count = 0, folded = false }
  local fold_row = label_line + OUTPUT_PREVIEW_LINES
  local was_open = previous.folded and folds:is_open(bufnr, fold_row)
  local was_following = self.chat.ui:is_following()
  local hl_group = tool_call.status == "failed" and "CodeCompanionChatToolError" or "CodeCompanionChatToolOutput"

  self.chat.ui:unlock_buf()
  vim.api.nvim_buf_clear_namespace(bufnr, OUTPUT_NS, label_line, label_line + previous.count)
  -- Delete before inserting: replacing lines in place keeps the old fold, so each update would nest another
  vim.api.nvim_buf_set_lines(bufnr, label_line, label_line + previous.count, false, {})
  -- Parallel tool calls write their labels first, so the output lands right above the next label
  local next_line = vim.api.nvim_buf_get_lines(bufnr, label_line, label_line + 1, false)[1]
  local spacer = next_line ~= nil and next_line ~= "" and { "" } or {}
  vim.api.nvim_buf_set_lines(bufnr, label_line, label_line, false, vim.list_extend(vim.list_slice(block), spacer))
  -- priority above treesitter (100) and below the status icons (120)
  vim.api.nvim_buf_set_extmark(bufnr, OUTPUT_NS, label_line, 0, {
    end_row = label_line + #block - 1,
    end_col = #block[#block],
    hl_group = hl_group,
    priority = 110,
  })
  -- Terminal colors draw over the dimmed block, still below the status icons
  for _, color in ipairs(colors) do
    vim.api.nvim_buf_set_extmark(bufnr, OUTPUT_NS, label_line + color.row, color.col, {
      end_col = color.end_col,
      hl_group = color.hl_group,
      priority = 115,
    })
  end
  self.chat.ui:lock_buf()

  -- A one-line fold never displays closed ('foldminlines'), so it would read as opened by the user
  local folded = #block > OUTPUT_PREVIEW_LINES + 1
  if folded then
    folds:create_output_fold(bufnr, fold_row, label_line + #block - 1, { hl_group = hl_group, open = was_open })
  end
  self.output_blocks[id] = { count = #block + #spacer, folded = folded }

  self.chat.ui:move_cursor(was_following)
end

---Output tool call to the chat
---@param tool_call table
---@param opts? { subagent?: string } The sub-agent session the tool call came from
---@return nil
function ACPHandler:process_tool_call(tool_call, opts)
  local id = tool_call.toolCallId
  local indent = opts and opts.subagent and SUBAGENT_INDENT or ""

  -- An update for a tool call never seen before, without a title or status,
  -- has nothing to show; claude-agent-acp hides its Agent tool calls once the
  -- client supports sub-agents, but still sends one such update for each
  if not self.tools[id] and not self.ui_state[id] and not tool_call.title and not tool_call.status then
    return
  end

  -- Render error output only on the transition into failed; agents may send
  -- further updates for an already-failed call
  local was_failed = self.tools[id] ~= nil and self.tools[id].status == "failed"

  local merged = merge_tool_call(self.tools[id], tool_call)

  -- codex-acp 2.x sends command output only as `_meta.terminal_output_delta`
  -- chunks, one per update; the merge replaces `_meta`, so append each chunk
  -- it also sends newline-only chunks the command never printed, alongside its usage updates
  local delta = vim.tbl_get(tool_call, "_meta", "terminal_output_delta", "data")
  if type(delta) == "string" and not delta:match("^\n+$") then
    merged.streamed_output = (merged.streamed_output or "") .. delta
  end
  tool_call = merged

  self:track_edits(id, tool_call)

  -- Cache or cleanup
  if tool_call.status == "completed" then
    self.tools[id] = nil
  else
    self.tools[id] = merged
  end

  self:flush_edits(id, tool_call)

  local ok, content = pcall(formatter.tool_message, tool_call, self.chat.adapter)
  if not ok then
    content = "[Error formatting tool output]"
  end

  local line_number = self:_write_status_line(
    id,
    content,
    tool_call.status,
    indent,
    { tools = { call_id = id }, kind = tool_call.kind }
  )

  if line_number and shows_output(tool_call, was_failed) then
    self:_render_output(id, tool_call, line_number, indent)
  end
end

---Write a status line with a status icon to the chat, or rewrite the line already written for `id`
---@param id string
---@param content string
---@param status? string
---@param indent string Drawn before the status icon
---@param opts? table Extra options for a new line, passed to `add_buf_message()`
---@return number|nil line_number 1-based
function ACPHandler:_write_status_line(id, content, status, indent, opts)
  indent = indent ~= "" and indent or nil
  local cached = self.ui_state[id]
  if cached then
    -- The cached line number goes stale when content is inserted above it
    -- (e.g. approval feedback anchored to its prompt block); the icon extmark
    -- shifts with the buffer, so resolve the current line from it
    local line_number = cached.line_number
    if cached.icon_id then
      local pos = vim.api.nvim_buf_get_extmark_by_id(self.chat.bufnr, Icons.ns(), cached.icon_id, {})
      if pos and pos[1] then
        line_number = pos[1] + 1
      end
    end

    local call_ok, update_ok, new_icon_id = pcall(
      self.chat.update_buf_line,
      self.chat,
      line_number,
      content,
      { status = status, icon_id = cached.icon_id, priority = 120, virt_text_pos = "inline", indent = indent }
    )

    if call_ok and update_ok then
      if status == "completed" then
        self.ui_state[id] = nil
      elseif new_icon_id then
        cached.icon_id = new_icon_id
      end
      return line_number
    end

    if status == "completed" then
      self.ui_state[id] = nil
    end
    log:debug("[ACP::Handler] Failed to update the status line for %s", id)
  end

  local line_number, icon_id = self.chat:add_buf_message(
    { role = config.constants.LLM_ROLE, content = content },
    vim.tbl_extend("force", {
      status = status or "in_progress",
      virt_text_pos = "inline",
      indent = indent,
      type = self.chat.MESSAGE_TYPES.TOOL_MESSAGE,
    }, opts or {})
  )

  self.ui_state[id] = { line_number = line_number, icon_id = icon_id }
  return line_number
end

---Show a sub-agent as one status line: in progress once it starts, then completed or failed
---@param update table A `subagent_spawned` or `subagent_state_update` session update
---@return nil
function ACPHandler:process_subagent(update)
  local sid = update.subagentSessionId
  if type(sid) ~= "string" then
    return
  end

  if update.sessionUpdate == "subagent_spawned" then
    -- `task` is left out: claude-agent-acp sends the sub-agent's whole prompt
    -- there, codex-acp "Delegated task for <name>"
    local label = "Sub-agent: " .. (type(update.name) == "string" and update.name or "")
    self.subagents[sid] = label
    self:_write_status_line("subagent:" .. sid, label, "in_progress", "")
    return
  end

  -- the update only carries an end state: completed, failed, cancelled or disconnected
  local label = self.subagents[sid]
  if not label then
    return
  end
  local state = update.state
  local status = state == "completed" and "completed" or "failed"
  if state ~= "completed" and type(state) == "string" then
    label = ("%s (%s)"):format(label, state)
  end
  self:_write_status_line("subagent:" .. sid, label, status, "")
end

---Queue a permission request and process when ready
---@param request table
---@return nil
function ACPHandler:handle_permission_request(request)
  self._permission.queue:push(request)
  self:_process_next_permission()
end

---Pop the next permission request from the queue and present it
---@return nil
function ACPHandler:_process_next_permission()
  if self._permission.active or self._permission.queue:is_empty() then
    return
  end

  self._permission.active = true
  local request = self._permission.queue:pop()

  -- Merge cached tool call data so the diff UI can activate
  local tool_call = request.tool_call
  if
    type(tool_call) == "table"
    and tool_call.toolCallId
    and (tool_call.content == nil or tool_call.content == vim.NIL)
  then
    local cached = self.tools[tool_call.toolCallId]
    if cached then
      request.tool_call = merge_tool_call(cached, tool_call)
    end
  end

  -- The original respond function is stored so that if the user cancels the request, we can respond as per the spec
  self._permission.respond = request.respond

  -- Ensure that the next item in the queue is processed after the user's response
  local send_response = request.respond
  request.respond = function(option_id, cancelled)
    if not self._permission.respond then
      return
    end
    send_response(option_id, cancelled)
    self._permission.active = false
    self._permission.respond = nil
    self:_process_next_permission()
  end

  return require("codecompanion.interactions.chat.acp.request_permission").confirm(self.chat, request)
end

---Clear any requests in the queue
---@return nil
function ACPHandler:_clear_permission_queue()
  local had_pending = self._permission.respond ~= nil or not self._permission.queue:is_empty()

  -- Cancel the currently active permission request (if any)
  if self._permission.respond then
    pcall(self._permission.respond, nil, true)
    self._permission.respond = nil
  end

  -- Cancel all queued permission requests
  while not self._permission.queue:is_empty() do
    local request = self._permission.queue:pop()
    pcall(request.respond, nil, true)
  end
  self._permission.active = false

  if had_pending then
    utils.fire("ToolApprovalFinished", { bufnr = self.chat.bufnr, choice = "cancelled" })
  end
end

---Handle the prompt response when it's complete
---@return nil
function ACPHandler:handle_complete()
  self:_clear_permission_queue()

  if not self.chat.status or self.chat.status == "" then
    self.chat.status = "success"
  end

  self.chat:done(self.output, self.reasoning, {})
end

---Handle errors
---@param error string
---@return nil
function ACPHandler:handle_error(error)
  self:_clear_permission_queue()

  self.chat.status = "error"
  log:error("[ACP::Handler] %s", error)

  self.chat:add_buf_message(
    { role = config.constants.LLM_ROLE, content = "\n" .. markdown.form_codeblock(error, { ft = "txt" }) },
    { type = self.chat.MESSAGE_TYPES.LLM_MESSAGE }
  )

  self.chat:done(self.output, nil, nil, nil, { error = error })
end

return ACPHandler
