local h = require("tests.helpers")
local adapter

local new_set = MiniTest.new_set
local T = new_set()

T["Claude Code adapter"] = new_set({
  hooks = {
    pre_case = function()
      adapter = require("codecompanion.adapters").resolve("claude_code")
    end,
  },
})

T["Claude Code adapter"]["warns about a command that runs OUTSIDE the sandbox"] = function()
  local notice = adapter.handlers.sandbox_notice(adapter, {
    kind = "execute",
    rawInput = { command = "make test", dangerouslyDisableSandbox = true },
  })

  h.eq("warning", notice.level)
end

T["Claude Code adapter"]["DOES NOT mark a command that runs INSIDE the sandbox"] = function()
  local notice = adapter.handlers.sandbox_notice(adapter, {
    kind = "execute",
    rawInput = { command = "make test" },
  })

  h.eq(nil, notice)
end

return T
