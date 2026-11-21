---@class VcJwtDecoderConfig
---@field cmd string[]|nil   Command to run the decoder; nil = auto-detect (vc-jwt-decoder, then uvx)
---@field verify boolean     Verify signatures (resolves did:web / did:key / OIDC keys over the network)
---@field auto_open boolean  Decode automatically when a *.jwt file is opened
---@field split "vertical"|"horizontal"|"tab"

local M = {}

---@type VcJwtDecoderConfig
M.defaults = {
  cmd = nil,
  verify = true,
  auto_open = true,
  split = "vertical",
}

---@type VcJwtDecoderConfig
M.config = vim.deepcopy(M.defaults)

local ns = vim.api.nvim_create_namespace("vc-jwt-decoder")
local result_buf ---@type integer|nil
local last_request ---@type { token: string, opts: table }|nil  for `r` (render again)

--- Resolve the decoder command, preferring an installed CLI over uvx.
---@return string[]|nil cmd, string|nil err
function M.resolve_cmd()
  if M.config.cmd then
    return M.config.cmd
  end
  if vim.fn.executable("vc-jwt-decoder") == 1 then
    return { "vc-jwt-decoder" }
  end
  if vim.fn.executable("uvx") == 1 then
    return { "uvx", "--quiet", "--from", "vc-jwt-decoder[cli]", "vc-jwt-decoder" }
  end
  return nil, "vc-jwt-decoder not found; install it with: uv tool install 'vc-jwt-decoder[cli]'"
end

--- Strip whitespace, quotes and an "Authorization: Bearer" prefix around a token.
---@param s string
---@return string
function M.clean_token(s)
  s = s:gsub("%s+", "")
  s = s:gsub("^[Aa]uthorization:", ""):gsub("^[Bb]earer", "")
  s = s:gsub("^[\"'`(<%[]+", ""):gsub("[\"'`,;)>%]]+$", "")
  return s
end

-- [[ ANSI colors ]]
-- The CLI prints colored panels. They are shown as plain text with highlights (not in a
-- terminal buffer), so resizing the window never re-wraps them. Background colors are
-- dropped, so the colorscheme's background shows through.

local xterm16 = {
  "#000000", "#cd0000", "#00cd00", "#cdcd00", "#0000ee", "#cd00cd", "#00cdcd", "#e5e5e5",
  "#7f7f7f", "#ff0000", "#00ff00", "#ffff00", "#5c5cff", "#ff00ff", "#00ffff", "#ffffff",
}

--- Color of a 256-color palette index; 0-15 follow the colorscheme's terminal colors.
local function palette_color(n)
  if n < 16 then
    return vim.g["terminal_color_" .. n] or xterm16[n + 1]
  elseif n < 232 then
    local function level(v)
      return v == 0 and 0 or 55 + v * 40
    end
    n = n - 16
    return ("#%02x%02x%02x"):format(level(math.floor(n / 36)), level(math.floor(n / 6) % 6), level(n % 6))
  end
  local grey = 8 + (n - 232) * 10
  return ("#%02x%02x%02x"):format(grey, grey, grey)
end

--- Apply one SGR sequence ("1;38;2;r;g;b") to the style state.
local function apply_sgr(params, st)
  local list = params == "" and { "0" } or vim.split(params, ";", { plain = true })
  local i = 1
  while i <= #list do
    local c = tonumber(list[i]) or 0
    if c == 0 then
      st.fg, st.bold, st.dim, st.italic, st.underline = nil, nil, nil, nil, nil
    elseif c == 1 then
      st.bold = true
    elseif c == 2 then
      st.dim = true
    elseif c == 3 then
      st.italic = true
    elseif c == 4 then
      st.underline = true
    elseif c == 22 then
      st.bold, st.dim = nil, nil
    elseif c == 23 then
      st.italic = nil
    elseif c == 24 then
      st.underline = nil
    elseif c == 39 then
      st.fg = nil
    elseif c >= 30 and c <= 37 then
      st.fg = palette_color(c - 30)
    elseif c >= 90 and c <= 97 then
      st.fg = palette_color(c - 90 + 8)
    elseif c == 38 or c == 48 then -- extended color; backgrounds (48) are skipped
      if list[i + 1] == "5" then
        if c == 38 then
          st.fg = palette_color(tonumber(list[i + 2]) or 0)
        end
        i = i + 2
      elseif list[i + 1] == "2" then
        if c == 38 then
          st.fg = ("#%02x%02x%02x"):format(tonumber(list[i + 2]) or 0, tonumber(list[i + 3]) or 0, tonumber(list[i + 4]) or 0)
        end
        i = i + 4
      end
    end
    i = i + 1
  end
