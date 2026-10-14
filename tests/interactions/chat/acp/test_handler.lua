local h = require("tests.helpers")

local new_set = MiniTest.new_set
local T = new_set()

local child = MiniTest.new_child_neovim()
T = new_set({
  hooks = {
    pre_once = function()
      h.child_start(child)
      child.lua([[h = require('tests.helpers')]])
      child.lua([[mocks_acp = require("tests.mocks.acp")]])
    end,
    pre_case = function()
      child.lua([[
        _G.last_prompt_request = nil
        _G.last_permission_request = nil
        _G.codecompanion_chat_metadata = {}
        package.loaded["codecompanion.acp"] = nil
      ]])
    end,
    post_once = function()
      child.lua([[
        _G.last_prompt_request = nil
        _G.last_permission_request = nil
        _G.codecompanion_chat_metadata = nil

        -- Reset modules that tests may have overridden
        package.loaded["codecompanion.acp"] = nil
        package.loaded["codecompanion.interactions.chat.acp.request_permission"] = nil
        package.loaded["codecompanion.interactions.chat.acp.handler"] = nil
        package.loaded["codecompanion.interactions.chat.acp.commands"] = nil
        package.loaded["codecompanion.interactions.chat"] = nil
        package.loaded["codecompanion.config"] = nil
      ]])
      child.stop()
    end,
  },
})

T["ACPHandler"] = new_set()

T["ACPHandler"]["establishes connection when needed"] = function()
  local result = child.lua([[
    local chat = h.setup_chat_buffer({}, {
      name = "test_acp",
      config = {
        name = "test_acp",
        type = "acp",
        handlers = {
          form_messages = function(adapter, messages)
            return vim.tbl_map(function(msg)
              return { type = "text", text = msg.content }
            end, messages)
          end
        }
      }
    })

    local ACPHandler = require("codecompanion.interactions.chat.acp.handler")
    local handler = ACPHandler.new(chat)

    local conn = mocks_acp.new()
    package.loaded["codecompanion.acp"] = {
      new = function() return conn end
    }

    handler:submit({
      messages = {{ type = "text", text = "Hello" }}
    })

    return {
      has_connection = chat.acp_connection ~= nil,
      is_ready = chat.acp_connection:is_ready(),
      session_id = chat.acp_connection.session_id,
      request_sent = _G.last_prompt_request ~= nil
    }
  ]])

  h.is_true(result.has_connection)
  h.is_true(result.is_ready)
  h.eq("test-session-123", result.session_id)
  h.is_true(result.request_sent)
end

T["ACPHandler"]["handles streaming message chunks"] = function()
  local result = child.lua([[
    local chat = h.setup_chat_buffer({}, {
      name = "test_acp",
      config = {
        name = "test_acp",
        type = "acp",
        handlers = { form_messages = function(a, m) return m end }
      }
    })

    local ACPHandler = require("codecompanion.interactions.chat.acp.handler")
    local handler = ACPHandler.new(chat)

    -- Track what gets added to the buffer
    local buffer_messages = {}
    chat.add_buf_message = function(self, data, opts)
      table.insert(buffer_messages, { data = data, opts = opts })
    end

    -- Simulate message chunk handling
    handler:handle_message_chunk("Hello ")
    handler:handle_message_chunk("there!")

    return {
      message_count = #buffer_messages,
      first_content = buffer_messages[1].data.content,
      second_content = buffer_messages[2].data.content,
      message_type = buffer_messages[1].opts.type
    }
  ]])

  h.eq(2, result.message_count)
  h.eq("Hello ", result.first_content)
  h.eq("there!", result.second_content)
  h.eq("llm_message", result.message_type)
end

T["ACPHandler"]["starts a new paragraph when the agent starts a NEW message"] = function()
  local contents = child.lua([[
    local chat = h.setup_chat_buffer({}, {
      name = "test_acp",
      config = {
        name = "test_acp",
        type = "acp",
        handlers = { form_messages = function(a, m) return m end }
      }
    })
    local handler = require("codecompanion.interactions.chat.acp.handler").new(chat)

    local contents = {}
    chat.add_buf_message = function(self, data)
      table.insert(contents, data.content)
    end

    handler:handle_message_chunk("I'll check ", { message_id = "msg_1" })
    handler:handle_message_chunk("the time.", { message_id = "msg_1" })
    handler:handle_message_chunk("It's 1 PM.", { message_id = "msg_2" })
    return contents
  ]])

  h.eq({ "I'll check ", "the time.", "\n\nIt's 1 PM." }, contents)
end

T["ACPHandler"]["handles thought chunks"] = function()
  local result = child.lua([[
    local chat = h.setup_chat_buffer({}, {
      name = "test_acp",
      config = {
        name = "test_acp",
        type = "acp",
        handlers = { form_messages = function(a, m) return m end }
      }
    })

    local ACPHandler = require("codecompanion.interactions.chat.acp.handler")
    local handler = ACPHandler.new(chat)

    local buffer_messages = {}
    chat.add_buf_message = function(self, data, opts)
      table.insert(buffer_messages, { data = data, opts = opts })
    end

    -- Simulate thought chunk handling
    handler:handle_thought_chunk("Let me think about this...")
    handler:handle_thought_chunk("I need to consider...")

    return {
      message_count = #buffer_messages,
      first_content = buffer_messages[1].data.content,
      message_type = buffer_messages[1].opts.type,
      reasoning_collected = #handler.reasoning
    }
  ]])

  h.eq(2, result.message_count)
  h.eq("Let me think about this...", result.first_content)
  h.eq("reasoning_message", result.message_type)
  h.eq(2, result.reasoning_collected)
