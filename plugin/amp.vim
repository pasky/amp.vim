" amp.vim - Main entry point for Amp plugin
" Manages user commands and plugin lifecycle

if exists('g:loaded_amp')
  finish
endif
let g:loaded_amp = 1

" Plugin state
let g:amp_state = {
      \ 'port': v:null,
      \ 'auth_token': v:null,
      \ 'connected': v:false,
      \ 'initialized': v:false
      \ }

" Initialize plugin on first load
function! s:Init()
  if g:amp_state.initialized
    return
  endif

  call amp#config#setup({})
  let g:amp_state.initialized = v:true
endfunction

" Start the Amp server
function! s:AmpStart()
  call s:Init()
  call amp#server#start()
endfunction

" Stop the Amp server
function! s:AmpStop()
  call amp#server#stop()
endfunction

" Show server status
function! s:AmpStatus()
  if amp#server#is_running()
    let l:status = g:amp_state.connected ? 'connected' : 'waiting for clients'
    echomsg 'Server is running on port ' . g:amp_state.port . ' (' . l:status . ')'
  else
    echomsg 'Server is not running'
  endif
endfunction

" Test IDE protocol notifications
function! s:AmpTest()
  if !amp#server#is_running()
    echohl WarningMsg
    echomsg 'Server is not running - start it first with :AmpStart'
    echohl None
    return
  endif

  echomsg 'Testing IDE protocol notifications...'

  call amp#selection#send_current()
  call amp#visible_files#send_current()

  echomsg 'IDE notifications sent!'
endfunction

" Define user commands
command! -nargs=0 AmpStart call s:AmpStart()
command! -nargs=0 AmpStop call s:AmpStop()
command! -nargs=0 AmpStatus call s:AmpStatus()
command! -nargs=0 AmpTest call s:AmpTest()

" Cleanup on exit
augroup AmpPluginShutdown
  autocmd!
  autocmd VimLeavePre * call amp#server#stop()
augroup END
