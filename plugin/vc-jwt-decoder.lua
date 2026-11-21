if vim.g.loaded_vc_jwt_decoder then
  return
end
vim.g.loaded_vc_jwt_decoder = true

if vim.fn.has("nvim-0.10") == 0 then
  vim.notify("vc-jwt-decoder.nvim requires Neovim 0.10+", vim.log.levels.ERROR)
  return
end

vim.filetype.add({ extension = { jwt = "jwt" } })

-- :JwtDecode        whole buffer       :'<,'>JwtDecode  selected lines
-- :JwtDecode!       skip signature verification
-- :JwtDecode <tok>  decode the given token
vim.api.nvim_create_user_command("JwtDecode", function(o)
  local jwt = require("vc-jwt-decoder")
  local opts = o.bang and { verify = false } or nil
  if o.args ~= "" then
    jwt.decode(o.args, opts)
  else
    jwt.decode_range(o.line1, o.line2, opts)
  end
end, { range = "%", bang = true, nargs = "?", desc = "Decode a JWT / VC-JWT" })

vim.api.nvim_create_user_command("JwtDecodeCursor", function(o)
  require("vc-jwt-decoder").decode_cursor(o.bang and { verify = false } or nil)
end, { bang = true, desc = "Decode the JWT under the cursor" })

vim.keymap.set("n", "<Plug>(JwtDecodeCursor)", function()
  require("vc-jwt-decoder").decode_cursor()
end, { desc = "Decode JWT under cursor" })
vim.keymap.set("x", "<Plug>(JwtDecodeSelection)", function()
  require("vc-jwt-decoder").decode_selection()
end, { desc = "Decode selected JWT" })

-- Registered here (not in setup) so `nvim token.jwt` also triggers it.
vim.api.nvim_create_autocmd("BufReadPost", {
  group = vim.api.nvim_create_augroup("vc-jwt-decoder", { clear = true }),
  pattern = "*.jwt",
  callback = function(ev)
    local jwt = require("vc-jwt-decoder")
    if jwt.config.auto_open and vim.api.nvim_buf_line_count(ev.buf) > 0 then
      vim.api.nvim_buf_call(ev.buf, function()
        jwt.decode_range(1, vim.api.nvim_buf_line_count(ev.buf))
      end)
    end
  end,
})