end

T["ACPHandler"]["suppresses thought chunks when show_reasoning is false"] = function()
  local result = child.lua([[
    local chat = h.setup_chat_buffer({
      display = {
        chat = {
          show_reasoning = false
        }
      }
    }, {
      name = "test_acp",
      config = {
        name = "test_acp",
        type = "acp",
        handlers = { form_messages = function(a, m) return m end }
      }
    })

    local ACPHandler = require("codecompanion.interactions.chat.acp.handler")
    local handler = ACPHandler.new(chat)

    local buffer_messages = {}
    chat.add_buf_message = function(self, data, opts)
      table.insert(buffer_messages, { data = data, opts = opts })
    end

    handler:handle_thought_chunk("Let me think about this...")
    handler:handle_thought_chunk("I need to consider...")

    return {
      message_count = #buffer_messages,
      reasoning_collected = #handler.reasoning
    }
  ]])

  h.eq(0, result.message_count)
  h.eq(2, result.reasoning_collected)
end

T["ACPHandler"]["coordinates completion flow"] = function()
  local result = child.lua([[
    local chat = h.setup_chat_buffer({}, {
      name = "test_acp",
      config = {
        name = "test_acp",
        type = "acp",
        handlers = { form_messages = function(a, m) return m end }
      }
    })

    local ACPHandler = require("codecompanion.interactions.chat.acp.handler")
    local handler = ACPHandler.new(chat)

    -- Track completion calls
    local completion_data = {}
    chat.done = function(self, output, reasoning, tools)
      completion_data = { output = output, reasoning = reasoning, tools = tools }
    end

    -- Simulate full interaction
    handler:handle_message_chunk("Response part 1")
    handler:handle_message_chunk(" and part 2")
    handler:handle_thought_chunk("My reasoning")
    handler:handle_complete("end_turn")

    return {
      status = chat.status,
      final_output = completion_data.output,
      final_reasoning = completion_data.reasoning,
      final_tools = completion_data.tools
    }
  ]])

  h.eq("success", result.status)
  h.eq({ "Response part 1", " and part 2" }, result.final_output)
  h.eq({ "My reasoning" }, result.final_reasoning)
  h.eq({}, result.final_tools)
end

T["ACPHandler"]["handles connection errors"] = function()
  local result = child.lua([[
    local chat = h.setup_chat_buffer({}, {
      name = "test_acp",
      config = {
        name = "test_acp",
        type = "acp",
        handlers = { form_messages = function(a, m) return m end }
      }
    })

    local ACPHandler = require("codecompanion.interactions.chat.acp.handler")
    local handler = ACPHandler.new(chat)

    -- Mock connection failure
    local conn = mocks_acp.new()
    conn.connect_and_authenticate = function() return nil end
    package.loaded["codecompanion.acp"] = {
      new = function() return conn end
    }

    local completion_called = false
    chat.done = function(self, output)
      completion_called = true
    end

    local request = handler:submit({
      messages = {{ type = "text", text = "Hello" }}
    })

    return {
      status = chat.status,
      completion_called = completion_called,
      request_returned = request
    }
  ]])

  h.eq("error", result.status)
  h.is_true(result.completion_called)
  h.eq(nil, result.request_returned)
end

T["ACPHandler"]["passes the agent's error to on_completed"] = function()
  local result = child.lua([[
    local chat = h.setup_chat_buffer({}, {
      name = "test_acp",
      config = {
        name = "test_acp",
        type = "acp",
        handlers = { form_messages = function(a, m) return m end }
      }
    })

    local completion
    chat:add_callback("on_completed", function(_, args)
      completion = args
    end)

    local handler = require("codecompanion.interactions.chat.acp.handler").new(chat)
    handler:handle_error("The agent exited unexpectedly")

    return completion
  ]])

  h.eq("error", result.status)
  h.eq("The agent exited unexpectedly", result.error)
end

T["ACPHandler"]["integrates with chat submit flow"] = function()
  local result = child.lua([[
    -- Create chat with ACP adapter
    local chat = h.setup_chat_buffer({}, {
      name = "test_acp",
      config = {
        name = "test_acp",
        type = "acp",
        handlers = { form_messages = function(a, m) return m end }
      }
    })

    local conn = mocks_acp.new()
    package.loaded["codecompanion.acp"] = {
      new = function() return conn end
    }

    -- Add a user message to submit
    chat:add_message({
      role = "user",
      content = "Test ACP submission"
    })

    -- Track the submission
    local submitted_payload = nil
    local original_submit_acp = chat._submit_acp
    chat._submit_acp = function(self, payload)
      submitted_payload = payload
      return original_submit_acp(self, payload)
    end

    -- Submit the chat - this should use ACP pathway
    chat:submit()

    return {
      adapter_type = chat.adapter.type,
      payload_submitted = submitted_payload ~= nil,
      has_messages = submitted_payload and #submitted_payload.messages > 0,
      last_prompt_set = _G.last_prompt_request ~= nil
    }
  ]])

  h.eq("acp", result.adapter_type)
  h.is_true(result.payload_submitted)
  h.is_true(result.has_messages)
  h.is_true(result.last_prompt_set)
end

