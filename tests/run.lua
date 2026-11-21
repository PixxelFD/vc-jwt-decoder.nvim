-- Headless smoke tests: nvim --headless -u NONE -l tests/run.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
vim.cmd("filetype on")
vim.cmd("runtime plugin/vc-jwt-decoder.lua")
local jwt = require("vc-jwt-decoder")
local failures = 0
local function check(name, cond, detail)
  if cond then print("ok   " .. name) else failures = failures + 1; print("FAIL " .. name .. " " .. vim.inspect(detail)) end
end

local function b64(t) return (vim.base64.encode(vim.json.encode(t)):gsub("=+$", ""):gsub("+", "-"):gsub("/", "_")) end
local token = b64({ alg = "HS256", typ = "JWT" }) .. "." .. b64({ sub = "alice", iat = 1700000000, exp = 1700003600 }) .. ".c2ln"

check("clean bearer", jwt.clean_token("Authorization: Bearer " .. token) == token)
check("clean quotes", jwt.clean_token('"' .. token .. '",') == token)
check("cmd resolves", jwt.resolve_cmd() ~= nil, jwt.resolve_cmd())

local function result_lines()
  local ok = vim.wait(120000, function()
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_name(b):match("jwt://decoded$") and vim.api.nvim_buf_get_lines(b, 0, 1, false)[1] == "{" then return true end
    end
  end, 100)
  if not ok then return nil end
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b):match("jwt://decoded$") then return b, vim.api.nvim_buf_get_lines(b, 0, -1, false) end
  end
end

-- token under cursor, embedded in a log line
vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'GET /api Authorization: "Bearer ' .. token .. '" 200' })
vim.api.nvim_win_set_cursor(0, { 1, 40 })
jwt.decode_cursor({ verify = false })
local buf, lines = result_lines()
check("decoded buffer", buf ~= nil)
local decoded = buf and vim.json.decode(table.concat(lines, "\n"))
check("payload sub", decoded and decoded.payload.sub == "alice", decoded)
check("filetype json", buf and vim.bo[buf].filetype == "json")
local win = buf and vim.fn.bufwinid(buf)
check("winbar status", win and vim.wo[win].winbar:find("not checked", 1, true), win and vim.wo[win].winbar)
local marks = buf and vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true }) or {}
local texts = vim.tbl_map(function(m) return m[4].virt_text[1][1] end, marks)
check("timestamp marks", #marks == 2 and table.concat(texts):find("expired", 1, true), texts)

-- error path: invalid token notifies instead of opening a buffer
vim.cmd("bwipeout! " .. buf)
local notified
vim.notify = function(msg) notified = msg end
jwt.decode("garbage")
vim.wait(120000, function() return notified ~= nil end, 100)
check("error notified", notified and notified:find("unrecognized token", 1, true), notified)

-- auto-open for *.jwt files
local path = vim.fn.tempname() .. ".jwt"
vim.fn.writefile({ token }, path)
jwt.setup({ verify = false })
vim.notify = print
vim.cmd("edit " .. path)
check("auto-open .jwt", result_lines() ~= nil)
check("filetype jwt", vim.bo[vim.fn.bufnr(path)].filetype == "jwt")

-- signature verification (did:key Ed25519, resolved offline) and tampering
local signed = "eyJhbGciOiAiRWREU0EiLCAidHlwIjogIkpXVCIsICJraWQiOiAiZGlkOmtleTp6Nk1rbVIyNjRBdGo1d3FOTnZDVzc5QlFYYko4NXpvbUNNdEF2OHBEbm0yTXFHR1IifQ"
  .. ".eyJqdGkiOiAiMDAwMDAwMDAtMDAwMC00MDAwLTgwMDAtMDAwMDAwMDAwMDAwIn0"
  .. ".3Jb9SQsZHcYH2Kdb7eOTwnhgryVqYlfKUWN3r3WqxElOc4mNG7zgIXjldfCU_nw6dEd5dZf9t71RqrzO0Ol9Dw"
local function winbar_for(tok)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b):match("jwt://decoded$") then vim.cmd("bwipeout! " .. b) end
  end
  jwt.decode(tok, { verify = true })
  local b = result_lines()
  return b and vim.wo[vim.fn.bufwinid(b)].winbar or ""
end
local wb = winbar_for(signed)
check("verified winbar", wb:find("verified", 1, true) and wb:find("DiagnosticOk", 1, true), wb)
wb = winbar_for(signed:gsub("3Jb9", "4Jb9"))
check("tampered winbar", wb:find("INVALID", 1, true), wb)

print(failures == 0 and "ALL PASSED" or (failures .. " FAILED"))
os.exit(failures == 0 and 0 or 1)
