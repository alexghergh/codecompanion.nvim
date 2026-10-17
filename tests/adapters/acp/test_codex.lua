local h = require("tests.helpers")
local adapter

local new_set = MiniTest.new_set
local T = new_set()

T["Codex adapter"] = new_set({
  hooks = {
    pre_case = function()
      adapter = require("codecompanion.adapters").resolve("codex")
    end,
  },
})

T["Codex adapter"]["warns that a plain command may run outside the sandbox"] = function()
  local notice = adapter.handlers.sandbox_notice(adapter, {
    kind = "execute",
    rawInput = { command = "make test", cwd = "/repo" },
  })

  h.eq("warning", notice.level)
end

T["Codex adapter"]["notes network access for a command that stays sandboxed"] = function()
  local notice = adapter.handlers.sandbox_notice(adapter, {
    kind = "execute",
    rawInput = { command = "curl example.com", url = "https://example.com" },
  })

  h.eq({ text = "Sandboxed, with network access to https://example.com", level = "info" }, notice)
end

T["Codex adapter"]["notes extra permissions for a command that stays sandboxed"] = function()
  local notice = adapter.handlers.sandbox_notice(adapter, {
    kind = "execute",
    rawInput = { command = "make install", additionalPermissions = { fileSystem = { write = { "/opt" } } } },
  })

  h.eq("info", notice.level)
end

T["Codex adapter"]["DOES NOT mark a request that is NOT a command"] = function()
  local notice = adapter.handlers.sandbox_notice(adapter, { kind = "edit", rawInput = {} })

  h.eq(nil, notice)
end

return T