T["ACPHandler"]["hydrates permission request with cached diff tool_call"] = function()
  local result = child.lua([[
    local chat = h.setup_chat_buffer({}, {
      name = "test_acp",
      config = {
        name = "test_acp",
        type = "acp",
        handlers = { form_messages = function(a, m) return m end }
      }
    })

    local ACPHandler = require("codecompanion.interactions.chat.acp.handler")
    local handler = ACPHandler.new(chat)

    -- Pre-populate cache with a diff tool call
    local id = "toolu_abc123"
    handler.tools[id] = {
      toolCallId = id,
      kind = "edit",
      status = "pending",
      title = "Edit `/tmp/file.txt`",
      content = {
        { type = "diff", path = "/tmp/file.txt", oldText = "old", newText = "new" }
      },
    }

    -- Stub the permission UI to capture the request
    _G.last_permission_request = nil
    package.loaded["codecompanion.interactions.chat.acp.request_permission"] = {
      confirm = function(chat_arg, request)
        _G.last_permission_request = request
      end
    }

    -- Simulate a permission request that only includes toolCallId
    handler:handle_permission_request({
      tool_call = { toolCallId = id },
      options = {
        { kind = "allow_once", optionId = "allow", name = "Allow" },
        { kind = "reject_once", optionId = "reject", name = "Reject" },
      }
    })

    local req = _G.last_permission_request
    return {
      hydrated = req ~= nil and req.tool_call ~= nil and req.tool_call.content ~= nil,
      toolCallId = req and req.tool_call and req.tool_call.toolCallId or nil,
      diff_type = req and req.tool_call and req.tool_call.content and req.tool_call.content[1] and req.tool_call.content[1].type or nil,
      newText = req and req.tool_call and req.tool_call.content and req.tool_call.content[1] and req.tool_call.content[1].newText or nil,
    }
  ]])

  h.is_true(result.hydrated)
  h.eq("toolu_abc123", result.toolCallId)
  h.eq("diff", result.diff_type)
  h.eq("new", result.newText)
end

T["ACPHandler"]["permission request passes through when toolCallId unknown"] = function()
  local result = child.lua([[
    local chat = h.setup_chat_buffer({}, {
      name = "test_acp",
      config = {
        name = "test_acp",
        type = "acp",
        handlers = { form_messages = function(a, m) return m end }
      }
    })

    local ACPHandler = require("codecompanion.interactions.chat.acp.handler")
    local handler = ACPHandler.new(chat)

    -- Stub the permission UI to capture the request
    _G.last_permission_request = nil
    package.loaded["codecompanion.interactions.chat.acp.request_permission"] = {
      confirm = function(chat_arg, request)
        _G.last_permission_request = request
      end
    }

    -- Simulate a permission request that references an unknown toolCallId
    handler:handle_permission_request({
      tool_call = { toolCallId = "unknown_tool_id" },
      options = {
        { kind = "allow_once", optionId = "allow", name = "Allow" },
        { kind = "reject_once", optionId = "reject", name = "Reject" },
      }
    })

    local req = _G.last_permission_request
    return {
      has_request = req ~= nil,
      has_tool_call = req and req.tool_call ~= nil,
      has_content = req and req.tool_call and req.tool_call.content ~= nil,
      toolCallId = req and req.tool_call and req.tool_call.toolCallId or nil,
    }
  ]])

  h.is_true(result.has_request)
  h.is_true(result.has_tool_call)
  h.is_false(result.has_content)
  h.eq("unknown_tool_id", result.toolCallId)
end

T["ACPHandler"]["transforms ACP commands in messages"] = function()
  local result = child.lua([[
    local chat = h.setup_chat_buffer({}, {
      name = "test_acp",
      config = {
        name = "test_acp",
        type = "acp",
        handlers = { form_messages = function(a, m) return m end }
      }
    })

    local ACPHandler = require("codecompanion.interactions.chat.acp.handler")
    local handler = ACPHandler.new(chat)

    -- Setup mock connection with session
    chat.acp_connection = {
      session_id = "test-session-123"
    }

    -- Register available ACP commands
    local commands = require("codecompanion.interactions.chat.acp.commands")
    commands.register_commands("test-session-123", {
      { name = "cost", description = "Show costs" },
      { name = "context", description = "Manage context" },
    })

    -- Test transformation
    local messages = {
      { content = "\\cost" },
      { content = "\\context --detailed" },
      { content = "Regular text with \\backslash" },
      { content = "\\cost at end" },
    }

    local transformed = handler:transform_acp_commands(messages)

    return {
      first = transformed[1].content,
      second = transformed[2].content,
      third = transformed[3].content,
      fourth = transformed[4].content,
    }
  ]])

  h.eq("/cost", result.first)
  h.eq("/context --detailed", result.second)
  h.eq("Regular text with \\backslash", result.third) -- Unknown command not transformed
  h.eq("/cost at end", result.fourth)
end

T["ACPHandler"]["only transforms known ACP commands"] = function()
  local result = child.lua([[
    local chat = h.setup_chat_buffer({}, {
      name = "test_acp",
      config = {
        name = "test_acp",
        type = "acp",
        handlers = { form_messages = function(a, m) return m end }
      }
    })

    local ACPHandler = require("codecompanion.interactions.chat.acp.handler")
    local handler = ACPHandler.new(chat)

    chat.acp_connection = {
      session_id = "test-session-456"
    }

    -- Register only 'cost' command
    local commands = require("codecompanion.interactions.chat.acp.commands")
    commands.register_commands("test-session-456", {
      { name = "cost", description = "Show costs" },
    })

    local messages = {
      { content = "\\cost is known" },
      { content = "\\unknown is not" },
    }

    local transformed = handler:transform_acp_commands(messages)

    return {
      first = transformed[1].content,
      second = transformed[2].content,
    }
  ]])

  h.eq("/cost is known", result.first)
  h.eq("\\unknown is not", result.second) -- Unknown command preserved
