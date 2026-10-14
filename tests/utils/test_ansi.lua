local ansi = require("codecompanion.utils.ansi")
local h = require("tests.helpers")
local new_set = MiniTest.new_set

local T = new_set()

---The foreground color of a highlight group, as a hex string
---@param name string
---@return string|nil
local function fg_of(name)
  local fg = vim.api.nvim_get_hl(0, { name = name }).fg
  return fg and ("#%06x"):format(fg)
end

T["ANSI utils"] = new_set()

T["ANSI utils"]["colors the text a color code covers and strips the codes"] = function()
  vim.g.terminal_color_1 = "#aa0000"
  local text, spans = ansi.parse("\27[31mred\27[0m plain")

  h.eq("red plain", text)
  h.eq(1, #spans)
  h.eq({ 0, 3 }, { spans[1].col, spans[1].end_col })
  h.eq("#aa0000", fg_of(spans[1].hl_group))
end

T["ANSI utils"]["maps 256-color and truecolor codes to their exact colors"] = function()
  local _, palette = ansi.parse("\27[38;5;196mx")
  local _, truecolor = ansi.parse("\27[38;2;1;2;3mx")

  h.eq("#ff0000", fg_of(palette[1].hl_group))
  h.eq("#010203", fg_of(truecolor[1].hl_group))
end

T["ANSI utils"]["strips escape codes that are NOT colors"] = function()
  local text, spans = ansi.parse("\27]0;window title\7\27[2Kdone\27[1A")

  h.eq("done", text)
  h.eq({}, spans)
end

T["ANSI utils"]["keeps only the last state of a line redrawn with carriage returns"] = function()
  h.eq("100%", (ansi.parse("10%\r50%\r100%")))
  h.eq("done", (ansi.parse("done\r")))
end

return T
