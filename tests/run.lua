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

-- ANSI parsing: text without escapes, byte columns, backgrounds dropped, styles reset
local lines, hls = jwt.parse_ansi("\27[94m╭─\27[0m x\r\n\27[1;38;2;1;2;3;48;2;4;5;6mab\27[0m\27[48;5;9mc\27[0m\n")
check("ansi lines", #lines == 2 and lines[1] == "╭─ x" and lines[2] == "abc", lines)
check("ansi ranges", #hls == 2 and hls[1][1] == 0 and hls[1][2] == 0 and hls[1][3] == 6 and hls[2][1] == 1 and hls[2][3] == 2, hls)
local hl = hls[2] and vim.api.nvim_get_hl(0, { name = hls[2][4] }) or {}
check("ansi style", hl.fg == 0x010203 and hl.bold and hl.bg == nil, hl)

-- Wait until the result buffer contains `pattern`; returns its buffer and text.
local function result(pattern)
  local buf, text
  vim.wait(120000, function()
    buf = vim.fn.bufnr("jwt://decoded")
    if buf == -1 then return false end
    text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    return text:find(pattern, 1, true) ~= nil
  end, 100)
  return buf, text
end
local function close_result()
  local buf = vim.fn.bufnr("jwt://decoded")
  if buf ~= -1 then vim.cmd("bwipeout! " .. buf) end
end

-- token under cursor, embedded in a log line
vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'GET /api Authorization: "Bearer ' .. token .. '" 200' })
vim.api.nvim_win_set_cursor(0, { 1, 40 })
jwt.decode_cursor({ verify = false })
local buf, text = result('"alice"')
check("panels", text and text:find("Header", 1, true) and text:find("Payload", 1, true), text)
check("no escapes", text and not text:find("\27", 1, true))
local marks = buf ~= -1 and vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, {}) or {}
check("highlighted", #marks > 0)
check("read-only", buf ~= -1 and not vim.bo[buf].modifiable)

-- resizing keeps the text; `r` lays the panels out again for the current width
local win = vim.fn.bufwinid(buf)
local function panel_width() return vim.fn.strdisplaywidth(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or "") end
local before = panel_width()
vim.api.nvim_win_set_width(win, 50)
check("resize keeps text", panel_width() == before)
vim.api.nvim_set_current_win(win)
vim.api.nvim_feedkeys("r", "x", false)
vim.wait(120000, function() return panel_width() == 49 end, 100)
check("r renders for width", panel_width() == 49, { before, panel_width() })

-- error path: invalid token notifies instead of opening a buffer
close_result()
local notified
vim.notify = function(msg) notified = msg end
jwt.decode("garbage")
vim.wait(120000, function() return notified ~= nil end, 100)
check("error notified", notified and notified:find("unrecognized token", 1, true), notified)
check("no view on error", vim.fn.bufnr("jwt://decoded") == -1)

-- auto-open for *.jwt files
local path = vim.fn.tempname() .. ".jwt"
vim.fn.writefile({ token }, path)
jwt.setup({ verify = false })
vim.notify = print
vim.cmd("edit " .. path)
check("auto-open .jwt", select(2, result('"alice"')) ~= nil)
check("filetype jwt", vim.bo[vim.fn.bufnr(path)].filetype == "jwt")

-- signature verification (did:key Ed25519, resolved offline) and tampering
local signed = "eyJhbGciOiAiRWREU0EiLCAidHlwIjogIkpXVCIsICJraWQiOiAiZGlkOmtleTp6Nk1rbVIyNjRBdGo1d3FOTnZDVzc5QlFYYko4NXpvbUNNdEF2OHBEbm0yTXFHR1IifQ"
  .. ".eyJqdGkiOiAiMDAwMDAwMDAtMDAwMC00MDAwLTgwMDAtMDAwMDAwMDAwMDAwIn0"
  .. ".3Jb9SQsZHcYH2Kdb7eOTwnhgryVqYlfKUWN3r3WqxElOc4mNG7zgIXjldfCU_nw6dEd5dZf9t71RqrzO0Ol9Dw"
close_result()
jwt.decode(signed, { verify = true })
check("verified", select(2, result("Signature verified")) ~= nil)
close_result()
jwt.decode((signed:gsub("3Jb9", "4Jb9")), { verify = true })
local _, failed = result("verification failed:")
check("tampered", failed and failed:find("Signature verification failed", 1, true), failed)

print(failures == 0 and "ALL PASSED" or (failures .. " FAILED"))
os.exit(failures == 0 and 0 or 1)