end

T["ACPHandler"]["handles no registered commands"] = function()
  local result = child.lua([[
    local chat = h.setup_chat_buffer({}, {
      name = "test_acp",
      config = {
        name = "test_acp",
        type = "acp",
        handlers = { form_messages = function(a, m) return m end }
      }
    })

    local ACPHandler = require("codecompanion.interactions.chat.acp.handler")
    local handler = ACPHandler.new(chat)

    chat.acp_connection = {
      session_id = "test-session-789"
    }

    -- No commands registered for this session

    local messages = {
      { content = "\\cost should not transform" },
    }

    local transformed = handler:transform_acp_commands(messages)

    return {
      content = transformed[1].content,
    }
  ]])

  h.eq("\\cost should not transform", result.content)
end

T["ACPHandler"]["handles no connection"] = function()
  local result = child.lua([[
    local chat = h.setup_chat_buffer({}, {
      name = "test_acp",
      config = {
        name = "test_acp",
        type = "acp",
        handlers = { form_messages = function(a, m) return m end }
      }
    })

    local ACPHandler = require("codecompanion.interactions.chat.acp.handler")
    local handler = ACPHandler.new(chat)

    -- No connection established

    local messages = {
      { content = "\\cost" },
    }

    local transformed = handler:transform_acp_commands(messages)

    return {
      content = transformed[1].content,
    }
  ]])

  h.eq("\\cost", result.content)
end

T["ACPHandler"]["Edited Files"] = new_set()

T["ACPHandler"]["Edited Files"]["fires FileEdited when an edit tool call completes"] = function()
  local result = child.lua([[
    local chat = h.setup_chat_buffer({}, {
      name = "test_acp",
      config = {
        name = "test_acp",
        type = "acp",
        handlers = { form_messages = function(a, m) return m end }
      }
    })

    local ACPHandler = require("codecompanion.interactions.chat.acp.handler")
    local handler = ACPHandler.new(chat)
    chat.add_buf_message = function() end

    local events = {}
    vim.api.nvim_create_autocmd("User", {
      pattern = "CodeCompanionFileEdited",
      callback = function(args)
        table.insert(events, args.data)
      end,
    })

    -- Replays the update sequence Claude Code sends for a direct-to-disk edit
    local id = "toolu_0145UJoLG4Q6dsWnaTu8fr3n"
    handler:process_tool_call({
      toolCallId = id,
      sessionUpdate = "tool_call",
      status = "pending",
      title = "Edit",
      kind = "edit",
      content = {},
      locations = {},
    })
    handler:process_tool_call({
      toolCallId = id,
      sessionUpdate = "tool_call_update",
      title = "Edit version.txt",
      kind = "edit",
      content = {
        { type = "diff", path = "/tmp/version.txt", oldText = "19.20.0", newText = "19.21.0" },
      },
      locations = { { path = "/tmp/version.txt" } },
    })
    handler:process_tool_call({
      toolCallId = id,
      sessionUpdate = "tool_call_update",
      content = {
        { type = "diff", path = "/tmp/version.txt", oldText = "19.20.0", newText = "19.21.0" },
      },
      locations = { { path = "/tmp/version.txt", line = 1 } },
    })
    handler:process_tool_call({
      toolCallId = id,
      sessionUpdate = "tool_call_update",
      status = "completed",
      rawOutput = "The file /tmp/version.txt has been updated successfully.",
    })

    return {
      event_count = #events,
      path = events[1] and events[1].path,
      line = events[1] and events[1].line,
      tool = events[1] and events[1].tool,
    }
  ]])

  h.eq(1, result.event_count)
  h.eq("/tmp/version.txt", result.path)
  h.eq(1, result.line)
  h.eq("test_acp", result.tool)
end

T["ACPHandler"]["Edited Files"]["fires FileEdited when a later update empties the locations"] = function()
  local result = child.lua([[
    local chat = h.setup_chat_buffer({}, {
      name = "test_acp",
      config = {
        name = "test_acp",
        type = "acp",
        handlers = { form_messages = function(a, m) return m end }
      }
    })

    local ACPHandler = require("codecompanion.interactions.chat.acp.handler")
    local handler = ACPHandler.new(chat)
    chat.add_buf_message = function() end

    local events = {}
    vim.api.nvim_create_autocmd("User", {
      pattern = "CodeCompanionFileEdited",
      callback = function(args)
        table.insert(events, args.data)
      end,
    })

    local id = "toolu_emptied"
    handler:process_tool_call({
      toolCallId = id,
      sessionUpdate = "tool_call",
      status = "in_progress",
      kind = "edit",
      locations = { { path = "/tmp/kept.lua", line = 12 } },
    })
    -- The completing update carries empty arrays, which would otherwise stand for the real ones
    handler:process_tool_call({
      toolCallId = id,
      sessionUpdate = "tool_call_update",
      status = "completed",
      content = {},
      locations = {},
    })

    return {
      event_count = #events,
      path = events[1] and events[1].path,
      line = events[1] and events[1].line,
    }
  ]])

  h.eq(1, result.event_count)
  h.eq("/tmp/kept.lua", result.path)
  h.eq(12, result.line)
end

