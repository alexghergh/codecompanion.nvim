local api = vim.api

local M = {}

-- xterm's colors for the 16 base indexes, for a colorscheme that sets no `g:terminal_color_N`
local BASE_COLORS = {
  "#000000",
  "#cd0000",
  "#00cd00",
  "#cdcd00",
  "#0000ee",
  "#cd00cd",
  "#00cdcd",
  "#e5e5e5",
  "#7f7f7f",
  "#ff0000",
  "#00ff00",
  "#ffff00",
  "#5c5cff",
  "#ff00ff",
  "#00ffff",
  "#ffffff",
}

local CUBE_LEVELS = { 0, 95, 135, 175, 215, 255 }

---The hex color of an xterm 256-color index; the 16 base colors follow the colorscheme's terminal colors
---@param index number
---@return string
local function color_256(index)
  index = math.max(0, math.min(255, index))
  if index < 16 then
    return vim.g["terminal_color_" .. index] or BASE_COLORS[index + 1]
  end
  if index < 232 then
    local n = index - 16
    return ("#%02x%02x%02x"):format(
      CUBE_LEVELS[math.floor(n / 36) + 1],
      CUBE_LEVELS[math.floor(n / 6) % 6 + 1],
      CUBE_LEVELS[n % 6 + 1]
    )
  end
  local grey = 8 + (index - 232) * 10
  return ("#%02x%02x%02x"):format(grey, grey, grey)
end

---Read an extended color ("5;n" or "2;r;g;b") from the codes after a 38 or 48
---@param codes number[]
---@param i number Index of the 38 or 48
---@return string|nil color
---@return number next_i
local function extended_color(codes, i)
  if codes[i + 1] == 5 and codes[i + 2] then
    return color_256(codes[i + 2]), i + 2
  end
  if codes[i + 1] == 2 and codes[i + 4] then
    local function channel(n)
      return math.max(0, math.min(255, n))
    end
    return ("#%02x%02x%02x"):format(channel(codes[i + 2]), channel(codes[i + 3]), channel(codes[i + 4])), i + 4
  end
  return nil, i
end

---Update a style with the parameters of one color (SGR) code
---@param style { fg?: string, bg?: string, bold?: boolean, italic?: boolean, underline?: boolean }
---@param params string
local function apply_sgr(style, params)
  local codes = vim.tbl_map(function(code)
    return tonumber(code) or 0
  end, vim.split((params:gsub(":", ";")), ";", { plain = true }))

  local i = 1
  while i <= #codes do
    local code = codes[i]
    if code == 0 then
      style.fg, style.bg, style.bold, style.italic, style.underline = nil, nil, nil, nil, nil
    elseif code == 1 or code == 22 then
      style.bold = code == 1 or nil
    elseif code == 3 or code == 23 then
      style.italic = code == 3 or nil
    elseif code == 4 or code == 24 then
      style.underline = code == 4 or nil
    elseif code >= 30 and code <= 37 or code >= 90 and code <= 97 then
      style.fg = color_256(code >= 90 and code - 82 or code - 30)
    elseif code >= 40 and code <= 47 or code >= 100 and code <= 107 then
      style.bg = color_256(code >= 100 and code - 92 or code - 40)
    elseif code == 39 or code == 49 then
      style[code == 39 and "fg" or "bg"] = nil
    elseif code == 38 or code == 48 then
      style[code == 38 and "fg" or "bg"], i = extended_color(codes, i)
    end
    i = i + 1
  end
end

---The highlight group drawing a style, defined the first time it's needed
---@param style { fg?: string, bg?: string, bold?: boolean, italic?: boolean, underline?: boolean }
---@return string|nil
local function style_group(style)
  if not (style.fg or style.bg or style.bold or style.italic or style.underline) then
    return nil
  end

  local name = ("CodeCompanionAnsi_%s_%s_%s%s%s"):format(
    style.fg and style.fg:sub(2) or "",
    style.bg and style.bg:sub(2) or "",
    style.bold and "b" or "",
    style.italic and "i" or "",
    style.underline and "u" or ""
  )
  -- A colorscheme change clears every group, so check the definition rather than remembering it
  if vim.tbl_isempty(api.nvim_get_hl(0, { name = name })) then
    api.nvim_set_hl(0, name, {
      fg = style.fg,
      bg = style.bg,
      bold = style.bold,
      italic = style.italic,
      underline = style.underline,
    })
  end
  return name
end

---The position after an escape sequence starting at `pos`, and its parameters if it sets colors
---@param line string
---@param pos number
---@return number next_pos
---@return string|nil sgr_params
local function read_escape(line, pos)
  local params, final = line:match("^\27%[([0-?]*)[ -/]*([@-~])", pos)
  if final then
    local length = #line:match("^\27%[[0-?]*[ -/]*[@-~]", pos)
    return pos + length, final == "m" and params or nil
  end

  -- OSC (e.g. a window title) runs up to a BEL or an ESC \
  if line:sub(pos + 1, pos + 1) == "]" then
    local _, stop = line:find("\7", pos + 2, true)
    local _, esc_stop = line:find("\27\\", pos + 2, true)
    stop = math.min(stop or math.huge, esc_stop or math.huge)
    return stop == math.huge and #line + 1 or stop + 1, nil
  end

  return pos + 2, nil
end

---Split a line of terminal output into plain text and the highlighted spans its color codes describe;
---codes that move the cursor or set titles are dropped, and a line redrawn with carriage returns keeps
---only its last state
---@param line string
---@return string text
---@return { col: number, end_col: number, hl_group: string }[] spans 0-based byte columns
function M.parse(line)
  local style = {}
  local text, spans = "", {}
  local previous_text, previous_spans = "", {}

  local pos = 1
  while pos <= #line do
    local stop = line:find("[\27\r]", pos) or #line + 1
    -- Other control characters (BEL, backspace) have no display form in a buffer
    local chunk = line:sub(pos, stop - 1):gsub("[\1-\8\11\12\14-\31]", "")
    if chunk ~= "" then
      local hl_group = style_group(style)
      if hl_group then
        table.insert(spans, { col = #text, end_col = #text + #chunk, hl_group = hl_group })
      end
      text = text .. chunk
    end

    if stop > #line then
      break
    elseif line:sub(stop, stop) == "\r" then
      previous_text, previous_spans = text, spans
      text, spans = "", {}
      pos = stop + 1
    else
      local sgr_params
      pos, sgr_params = read_escape(line, stop)
      if sgr_params then
        apply_sgr(style, sgr_params)
      end
    end
  end

  if text == "" then
    return previous_text, previous_spans
  end
  return text, spans
end

---Remove every escape code from a line of terminal output
---@param line string
---@return string
function M.strip(line)
  return (M.parse(line))
end

return M
