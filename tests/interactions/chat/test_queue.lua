local h = require("tests.helpers")

local new_set = MiniTest.new_set
local T = new_set()

local child = MiniTest.new_child_neovim()
T = new_set({
  hooks = {
    pre_case = function()
      h.child_start(child)
      child.lua([[
        codecompanion = require("codecompanion")
        h = require('tests.helpers')
        parser = require("codecompanion.interactions.chat.parser")
        _G.chat = h.setup_chat_buffer()

        -- The default test adapter is http, so queue_message takes the
        -- non-queueing fallback. A truthy current_request stands in for a turn
        -- in flight (queue_message no-ops without one).
        _G.chat.current_request = { cancel = function() end }

        -- Mirror what submit() reads to locate the user's message, and report
        -- whether both drafts are recoverable from it.
        function _G.recoverable(chat)
          local row = chat:_user_header_row() or chat.header_line
          local msg = parser.messages(chat, row)
          local text = msg and msg.content or ""
          return {
            drained = chat._queued_drafts == nil,
            has_header = chat:_user_header_row() ~= nil,
            has_first = text:find("first queued", 1, true) ~= nil,
            has_second = text:find("second queued", 1, true) ~= nil,
          }
        end

        function _G.buffer_has(text)
          local lines = table.concat(vim.api.nvim_buf_get_lines(_G.chat.bufnr, 0, -1, false), "\n")
          return lines:find(text, 1, true) ~= nil
        end

        function _G.preview_has(text)
          local ns = vim.api.nvim_get_namespaces()["CodeCompanion-queued_preview"]
          for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(_G.chat.bufnr, ns, 0, -1, { details = true })) do
            for _, virt_line in ipairs(mark[4].virt_lines or {}) do
              local row = table.concat(vim.tbl_map(function(chunk) return chunk[1] end, virt_line))
              if row:find(text, 1, true) then
                return true
              end
            end
          end
          return false
        end
      ]])
    end,
    post_case = function()
      child.lua([[h.teardown_chat_buffer()]])
    end,
    post_once = child.stop,
  },
})

T["queue"] = new_set()

T["queue"]["fallback accumulates in _queued_drafts, not _btw"] = function()
  local out = child.lua([[
    _G.chat:queue_message("first queued")
    _G.chat:queue_message("second queued")
    return { drafts = _G.chat._queued_drafts, btw_nil = _G.chat._btw == nil }
  ]])
  h.eq({ "first queued", "second queued" }, out.drafts)
  h.eq(true, out.btw_nil)
end

T["queue"]["drafts pop into the buffer as a submittable message on normal turn end"] = function()
  local out = child.lua([[
    local chat = _G.chat
    chat:queue_message("first queued")
    chat:queue_message("second queued")
    chat._last_role = "llm"      -- the assistant streamed a reply
    chat.status = "success"
    chat:done({ "an answer" })
    return _G.recoverable(chat)
  ]])
  h.eq(true, out.drained)
  h.eq(true, out.has_header)
  h.eq(true, out.has_first)
  h.eq(true, out.has_second)
end

T["queue"]["drafts pop into the buffer when the turn is cancelled"] = function()
  local out = child.lua([[
    local chat = _G.chat
    chat:queue_message("first queued")
    chat:queue_message("second queued")
    chat._last_role = "llm"
    chat.status = "cancelling"   -- what Chat:stop() sets before done()
    chat:done(nil, nil, nil, nil, { status = "stopped" })
    return _G.recoverable(chat)
  ]])
  h.eq(true, out.drained)
  h.eq(true, out.has_header)
  h.eq(true, out.has_first)
  h.eq(true, out.has_second)
end