T["ACPHandler"]["Edited Files"]["falls back to diff content when locations are absent"] = function()
  local result = child.lua([[
    local chat = h.setup_chat_buffer({}, {
      name = "test_acp",
      config = {
        name = "test_acp",
        type = "acp",
        handlers = { form_messages = function(a, m) return m end }
      }
    })

    local ACPHandler = require("codecompanion.interactions.chat.acp.handler")
    local handler = ACPHandler.new(chat)
    chat.add_buf_message = function() end

    local events = {}
    vim.api.nvim_create_autocmd("User", {
      pattern = "CodeCompanionFileEdited",
      callback = function(args)
        table.insert(events, args.data)
      end,
    })

    handler:process_tool_call({
      toolCallId = "toolu_diff_only",
      sessionUpdate = "tool_call",
      status = "completed",
      kind = "edit",
      content = {
        { type = "diff", path = "/tmp/a.lua", oldText = "a", newText = "b" },
      },
    })

    return {
      event_count = #events,
      path = events[1] and events[1].path,
      line = events[1] and events[1].line,
    }
  ]])

  h.eq(1, result.event_count)
  h.eq("/tmp/a.lua", result.path)
  h.eq(nil, result.line)
end

T["ACPHandler"]["Edited Files"]["ignores failed edits and non-edit tool calls"] = function()
  local result = child.lua([[
    local chat = h.setup_chat_buffer({}, {
      name = "test_acp",
      config = {
        name = "test_acp",
        type = "acp",
        handlers = { form_messages = function(a, m) return m end }
      }
    })

    local ACPHandler = require("codecompanion.interactions.chat.acp.handler")
    local handler = ACPHandler.new(chat)
    chat.add_buf_message = function() end

    local events = {}
    vim.api.nvim_create_autocmd("User", {
      pattern = "CodeCompanionFileEdited",
      callback = function(args)
        table.insert(events, args.data)
      end,
    })

    handler:process_tool_call({
      toolCallId = "toolu_failed",
      sessionUpdate = "tool_call",
      status = "failed",
      kind = "edit",
      locations = { { path = "/tmp/failed.lua" } },
    })
    handler:process_tool_call({
      toolCallId = "toolu_execute",
      sessionUpdate = "tool_call",
      status = "completed",
      kind = "execute",
      locations = { { path = "/tmp/executed.lua" } },
    })

    return #events
  ]])

  h.eq(0, result)
end

T["ACPHandler"]["collects streamed terminal output across updates"] = function()
  local result = child.lua([[
    local chat = h.setup_chat_buffer({}, {
      name = "test_acp",
      config = {
        name = "test_acp",
        type = "acp",
        handlers = { form_messages = function(a, m) return m end }
      }
    })

    local ACPHandler = require("codecompanion.interactions.chat.acp.handler")
    local handler = ACPHandler.new(chat)
    chat.add_buf_message = function() end

    handler:process_tool_call({
      toolCallId = "exec-1",
      sessionUpdate = "tool_call",
      status = "in_progress",
      kind = "read",
      title = "List files",
    })
    handler:process_tool_call({
      toolCallId = "exec-1",
      sessionUpdate = "tool_call_update",
      _meta = { terminal_output_delta = { data = "first\n", terminal_id = "exec-1" } },
    })
    handler:process_tool_call({
      toolCallId = "exec-1",
      sessionUpdate = "tool_call_update",
      status = "failed",
      rawOutput = { exit_code = 2 },
      _meta = { terminal_output_delta = { data = "second\n", terminal_id = "exec-1" } },
    })

    return handler.tools["exec-1"].streamed_output
  ]])

  h.eq("first\nsecond\n", result)
end

local GUTTER = "  \u{2514} "

T["ACPHandler"]["Tool Output"] = new_set({
  hooks = {
    pre_case = function()
      child.lua([[
        _G.chat = h.setup_chat_buffer({}, {
          name = "test_acp",
          config = {
            name = "test_acp",
            type = "acp",
            handlers = { form_messages = function(a, m) return m end }
          }
        })
        _G.handler = require("codecompanion.interactions.chat.acp.handler").new(_G.chat)

        ---The buffer lines below the line holding the tool label
        _G.lines_below_label = function(label)
          local lines = vim.api.nvim_buf_get_lines(_G.chat.bufnr, 0, -1, false)
          for i, line in ipairs(lines) do
            if line:find(label, 1, true) then
              return vim.list_slice(lines, i + 1)
            end
          end
        end
      ]])
    end,
  },
})

T["ACPHandler"]["Tool Output"]["previews two lines of command output and keeps the rest below them"] = function()
  local below = child.lua([[
    handler:process_tool_call({
      toolCallId = "bash-1",
      sessionUpdate = "tool_call",
      status = "in_progress",
      kind = "execute",
      title = "ls",
    })
    handler:process_tool_call({
      toolCallId = "bash-1",
      sessionUpdate = "tool_call_update",
      status = "completed",
      content = { { type = "content", content = { type = "text", text = "```\none\ntwo\nthree\nfour\n```" } } },
    })
    return vim.list_slice(lines_below_label("ls"), 1, 5)
  ]])

  h.eq({ GUTTER .. "one", "    two", "    three", "    four" }, vim.list_slice(below, 1, 4))
end