end

local groups = {} ---@type table<string, vim.api.keyset.highlight>

--- Highlight group for a style, created on first use.
local function style_group(st)
  if not (st.fg or st.bold or st.dim or st.italic or st.underline) then
    return nil
  end
  local name = ("VcJwtDecoder_%s%s%s%s%s"):format(
    st.fg and st.fg:sub(2) or "",
    st.bold and "b" or "",
    st.dim and "d" or "",
    st.italic and "i" or "",
    st.underline and "u" or ""
  )
  if not groups[name] then
    local spec = { fg = st.fg, bold = st.bold, italic = st.italic, underline = st.underline }
    if st.dim and not st.fg then
      spec.fg = vim.api.nvim_get_hl(0, { name = "Comment", link = false }).fg
    end
    groups[name] = spec
    vim.api.nvim_set_hl(0, name, spec)
  end
  return name
end

-- `:colorscheme` clears all highlight groups; define ours again.
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("vc-jwt-decoder-colors", { clear = true }),
  callback = function()
    for name, spec in pairs(groups) do
      vim.api.nvim_set_hl(0, name, spec)
    end
  end,
})

--- Split ANSI-colored text into plain lines and highlight ranges.
---@param text string
---@return string[] lines
---@return { [1]: integer, [2]: integer, [3]: integer, [4]: string }[] highlights row, start_col, end_col (0-based bytes), group
function M.parse_ansi(text)
  local lines, highlights, st = {}, {}, {}
  text = text:gsub("\r", ""):gsub("\n$", "")
  for row, raw in ipairs(vim.split(text, "\n", { plain = true })) do
    local parts, len, pos = {}, 0, 1
    while true do
      local s, e, params = raw:find("\27%[([%d;]*)m", pos)
      local chunk = raw:sub(pos, (s or 0) - 1)
      if chunk ~= "" then
        local group = style_group(st)
        if group then
          highlights[#highlights + 1] = { row - 1, len, len + #chunk, group }
        end
        parts[#parts + 1] = chunk
        len = len + #chunk
      end
      if not s then
        break
      end
      apply_sgr(params, st)
      pos = e + 1
    end
    lines[row] = table.concat(parts)
  end
  return lines, highlights
end

-- [[ Result window ]]

--- Width the result window has (or will get), so the CLI can fit its panels to it.
local function result_width()
  local win = result_buf and vim.fn.bufwinid(result_buf) or -1
  local width
  if win ~= -1 then
    width = vim.api.nvim_win_get_width(win)
  elseif M.config.split == "tab" then
    width = vim.o.columns
  elseif M.config.split == "horizontal" then
    width = vim.api.nvim_win_get_width(0)
  else
    width = math.floor(vim.api.nvim_win_get_width(0) / 2)
  end
  return math.max(width - 1, 40)
end

--- Focus the result window, opening a split with a new buffer if there is none.
local function open_window()
  local win = result_buf and vim.fn.bufwinid(result_buf) or -1
  if win ~= -1 then
    vim.api.nvim_set_current_win(win)
    return result_buf, win
  end
  local split = M.config.split
  vim.cmd(split == "tab" and "tab split" or split == "horizontal" and "rightbelow split" or "rightbelow vsplit")
  win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_win_set_buf(win, buf)
  pcall(vim.api.nvim_buf_set_name, buf, "jwt://decoded")
  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = buf, desc = "Close JWT view" })
  vim.keymap.set("n", "r", function()
    if last_request then
      M.decode(last_request.token, last_request.opts)
    end
  end, { buffer = buf, desc = "Render JWT view again for the window width" })
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      result_buf = nil
    end,
  })
  result_buf = buf
  local wo = vim.wo[win]
  wo.wrap, wo.list, wo.number, wo.relativenumber, wo.signcolumn, wo.foldcolumn = false, false, false, false, "no", "0"
  return buf, win
