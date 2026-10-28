local helpers = require("codecompanion.adapters.acp.helpers")

---@class CodeCompanion.ACPAdapter.Codex: CodeCompanion.ACPAdapter
return {
  name = "codex",
  formatted_name = "Codex",
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
      "codex-acp",
    },
  },
  defaults = {
    auth_method = "api-key", -- "api-key"|"chat-gpt"
    mcpServers = {},
    timeout = 20000, -- 20 seconds
  },
  env = {
    OPENAI_API_KEY = "OPENAI_API_KEY",
  },
  parameters = {
    protocolVersion = 1,
    clientCapabilities = {
      fs = { readTextFile = true, writeTextFile = true },
      -- the agent checks for a JSON object; `{}` would be sent as an array
      subagents = vim.empty_dict(),
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

    ---@param self CodeCompanion.ACPAdapter
    ---@param messages table
    ---@param capabilities table
    ---@return table
    form_messages = function(self, messages, capabilities)
      return helpers.form_messages(self, messages, capabilities)
    end,

    ---Codex (0.160.1) asks for a command it would sandbox only when the model asks to leave the sandbox, or
    ---when the command is on its dangerous list and still runs sandboxed (`exec_policy.rs`); the request
    ---carries neither fact, so a plain command can only be marked as possibly unsandboxed
    ---@param self CodeCompanion.ACPAdapter
    ---@param tool_call table
    ---@return CodeCompanion.ACPAdapter.SandboxNotice|nil
    sandbox_notice = function(self, tool_call)
      local raw = tool_call and type(tool_call.rawInput) == "table" and tool_call.rawInput or {}
      if raw.url then
        return { text = "Sandboxed, with network access to " .. raw.url, level = "info" }
      end
      if raw.additionalPermissions then
        return { text = "Sandboxed, with extra permissions", level = "info" }
      end
      if raw.command or (tool_call and tool_call.kind == "execute") then
        return { text = "May run outside the sandbox", level = "warning" }
      end
    end,

    ---Function to run when the request has completed. Useful to catch errors
    ---@param self CodeCompanion.ACPAdapter
    ---@param code number
    ---@return nil
    on_exit = function(self, code) end,
  },
}