T["ACPHandler"]["Tool Output"]["streams command output into the block as it arrives"] = function()
  local result = child.lua([[
    local snapshots = {}
    handler:process_tool_call({
      toolCallId = "exec-1",
      sessionUpdate = "tool_call",
      status = "in_progress",
      kind = "execute",
      title = "make",
    })
    handler:process_tool_call({
      toolCallId = "exec-1",
      sessionUpdate = "tool_call_update",
      _meta = { terminal_output_delta = { data = "a\n", terminal_id = "exec-1" } },
    })
    table.insert(snapshots, vim.list_slice(lines_below_label("make"), 1, 1))
    -- codex-acp sends newline-only chunks that the command never printed
    handler:process_tool_call({
      toolCallId = "exec-1",
      sessionUpdate = "tool_call_update",
      _meta = { terminal_output_delta = { data = "\n\n", terminal_id = "exec-1" } },
    })
    handler:process_tool_call({
      toolCallId = "exec-1",
      sessionUpdate = "tool_call_update",
      _meta = { terminal_output_delta = { data = "b\nc\n", terminal_id = "exec-1" } },
    })
    table.insert(snapshots, vim.list_slice(lines_below_label("make"), 1, 4))
    return snapshots
  ]])

  h.eq({ GUTTER .. "a" }, result[1])
  h.eq({ GUTTER .. "a", "    b", "    c" }, vim.list_slice(result[2], 1, 3))
end

T["ACPHandler"]["Tool Output"]["draws the colors of terminal escape codes instead of the codes"] = function()
  local result = child.lua([[
    handler:process_tool_call({
      toolCallId = "exec-3",
      sessionUpdate = "tool_call",
      status = "in_progress",
      kind = "execute",
      title = "test",
    })
    handler:process_tool_call({
      toolCallId = "exec-3",
      sessionUpdate = "tool_call_update",
      _meta = { terminal_output_delta = { data = "\27[1mTotal:\27[0m 4\n", terminal_id = "exec-3" } },
    })
    local below = lines_below_label("test")
    local ns = vim.api.nvim_get_namespaces()["CodeCompanion-acp_tool_output"]
    local groups = {}
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(chat.bufnr, ns, 0, -1, { details = true })) do
      table.insert(groups, mark[4].hl_group)
    end
    return { line = below[1], groups = groups }
  ]])

  h.eq(GUTTER .. "Total: 4", result.line)
  h.eq(true, vim.tbl_contains(result.groups, "CodeCompanionAnsi___b"))
end

T["ACPHandler"]["Tool Output"]["separates the output from a tool label written BEFORE it arrived"] = function()
  local below = child.lua([[
    for _, id in ipairs({ "exec-4", "exec-5" }) do
      handler:process_tool_call({
        toolCallId = id,
        sessionUpdate = "tool_call",
        status = "in_progress",
        kind = "execute",
        title = id == "exec-4" and "first" or "second",
      })
    end
    for _ = 1, 2 do
      handler:process_tool_call({
        toolCallId = "exec-4",
        sessionUpdate = "tool_call_update",
        _meta = { terminal_output_delta = { data = "one\n", terminal_id = "exec-4" } },
      })
    end
    return lines_below_label("first")
  ]])

  h.eq({ GUTTER .. "one", "    one", "" }, vim.list_slice(below, 1, 3))
  h.eq(true, below[4]:find("second", 1, true) ~= nil)
end

T["ACPHandler"]["Tool Output"]["folds output that arrived while the chat was hidden"] = function()
  local result = child.lua([[
    handler:process_tool_call({
      toolCallId = "exec-6",
      sessionUpdate = "tool_call",
      status = "in_progress",
      kind = "execute",
      title = "hidden",
    })
    chat.ui:hide()
    local hidden = #vim.fn.win_findbuf(chat.bufnr) == 0
    handler:process_tool_call({
      toolCallId = "exec-6",
      sessionUpdate = "tool_call_update",
      _meta = { terminal_output_delta = { data = "a\nb\nc\nd\ne\n", terminal_id = "exec-6" } },
    })
    chat.ui:open()
    local lines = vim.api.nvim_buf_get_lines(chat.bufnr, 0, -1, false)
    local fold_line
    for i, line in ipairs(lines) do
      if line == "    c" then
        fold_line = i
      end
    end
    local closed = vim.api.nvim_win_call(chat.ui.winnr, function()
      return vim.fn.foldclosed(fold_line)
    end)
    return { hidden = hidden, closed = closed == fold_line }
  ]])

  h.eq({ hidden = true, closed = true }, result)
end

T["ACPHandler"]["Tool Output"]["DOES NOT fold a single hidden line"] = function()
  local folded = child.lua([[
    handler:process_tool_call({
      toolCallId = "exec-2",
      sessionUpdate = "tool_call",
      status = "in_progress",
      kind = "execute",
      title = "three",
    })
    handler:process_tool_call({
      toolCallId = "exec-2",
      sessionUpdate = "tool_call_update",
      _meta = { terminal_output_delta = { data = "a\nb\nc\n", terminal_id = "exec-2" } },
    })
    return handler.output_blocks["exec-2"].folded
  ]])

  h.eq(false, folded)
end

T["ACPHandler"]["Tool Output"]["DOES NOT render output for a tool that is NOT a command"] = function()
  local below = child.lua([[
    handler:process_tool_call({
      toolCallId = "read-1",
      sessionUpdate = "tool_call",
      status = "in_progress",
      kind = "read",
      title = "Read notes.md",
    })
    handler:process_tool_call({
      toolCallId = "read-1",
      sessionUpdate = "tool_call_update",
      status = "completed",
      content = { { type = "content", content = { type = "text", text = "file contents" } } },
    })
    return lines_below_label("notes.md")
  ]])

  h.eq(false, vim.tbl_contains(below, GUTTER .. "file contents"))
end

