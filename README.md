# Amp Vim Plugin

This plugin allows the [Amp CLI](https://ampcode.com/manual#cli) to see the file you currently have open in your Vim instance, along with your cursor position and your text selection.

https://github.com/user-attachments/assets/3a5f136f-7b0a-445f-90be-b4e5b28a7e82

When installed, this plugin allows Vim to:

- Notify Amp about currently open file
- Notify Amp about selected code
- Send messages to the Amp agent (see [Sending Messages to Amp](#sending-messages-to-amp))
- Read and edit files through the Vim buffers

## Installation

Install the plugin using your preferred Vim plugin manager:

### vim-plug
```vim
Plug 'sourcegraph/amp.nvim'
```

### Vundle
```vim
Plugin 'sourcegraph/amp.nvim'
```

### Pathogen
```bash
cd ~/.vim/bundle
git clone https://github.com/sourcegraph/amp.nvim.git
```

### Requirements
- Vim 8.0+ with Python 3 support (`:echo has('python3')` should return `1`)
- Python 3.7+
- Python packages: `pip install -r python3/requirements.txt`

Once installed, start server in a running vim instance using `:AmpStart`. Run `amp --ide` to connect.

## Commands

- `:AmpStart` - Start the WebSocket server
- `:AmpStop` - Stop the WebSocket server
- `:AmpStatus` - Show server status and connection state
- `:AmpTest` - Test IDE protocol notifications

## Sending Messages to Amp

The plugin provides a `amp#message#send()` function that you can use to create your own commands and workflows. Here are example commands you can add to your `.vimrc`:

### Example Commands

```vim
" Send a quick message to the agent
command! -nargs=* AmpSend call amp#message#send_message(<q-args>)

" Send entire buffer contents
command! -nargs=0 AmpSendBuffer call amp#message#send_message(join(getline(1, '$'), "\n"))

" Add selected text directly to prompt (visual mode)
command! -range AmpPromptSelection call amp#message#send_to_prompt(join(getline(<line1>, <line2>), "\n"))

" Add file+selection reference to prompt
command! -range AmpPromptRef call s:SendFileRef(<line1>, <line2>)

function! s:SendFileRef(line1, line2)
  let l:bufname = expand('%:p')
  if l:bufname == ''
    echo 'Current buffer has no filename'
    return
  endif
  
  let l:ref = '@' . fnamemodify(l:bufname, ':.')
  if a:line1 != a:line2
    let l:ref .= '#L' . a:line1 . '-' . a:line2
  elseif a:line1 > 1
    let l:ref .= '#L' . a:line1
  endif
  
  call amp#message#send_to_prompt(l:ref)
endfunction
```

## Feature Ideas

Do you have a feature request or an idea? Submit an issue in this repo!

- Better reconnect: Vim users are much more likely to reopen their editor than JetBrains users. Because of that, we should check if we can automatically reconnect to an IDE in the same path that we had the last connection with.
- When I ask Amp to show me a particular section of code, it would be nice if Amp could open that file and select the code for me.
- Should we keep the code selection when moving between splits? Currently you can't switch to a split terminal if you don't want to lose the selection, making the built in terminal unfeasible for code selection.

## Development

This is a hybrid Vim/Python plugin:
- **VimScript**: Provides Vim integration and UI commands
- **Python**: Runs WebSocket server and handles JSON-RPC communication

For Python dependencies:
```bash
pip install -r python3/requirements.txt
```

## Cross-Platform Support

The plugin uses the same lockfile directory pattern as the main Amp repository:

- **Windows & macOS**: `~/.local/share/amp/ide`
- **Linux**: `$XDG_DATA_HOME/amp/ide` or `~/.local/share/amp/ide`

You can override the data directory by setting the `AMP_DATA_HOME` environment variable for testing or custom setups.
