---@class VcJwtDecoderConfig
---@field cmd string[]|nil   Command to run the decoder; nil = auto-detect (vc-jwt-decoder, then uvx)
---@field verify boolean     Verify signatures (resolves did:web / did:key / OIDC keys over the network)
---@field auto_open boolean  Decode automatically when a *.jwt file is opened
---@field split "vertical"|"horizontal"|"tab"
---@field timestamps boolean Show iat/nbf/exp as human-readable dates next to the claims

local M = {}

---@type VcJwtDecoderConfig
M.defaults = {
  cmd = nil,
  verify = true,
  auto_open = true,
  split = "vertical",
  timestamps = true,
}

---@type VcJwtDecoderConfig
M.config = vim.deepcopy(M.defaults)

local ns = vim.api.nvim_create_namespace("vc-jwt-decoder")
local result_buf ---@type integer|nil

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

local function sig_status(sig, verified_requested)
  if not verified_requested or type(sig) ~= "table" then
    return "signature: not checked", "Comment"
  elseif sig.verified == true then
    return "✓ signature verified", "DiagnosticOk"
  elseif sig.verified == false then
    return "✗ signature INVALID", "DiagnosticError"
  end
  return "? signature not verified (no key found)", "DiagnosticWarn"
end

local function winbar_text(result, verify)
  if result.error then
    return "%#DiagnosticError# JWT: " .. result.error:gsub("%%", "%%%%")
  end
  local text, hl = sig_status(result.signature, verify)
  local parts = { ("%%#%s# %s"):format(hl, text) }
  for i, vc in ipairs(result.enveloped_vcs or {}) do
    local t, h = sig_status(vc.signature, verify)
    parts[#parts + 1] = ("%%#%s#VC[%d]: %s"):format(h, i - 1, t)
  end
  if result.is_vp then
    parts[#parts + 1] = "%#Title#VP"
  end
  return table.concat(parts, "%#Normal#  │  ")
end

local function annotate_timestamps(buf, lines)
  for i, line in ipairs(lines) do
    local key, num = line:match('^%s*"(%a+)":%s*(%d+),?$')
    if num and (key == "iat" or key == "nbf" or key == "exp" or key == "auth_time") then
      local ts = tonumber(num)
      local label = os.date("!%Y-%m-%d %H:%M:%S UTC", ts)
      local hl = "Comment"
      if key == "exp" and ts < os.time() then
        label, hl = label .. " (expired)", "DiagnosticError"
      elseif key == "nbf" and ts > os.time() then
        label, hl = label .. " (not yet valid)", "DiagnosticWarn"
      end
      vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, { virt_text = { { "  " .. label, hl } } })
    end
  end
end

local function open_window(title)
  local win = result_buf and vim.fn.bufwinid(result_buf) or -1
  if win ~= -1 then
    vim.api.nvim_set_current_win(win)
    return result_buf, win
  end
  local split = M.config.split
  vim.cmd(split == "tab" and "tabnew" or split == "horizontal" and "rightbelow new" or "rightbelow vnew")
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "json"
  pcall(vim.api.nvim_buf_set_name, buf, title)
  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = buf, desc = "Close JWT view" })
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      result_buf = nil
    end,
  })
  result_buf = buf
  return buf, vim.api.nvim_get_current_win()
end

local function render(stdout, stderr, verify)
  local ok, result = pcall(vim.json.decode, stdout, { luanil = { object = true, array = true } })
  if not ok or type(result) ~= "table" then
    local msg = vim.trim(stderr ~= "" and stderr or stdout)
    vim.notify("vc-jwt-decoder: " .. (msg ~= "" and msg or "no output"), vim.log.levels.ERROR)
    return
  end
  if result.error then
    vim.notify("vc-jwt-decoder: " .. result.error, vim.log.levels.ERROR)
    return
  end
  local buf, win = open_window("jwt://decoded")
  local lines = vim.split(vim.trim(stdout), "\n")
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  if M.config.timestamps then
    annotate_timestamps(buf, lines)
  end
  vim.wo[win].winbar = winbar_text(result, verify)
  vim.wo[win].foldmethod = "indent"
  vim.wo[win].foldlevel = 3
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
  local args = vim.list_extend(vim.deepcopy(cmd), { "--json" })
  local verify = opts.verify
  if verify == nil then
    verify = M.config.verify
  end
  if not verify then
    args[#args + 1] = "--no-verify"
  end
  local ok, spawn_err = pcall(vim.system, args, { stdin = token, text = true }, function(r)
    vim.schedule(function()
      render(r.stdout or "", r.stderr or "", verify)
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

---@param opts? VcJwtDecoderConfig
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
end

return M