end

local function show(stdout, stderr)
  local lines, highlights = M.parse_ansi(stdout)
  if vim.trim(stderr) ~= "" then -- e.g. the steps of a failed signature check
    local extra, extra_hl = M.parse_ansi(stderr)
    local offset = #lines + 1
    lines[#lines + 1] = ""
    vim.list_extend(lines, extra)
    for _, h in ipairs(extra_hl) do
      highlights[#highlights + 1] = { h[1] + offset, h[2], h[3], h[4] }
    end
  end
  local buf, win = open_window()
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, h in ipairs(highlights) do
    vim.api.nvim_buf_set_extmark(buf, ns, h[1], h[2], { end_col = h[3], hl_group = h[4] })
  end
  vim.api.nvim_win_set_cursor(win, { 1, 0 })
end

--- Decode a token and show the result in a split.
---@param token string
---@param opts? { verify?: boolean }
function M.decode(token, opts)
  opts = opts or {}
  token = M.clean_token(token or "")
  if token == "" then
    vim.notify("vc-jwt-decoder: no token found", vim.log.levels.WARN)
    return
  end
  local cmd, err = M.resolve_cmd()
  if not cmd then
    vim.notify(err, vim.log.levels.ERROR)
    return
  end
  last_request = { token = token, opts = opts }
  local args = vim.deepcopy(cmd)
  local verify = opts.verify
  if verify == nil then
    verify = M.config.verify
  end
  if not verify then
    args[#args + 1] = "--no-verify"
  end
  -- Make the CLI (rich) print colors and fit its panels to the result window.
  local env = { FORCE_COLOR = "1", COLORTERM = "truecolor", COLUMNS = tostring(result_width()) }
  local ok, spawn_err = pcall(vim.system, args, { stdin = token, text = true, env = env }, function(r)
    vim.schedule(function()
      local stdout, stderr = r.stdout or "", r.stderr or ""
      if r.code ~= 0 or vim.trim(stdout) == "" then
        local msg = vim.trim(table.concat((M.parse_ansi(stderr ~= "" and stderr or stdout)), " "))
        msg = msg:gsub("^Error decoding JWT: ", "")
        vim.notify("vc-jwt-decoder: " .. (msg ~= "" and msg or "no output"), vim.log.levels.ERROR)
        return
      end
      show(stdout, stderr)
    end)
  end)
  if not ok then
    vim.notify("vc-jwt-decoder: failed to start " .. args[1] .. ": " .. tostring(spawn_err), vim.log.levels.ERROR)
  end
end

--- Decode lines [line1, line2] of the current buffer (1-based, inclusive).
function M.decode_range(line1, line2, opts)
  local lines = vim.api.nvim_buf_get_lines(0, line1 - 1, line2, false)
  M.decode(table.concat(lines, ""), opts)
end

--- Decode the current visual selection (charwise, linewise or blockwise).
function M.decode_selection(opts)
  local lines = vim.fn.getregion(vim.fn.getpos("v"), vim.fn.getpos("."), { type = vim.fn.mode() })
  vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
  M.decode(table.concat(lines, ""), opts)
end

--- Decode the JWT-like string under the cursor.
function M.decode_cursor(opts)
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2] + 1
  -- base64url segments separated by dots (JWT has 3, JWE 5)
  local pattern = "[%w_%-]+%.[%w_%-]+%.[%w_%-]*[%.%w_%-]*"
  local init = 1
  while true do
    local s, e = line:find(pattern, init)
    if not s then
      break
    end
    if col >= s and col <= e then
      return M.decode(line:sub(s, e), opts)
    end
    init = e + 1
  end
  M.decode(vim.fn.expand("<cWORD>"), opts)
end

---@param opts? VcJwtDecoderConfig|table  any subset of the defaults
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
end

return M
