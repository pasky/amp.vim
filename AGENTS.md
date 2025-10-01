# Agent Instructions for amp.nvim

## Commands
- **Format**: N/A (VimScript doesn't have a standard formatter)
- **Lint**: `:checkhealth amp` (in Vim)
- **Testing**: `./test_interactive.sh` (automated integration test with tmux, Vim, and Amp CLI)

## Architecture
- **Languages**: VimScript (frontend) + Python 3 (backend server)
- **Structure**: Plugin that exposes a WebSocket server (Python) for Amp CLI integration, with Vim frontend
- **Core modules**: 
  - VimScript: `autoload/amp/server.vim` (server lifecycle), `autoload/amp/selection.vim` (cursor tracking), `autoload/amp/visible_files.vim` (buffer tracking), `autoload/amp/message.vim` (send messages to Amp), `autoload/amp/config.vim` (configuration), `autoload/amp/logger.vim` (logging)
  - Python: `python3/amp_server.py` (WebSocket server, JSON-RPC bridge to Vim)
- **Entry point**: `plugin/amp.vim` with auto-initialization

## Code Style
- **VimScript**: 
  - Autoload pattern: `autoload/amp/module.vim` with `amp#module#function()` naming
  - Use `function! amp#module#func() abort` for autoload functions
  - Prefer `call` for function invocation with side effects
  - Error handling: Check return values, use `echohl ErrorMsg` for user-facing errors
  - Use `let l:var` for local variables, `g:` for globals
  - Comments: Use `"` for line comments
- **Python**:
  - Type hints for function signatures
  - Async/await for I/O operations (websockets, JSON-RPC)
  - Use `logging` module for debug output
  - Error handling: explicit exception catching with logging
