local M = {}

function M.check()
  vim.health.start("vc-jwt-decoder.nvim")

  if vim.fn.has("nvim-0.10") == 1 then
    vim.health.ok("Neovim " .. tostring(vim.version()))
  else
    vim.health.error("Neovim 0.10+ is required (vim.system)")
  end

  local jwt = require("vc-jwt-decoder")
  local cmd, err = jwt.resolve_cmd()
  if not cmd then
    vim.health.error(err, { "uv tool install 'vc-jwt-decoder[cli]'", "or: pipx install 'vc-jwt-decoder[cli]'" })
    return
  end

  if vim.fn.executable(cmd[1]) == 0 then
    vim.health.error(("configured command '%s' is not executable"):format(cmd[1]))
    return
  end

  if cmd[1] == "uvx" then
    vim.health.warn("using uvx (slower first run); install the CLI for faster startup", {
      "uv tool install 'vc-jwt-decoder[cli]'",
    })
  end

  local r = vim.system(vim.list_extend(vim.deepcopy(cmd), { "--version" }), { text = true }):wait(60000)
  local out = vim.trim((r.stdout or "") .. (r.stderr or ""))
  if r.code == 0 then
    vim.health.ok(("%s (%s)"):format(out, table.concat(cmd, " ")))
  elseif out:find("cli' extra", 1, true) then
    vim.health.error("vc-jwt-decoder is installed without the CLI extra", {
      "uv tool install --force 'vc-jwt-decoder[cli]'",
    })
  else
    vim.health.error(("`%s --version` failed: %s"):format(table.concat(cmd, " "), out))
  end

  vim.health.info(("verify=%s, auto_open=%s, split=%s"):format(
    tostring(jwt.config.verify),
    tostring(jwt.config.auto_open),
    jwt.config.split
  ))
end

return M
