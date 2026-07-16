local helpers = require("codecompanion.adapters.acp.helpers")

---@class CodeCompanion.ACPAdapter.ClaudeCode: CodeCompanion.ACPAdapter
return {
  name = "claude_code",
  formatted_name = "Claude Code",
  type = "acp",
  roles = {
    llm = "assistant",
    user = "user",
  },
  opts = {
    vision = true,
  },
  commands = {
    default = {
      "claude-agent-acp",
    },
    yolo = {
      "claude-agent-acp",
      "--yolo",
    },
  },
  defaults = {
    mcpServers = {},
    timeout = 20000, -- 20 seconds
  },
  env = {
    CLAUDE_CODE_OAUTH_TOKEN = "CLAUDE_CODE_OAUTH_TOKEN",
  },
  parameters = {
    protocolVersion = 1,
    clientCapabilities = {
      fs = { readTextFile = true, writeTextFile = true },
    },
    clientInfo = {
      name = "CodeCompanion.nvim",
      version = "1.0.0",
    },
  },
  handlers = {
    ---@param self CodeCompanion.ACPAdapter
    ---@return boolean
    setup = function(self)
      return true
    end,

    ---Manually handle authentication
    ---@param self CodeCompanion.ACPAdapter
    ---@return boolean
    auth = function(self)
      local token = self.env_replaced.CLAUDE_CODE_OAUTH_TOKEN
      if token and token ~= "" then
        vim.env.CLAUDE_CODE_OAUTH_TOKEN = token
        return true
      end
      return false
    end,

    ---Surface the target host for sandbox network permission requests, whose
    ---bare "SandboxNetworkAccess" title carries no information; every other
    ---tool call falls through to the default prompt
    ---@param self CodeCompanion.ACPAdapter
    ---@param tool_call table
    ---@return string|nil
    format_permission_prompt = function(self, tool_call)
      local raw = tool_call and tool_call.rawInput
      if type(raw) ~= "table" then
        return nil
      end
      -- sandbox network callback: fires mid-command when a sandboxed command
      -- attempts an outbound connection to a host outside the allowlist
      if tool_call.title == "SandboxNetworkAccess" and raw.host then
        return "Network access: " .. raw.host .. (raw.port and (":" .. raw.port) or "")
      end
    end,

    ---@param self CodeCompanion.ACPAdapter
    ---@param messages table
    ---@param capabilities table
    ---@return table
    form_messages = function(self, messages, capabilities)
      return helpers.form_messages(self, messages, capabilities)
    end,

    ---Function to run when the request has completed. Useful to catch errors
    ---@param self CodeCompanion.ACPAdapter
    ---@param code number
    ---@return nil
    on_exit = function(self, code) end,
  },
}