T["ACPHandler"]["Tool Output"]["renders the output of a FAILED tool of any kind"] = function()
  local below = child.lua([[
    handler:process_tool_call({
      toolCallId = "read-2",
      sessionUpdate = "tool_call",
      status = "in_progress",
      kind = "read",
      title = "Read missing.md",
    })
    handler:process_tool_call({
      toolCallId = "read-2",
      sessionUpdate = "tool_call_update",
      status = "failed",
      content = { { type = "content", content = { type = "text", text = "no such file" } } },
    })
    return vim.list_slice(lines_below_label("missing.md"), 1, 1)
  ]])

  h.eq({ GUTTER .. "no such file" }, below)
end

T["ACPHandler"]["Permission Queue"] = new_set()

T["ACPHandler"]["Permission Queue"]["queues concurrent requests and presents one at a time"] = function()
  local result = child.lua([[
    local chat = h.setup_chat_buffer({}, {
      name = "test_acp",
      config = {
        name = "test_acp",
        type = "acp",
        handlers = { form_messages = function(a, m) return m end }
      }
    })

    local ACPHandler = require("codecompanion.interactions.chat.acp.handler")
    local handler = ACPHandler.new(chat)

    -- Track which requests reach the permission UI
    local confirmed = {}
    package.loaded["codecompanion.interactions.chat.acp.request_permission"] = {
      confirm = function(chat_arg, request)
        table.insert(confirmed, request)
      end
    }

    -- Send three permission requests concurrently
    handler:handle_permission_request({
      tool_call = { toolCallId = "tool_1", kind = "edit", title = "Edit file A" },
      options = { { kind = "allow_once", optionId = "allow", name = "Allow" } },
      respond = function() end,
    })
    handler:handle_permission_request({
      tool_call = { toolCallId = "tool_2", kind = "edit", title = "Edit file B" },
      options = { { kind = "allow_once", optionId = "allow", name = "Allow" } },
      respond = function() end,
    })
    handler:handle_permission_request({
      tool_call = { toolCallId = "tool_3", kind = "edit", title = "Edit file C" },
      options = { { kind = "allow_once", optionId = "allow", name = "Allow" } },
      respond = function() end,
    })

    return {
      confirmed_count = #confirmed,
      first_id = confirmed[1] and confirmed[1].tool_call.toolCallId,
      queue_count = handler._permission.queue:count(),
      active = handler._permission.active,
    }
  ]])

  h.eq(1, result.confirmed_count)
  h.eq("tool_1", result.first_id)
  h.eq(2, result.queue_count)
  h.is_true(result.active)
end

T["ACPHandler"]["Permission Queue"]["presents next request after user responds"] = function()
  local result = child.lua([[
    local chat = h.setup_chat_buffer({}, {
      name = "test_acp",
      config = {
        name = "test_acp",
        type = "acp",
        handlers = { form_messages = function(a, m) return m end }
      }
    })

    local ACPHandler = require("codecompanion.interactions.chat.acp.handler")
    local handler = ACPHandler.new(chat)

    local confirmed = {}
    package.loaded["codecompanion.interactions.chat.acp.request_permission"] = {
      confirm = function(chat_arg, request)
        table.insert(confirmed, request)
      end
    }

    local responses = {}
    local make_respond = function(id)
      return function(option_id, canceled)
        table.insert(responses, { id = id, option_id = option_id, canceled = canceled })
      end
    end

    handler:handle_permission_request({
      tool_call = { toolCallId = "tool_1" },
      options = { { kind = "allow_once", optionId = "allow", name = "Allow" } },
      respond = make_respond("tool_1"),
    })
    handler:handle_permission_request({
      tool_call = { toolCallId = "tool_2" },
      options = { { kind = "allow_once", optionId = "allow", name = "Allow" } },
      respond = make_respond("tool_2"),
    })

    -- Simulate user accepting the first request
    confirmed[1].respond("allow", false)

    return {
      confirmed_count = #confirmed,
      second_id = confirmed[2] and confirmed[2].tool_call.toolCallId,
      responses = responses,
      queue_empty = handler._permission.queue:is_empty(),
      active = handler._permission.active,
    }
  ]])

  h.eq(2, result.confirmed_count)
  h.eq("tool_2", result.second_id)
  h.eq("tool_1", result.responses[1].id)
  h.eq("allow", result.responses[1].option_id)
  h.is_true(result.queue_empty)
  h.is_true(result.active)
end

T["ACPHandler"]["Permission Queue"]["clears queue on completion"] = function()
  local result = child.lua([[
    local chat = h.setup_chat_buffer({}, {
      name = "test_acp",
      config = {
        name = "test_acp",
        type = "acp",
        handlers = { form_messages = function(a, m) return m end }
      }
    })

    local ACPHandler = require("codecompanion.interactions.chat.acp.handler")
    local handler = ACPHandler.new(chat)

    local confirmed = {}
    package.loaded["codecompanion.interactions.chat.acp.request_permission"] = {
      confirm = function(chat_arg, request)
        table.insert(confirmed, request)
      end
    }

    local rejected = {}
    local make_respond = function(id)
      return function(option_id, canceled)
        if canceled then
          table.insert(rejected, id)
        end
      end
    end

    -- Queue up three requests
    handler:handle_permission_request({
      tool_call = { toolCallId = "tool_1" },
      options = {},
      respond = make_respond("tool_1"),
    })
    handler:handle_permission_request({
      tool_call = { toolCallId = "tool_2" },
      options = {},
      respond = make_respond("tool_2"),
    })
    handler:handle_permission_request({
      tool_call = { toolCallId = "tool_3" },
      options = {},
      respond = make_respond("tool_3"),
    })

    -- Simulate completion while requests are still queued
    chat.done = function() end
    handler:handle_complete()

    return {
      queue_empty = handler._permission.queue:is_empty(),
      active = handler._permission.active,
      rejected = rejected,
    }
  ]])

  h.is_true(result.queue_empty)
  h.is_false(result.active)
  h.eq({ "tool_1", "tool_2", "tool_3" }, result.rejected)