T["queue"]["failed mid-stream delivery becomes a turn-end draft, not a stack message"] = function()
  local out = child.lua([[
    local chat = _G.chat
    -- Queueing-capable agent whose process write fails; the metadata stubs
    -- keep update_metadata() happy once done() runs
    chat.adapter.type = "acp"
    chat.acp_connection = {
      supports_prompt_queueing = function() return true end,
      _active_prompt = { queue_prompt = function() return false end },
      get_models = function() return nil end,
      build_name_map = function() return nil end,
      get_config_options = function() return {} end,
    }
    -- the turn streams before the user queues, so the queued render lands in
    -- the assistant section rather than the opening user section
    chat:add_buf_message({ role = "llm", content = "streamed answer" })
    chat:queue_message("dropped message")

    local in_stack = false
    for _, msg in ipairs(chat.messages) do
      if msg.content == "dropped message" then
        in_stack = true
      end
    end

    chat._last_role = "llm"
    chat.status = "success"
    chat:done({ "an answer" })

    local row = chat:_user_header_row() or chat.header_line
    local msg = parser.messages(chat, row)
    return {
      in_stack = in_stack,
      drained = chat._queued_drafts == nil,
      recovered = (msg and msg.content or ""):find("dropped message", 1, true) ~= nil,
    }
  ]])
  h.eq(false, out.in_stack)
  h.eq(true, out.drained)
  h.eq(true, out.recovered)
end

