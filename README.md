# vc-jwt-decoder.nvim

Decode JWTs and Verifiable Credential JWTs in Neovim. You can also unpack enveloped VCs inside VPs and verify signatures (did:web, did:key, did:jwk, OIDC discovery).

This is the Neovim counterpart of the [VC JWT Decoder](https://gitlab.com/riphixel/vc-jwt-decoder-vsx) VS Code extension. Both use the same Python decoder, [`vc-jwt-decoder`](https://pypi.org/project/vc-jwt-decoder/), through its CLI.

## Features

- `*.jwt` files open with the decoded view in a split.
- Decode the whole buffer, a selection, an argument, or the token under the cursor. A cursor or selection can sit in a log line, a `Bearer …` header or a quoted string.
- Results open beside the current window in the CLI's own layout: a panel each for header and payload, the signature status with key details (`✓ Signature verified (RS256 · RSA · 2048-bit · SHA-256)`) in the panel title, and every enveloped VC decoded the same way. If a check fails, its steps are listed below the panels.
- The view is a normal read-only buffer with the CLI's colors as highlights, on your colorscheme's background, so you can search and yank in it. The panels are laid out for the window width when they open; after resizing, press `r` to lay them out again. Close it with `q`.
- Runs asynchronously, so key resolution over the network doesn't block the editor.

## Requirements

- Neovim 0.10+
- The `vc-jwt-decoder` CLI:

  ```sh
  uv tool install 'vc-jwt-decoder[cli]'
  ```

  If the CLI is missing but `uvx` is available, the plugin falls back to `uvx --from 'vc-jwt-decoder[cli]' vc-jwt-decoder`.

Run `:checkhealth vc-jwt-decoder` to confirm the setup works.

## Installation

[lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "riphixel/vc-jwt-decoder.nvim", -- adjust to wherever you host it
  ft = "jwt",
  cmd = { "JwtDecode", "JwtDecodeCursor" },
  keys = {
    { "<leader>jd", "<Plug>(JwtDecodeCursor)", desc = "Decode JWT under cursor" },
    { "<leader>jd", "<Plug>(JwtDecodeSelection)", mode = "x", desc = "Decode selected JWT" },
  },
  opts = {},
}
```

From a local checkout: `{ dir = "~/Code/vc-jwt-decoder.nvim", ... }`.

## Usage

| Command | Action |
|---|---|
| `:JwtDecode` | Decode the whole buffer |
| `:'<,'>JwtDecode` | Decode the selected lines |
| `:JwtDecode {token}` | Decode the given token |
| `:JwtDecodeCursor` | Decode the token under the cursor |
| `!` on either command | Skip signature verification (no network) |

The plugin sets no mappings of its own. It provides `<Plug>(JwtDecodeCursor)` (normal mode) and `<Plug>(JwtDecodeSelection)` (visual mode) for you to map.

## Configuration

These are the defaults:

```lua
require("vc-jwt-decoder").setup({
  cmd = nil,           -- e.g. { "vc-jwt-decoder" }; nil = auto-detect
  verify = true,       -- verify signatures (may fetch DID documents / JWKS)
  auto_open = true,    -- decode *.jwt files when opened
  split = "vertical",  -- "vertical" | "horizontal" | "tab"
})
```

Calling `setup()` is optional.

## Tests

```sh
nvim --headless -u NONE -l tests/run.lua
```

The tests run the real CLI. Signature checks use an offline did:key token.

## License

MIT