end

T["ACPHandler"]["Permission Queue"]["clears queue on error"] = function()
  local result = child.lua([[
    local chat = h.setup_chat_buffer({}, {
      name = "test_acp",
      config = {
        name = "test_acp",
        type = "acp",
        handlers = { form_messages = function(a, m) return m end }
      }
    })

    local ACPHandler = require("codecompanion.interactions.chat.acp.handler")
    local handler = ACPHandler.new(chat)

    local confirmed = {}
    package.loaded["codecompanion.interactions.chat.acp.request_permission"] = {
      confirm = function(chat_arg, request)
        table.insert(confirmed, request)
      end
    }

    local rejected = {}
    local make_respond = function(id)
      return function(option_id, canceled)
        if canceled then
          table.insert(rejected, id)
        end
      end
    end

    handler:handle_permission_request({
      tool_call = { toolCallId = "tool_1" },
      options = {},
      respond = make_respond("tool_1"),
    })
    handler:handle_permission_request({
      tool_call = { toolCallId = "tool_2" },
      options = {},
      respond = make_respond("tool_2"),
    })

    -- Stub add_buf_message and done
    chat.add_buf_message = function() end
    chat.done = function() end
    handler:handle_error("Something went wrong")

    return {
      queue_empty = handler._permission.queue:is_empty(),
      active = handler._permission.active,
      rejected = rejected,
    }
  ]])

  h.is_true(result.queue_empty)
  h.is_false(result.active)
  h.eq({ "tool_1", "tool_2" }, result.rejected)
end

T["ACPHandler"]["Config Options"] = new_set()

T["ACPHandler"]["Config Options"]["updates metadata with config options"] = function()
  local result = child.lua([[
    local chat = h.setup_chat_buffer({}, {
      name = "test_acp",
      config = {
        name = "test_acp",
        type = "acp",
        handlers = { form_messages = function(a, m) return m end }
      }
    })

    chat.acp_connection = mocks_acp.new({
      config_options = {
        {
          type = "select",
          id = "mode",
          name = "Mode",
          category = "mode",
          currentValue = "plan",
          options = {
            { value = "default", name = "Always Ask" },
            { value = "plan", name = "Plan Mode" },
          },
        },
      },
    })
    chat:update_metadata()

    local metadata = _G.codecompanion_chat_metadata[chat.bufnr]

    return {
      has_config_options = metadata.config_options ~= nil,
      mode_current = metadata.config_options and metadata.config_options.mode and metadata.config_options.mode.current,
      mode_name = metadata.config_options and metadata.config_options.mode and metadata.config_options.mode.name,
    }
  ]])

  h.is_true(result.has_config_options)
  h.eq("plan", result.mode_current)
  h.eq("Plan Mode", result.mode_name)
end

T["ACPHandler"]["Config Options"]["handles no config options gracefully"] = function()
  local result = child.lua([[
    local chat = h.setup_chat_buffer({}, {
      name = "test_acp",
      config = {
        name = "test_acp",
        type = "acp",
        handlers = { form_messages = function(a, m) return m end }
      }
    })

    chat.acp_connection = mocks_acp.new({ config_options = {} })
    chat:update_metadata()

    local metadata = _G.codecompanion_chat_metadata[chat.bufnr]

    return {
      metadata_exists = metadata ~= nil,
      has_config_options = metadata.config_options ~= nil,
    }
  ]])

  h.is_true(result.metadata_exists)
  h.is_false(result.has_config_options)
end

T["ACPHandler"]["Config Options"]["reflects config option changes in metadata"] = function()
  local result = child.lua([[
    local chat = h.setup_chat_buffer({}, {
      name = "test_acp",
      config = {
        name = "test_acp",
        type = "acp",
        handlers = { form_messages = function(a, m) return m end }
      }
    })

    local config_opts = {
      {
        type = "select",
        id = "mode",
        name = "Mode",
        category = "mode",
        currentValue = "default",
        options = {
          { value = "default", name = "Always Ask" },
          { value = "plan", name = "Plan Mode" },
        },
      },
    }
    chat.acp_connection = mocks_acp.new({ config_options = config_opts })
    chat:update_metadata()

    local metadata_before = vim.deepcopy(_G.codecompanion_chat_metadata[chat.bufnr])

    -- Simulate config option change
    config_opts[1].currentValue = "plan"

    chat:update_metadata()

    local metadata_after = _G.codecompanion_chat_metadata[chat.bufnr]

    return {
      mode_before = metadata_before.config_options and metadata_before.config_options.mode and metadata_before.config_options.mode.current,
      mode_after = metadata_after.config_options and metadata_after.config_options.mode and metadata_after.config_options.mode.current,
      name_after = metadata_after.config_options and metadata_after.config_options.mode and metadata_after.config_options.mode.name,
    }
  ]])

  h.eq("default", result.mode_before)
  h.eq("plan", result.mode_after)
  h.eq("Plan Mode", result.name_after)
end

return T