T["queue"]["delivered mid-stream message is marked sent and not restored"] = function()
  local out = child.lua([[
    local chat = _G.chat
    chat.adapter.type = "acp"
    chat.acp_connection = {
      supports_prompt_queueing = function() return true end,
      _active_prompt = { queue_prompt = function() return true end },
      get_models = function() return nil end,
      build_name_map = function() return nil end,
      get_config_options = function() return {} end,
    }
    -- the turn streams before the user queues, so the queued render lands in
    -- the assistant section rather than the opening user section
    chat:add_buf_message({ role = "llm", content = "streamed answer" })
    chat:queue_message("delivered message")
    chat:_queued_turn_started("end_turn")

    local last = chat.messages[#chat.messages]
    chat._last_role = "llm"
    chat.status = "success"
    chat:done({ "an answer" })

    local row = chat:_user_header_row() or chat.header_line
    local msg = parser.messages(chat, row)
    return {
      content = last.content,
      sent = last._meta and last._meta.sent,
      no_drafts = chat._queued_drafts == nil,
      restored = (msg and msg.content or ""):find("delivered message", 1, true) ~= nil,
    }
  ]])
  h.eq("delivered message", out.content)
  h.eq(true, out.sent)
  h.eq(true, out.no_drafts)
  h.eq(false, out.restored)
end

T["queue"]["queued prompt waits in the preview and moves into the chat when its turn starts"] = function()
  local out = child.lua([[
    local chat = _G.chat
    chat.adapter.type = "acp"
    chat.acp_connection = {
      supports_prompt_queueing = function() return true end,
      _active_prompt = { queue_prompt = function() return true end },
    }
    chat:add_buf_message({ role = "llm", content = "streamed answer" })
    chat:queue_message("waiting prompt")
    local waiting = { preview = _G.preview_has("waiting prompt"), buffer = _G.buffer_has("waiting prompt") }

    chat:_queued_turn_started("end_turn")
    return {
      waiting = waiting,
      started = { preview = _G.preview_has("waiting prompt"), buffer = _G.buffer_has("waiting prompt") },
    }
  ]])
  h.eq({ preview = true, buffer = false }, out.waiting)
  h.eq({ preview = false, buffer = true }, out.started)
end

T["queue"]["moves EVERY waiting prompt into the chat when a turn hands over"] = function()
  local out = child.lua([[
    local chat = _G.chat
    chat.adapter.type = "acp"
    chat.acp_connection = {
      supports_prompt_queueing = function() return true end,
      _active_prompt = { queue_prompt = function() return true end },
    }
    chat:add_buf_message({ role = "llm", content = "streamed answer" })
    chat:queue_message("first prompt")
    chat:queue_message("second prompt")

    -- Claude Code takes in everything queued at once, but answers only the turn it handed over from
    chat:_queued_turn_started("end_turn")
    return {
      first = { preview = _G.preview_has("first prompt"), buffer = _G.buffer_has("first prompt") },
      second = { preview = _G.preview_has("second prompt"), buffer = _G.buffer_has("second prompt") },
    }
  ]])
  h.eq({ preview = false, buffer = true }, out.first)
  h.eq({ preview = false, buffer = true }, out.second)
end

T["queue"]["queued message cancelled before its turn is restored as a draft"] = function()
  local out = child.lua([[
    local chat = _G.chat
    chat.adapter.type = "acp"
    chat.acp_connection = {
      supports_prompt_queueing = function() return true end,
      _active_prompt = { queue_prompt = function() return true end },
      get_models = function() return nil end,
      build_name_map = function() return nil end,
      get_config_options = function() return {} end,
    }
    chat:add_buf_message({ role = "llm", content = "streamed answer" })
    chat:queue_message("never ran")

    -- the agent dropped the queued prompt on cancel and answered it first
    chat:_queued_turn_started("cancelled")
    local in_stack = false
    for _, msg in ipairs(chat.messages) do
      if msg.content == "never ran" then
        in_stack = true
      end
    end
    local inline = table.concat(vim.api.nvim_buf_get_lines(chat.bufnr, 0, -1, false), "\n")

    chat._last_role = "llm"
    chat.status = "success"
    chat:done(nil, nil, nil, nil, { status = "stopped" })

    local row = chat:_user_header_row() or chat.header_line
    local msg = parser.messages(chat, row)
    return {
      in_stack = in_stack,
      inline_removed = inline:find("never ran", 1, true) == nil,
      drained = chat._queued_drafts == nil,
      recovered = (msg and msg.content or ""):find("never ran", 1, true) ~= nil,
    }
  ]])
  h.eq(false, out.in_stack)
  h.eq(true, out.inline_removed)
  h.eq(true, out.drained)
  h.eq(true, out.recovered)
end

T["queue"]["queued prompt still waiting when the user stops the turn is restored as a draft"] = function()
  local out = child.lua([[
    local chat = _G.chat
    chat.adapter.type = "acp"
    chat.acp_connection = {
      supports_prompt_queueing = function() return true end,
      _active_prompt = { queue_prompt = function() return true end },
      get_models = function() return nil end,
      build_name_map = function() return nil end,
      get_config_options = function() return {} end,
    }
    chat:add_buf_message({ role = "llm", content = "streamed answer" })
    chat:queue_message("stopped early")

    -- Chat:stop() finishes the chat before the agent reports the queued prompt as cancelled
    chat._last_role = "llm"
    chat.status = "cancelling"
    chat:done(nil, nil, nil, nil, { status = "stopped" })

    local in_stack = false
    for _, msg in ipairs(chat.messages) do
      if msg.content == "stopped early" then
        in_stack = true
      end
    end
    local row = chat:_user_header_row() or chat.header_line
    local msg = parser.messages(chat, row)
    return {
      in_stack = in_stack,
      preview = _G.preview_has("stopped early"),
      recovered = (msg and msg.content or ""):find("stopped early", 1, true) ~= nil,
    }
  ]])
  h.eq(false, out.in_stack)
  h.eq(false, out.preview)
  h.eq(true, out.recovered)
end

T["queue"]["no queued drafts leaves turn end unchanged"] = function()
  local out = child.lua([[
    local chat = _G.chat
    chat._last_role = "llm"
    chat.status = "success"
    chat:done({ "an answer" })
    return { drained = chat._queued_drafts == nil }
  ]])
  h.eq(true, out.drained)
end

T["steering"] = new_set({
  hooks = {
    pre_case = function()
      -- Steering-capable agent; the captured callback stands in for the async
      -- _session/steering response. The metadata stubs keep update_metadata()
      -- happy once done() runs
      child.lua([[
        _G.chat.adapter.type = "acp"
        _G.chat.acp_connection = {
          supports_steering = function() return true end,
          steer = function(_, messages, cb)
            _G.steer_cb = cb
            return true
          end,
          get_models = function() return nil end,
          build_name_map = function() return nil end,
          get_config_options = function() return {} end,
        }
      ]])
    end,
  },
})

T["steering"]["waits in the preview; injection moves it into the chat and marks it sent"] = function()
  local out = child.lua([[
    local chat = _G.chat
    -- the turn streams before the user queues, so the queued render lands in
    -- the assistant section rather than the opening user section
    chat:add_buf_message({ role = "llm", content = "streamed answer" })
    chat:queue_message("steered message")

    local waiting = { preview = _G.preview_has("steered message"), buffer = _G.buffer_has("steered message") }

    _G.steer_cb("injected")

    local last = chat.messages[#chat.messages]
    local injected = { preview = _G.preview_has("steered message"), buffer = _G.buffer_has("steered message") }

    chat._last_role = "llm"
    chat.status = "success"
    chat:done({ "an answer" })

    local row = chat:_user_header_row() or chat.header_line
    local msg = parser.messages(chat, row)
    return {
      waiting = waiting,
      injected = injected,
      content = last.content,
      sent = last._meta and last._meta.sent,
      no_drafts = chat._queued_drafts == nil,
      restored = (msg and msg.content or ""):find("steered message", 1, true) ~= nil,
    }
  ]])
  h.eq({ preview = true, buffer = false }, out.waiting)
  h.eq({ preview = false, buffer = true }, out.injected)
  h.eq("steered message", out.content)
  h.eq(true, out.sent)
  h.eq(true, out.no_drafts)
  h.eq(false, out.restored)
end

T["steering"]["failed outcome clears the preview and recovers via drafts"] = function()
  local out = child.lua([[
    local chat = _G.chat
    chat:add_buf_message({ role = "llm", content = "streamed answer" })
    chat:queue_message("failed steer")

    local previewed = _G.preview_has("failed steer")
    _G.steer_cb("failed")
    local cleared = not _G.preview_has("failed steer") and not _G.buffer_has("failed steer")
    local drafts = vim.deepcopy(chat._queued_drafts)

    local in_stack = false
    for _, msg in ipairs(chat.messages) do
      if msg.content == "failed steer" then
        in_stack = true
      end
    end

    chat._last_role = "llm"
    chat.status = "success"
    chat:done({ "an answer" })

    local row = chat:_user_header_row() or chat.header_line
    local msg = parser.messages(chat, row)
    return {
      previewed = previewed,
      cleared = cleared,
      drafts = drafts,
      in_stack = in_stack,
      drained = chat._queued_drafts == nil,
      recovered = (msg and msg.content or ""):find("failed steer", 1, true) ~= nil,
    }
  ]])
  h.eq(true, out.previewed)
  h.eq(true, out.cleared)
  h.eq({ "failed steer" }, out.drafts)
  h.eq(false, out.in_stack)
  h.eq(true, out.drained)
  h.eq(true, out.recovered)
end

T["steering"]["outcome arriving after turn end flushes into the input area immediately"] = function()
  local out = child.lua([[
    local chat = _G.chat
    chat:add_buf_message({ role = "llm", content = "streamed answer" })
    chat:queue_message("late steer")

    -- turn ends (clearing current_request) before the steering response lands
    chat._last_role = "llm"
    chat.status = "success"
    chat:done({ "an answer" })
    _G.steer_cb("startedNewTurn")

    local row = chat:_user_header_row() or chat.header_line
    local msg = parser.messages(chat, row)
    return {
      drained = chat._queued_drafts == nil,
      recovered = (msg and msg.content or ""):find("late steer", 1, true) ~= nil,
    }
  ]])
  h.eq(true, out.drained)
  h.eq(true, out.recovered)
end

T["steering"]["a steer that never reaches the process becomes a turn-end draft"] = function()
  local out = child.lua([[
    local chat = _G.chat
    chat.acp_connection.steer = function() return false end
    chat:add_buf_message({ role = "llm", content = "streamed answer" })
    chat:queue_message("undelivered steer")
    return {
      drafts = vim.deepcopy(chat._queued_drafts),
      rendered = _G.buffer_has("undelivered steer"),
    }
  ]])
  h.eq({ "undelivered steer" }, out.drafts)
  h.eq(false, out.rendered)
end

return T
