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

return T
