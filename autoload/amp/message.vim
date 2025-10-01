" Message sending functionality for Amp Vim plugin

" Send a message to the agent or IDE
" @param message_dict dict The notification data to send
" @return boolean Whether message was sent successfully
function! amp#message#send(message_dict) abort
  if !exists('g:amp_channel') || type(g:amp_channel) != v:t_channel
    echohl WarningMsg
    echom 'Amp: Server is not running - start it first with :AmpStart'
    echohl None
    return v:false
  endif

  if ch_status(g:amp_channel) !=# 'open'
    echohl ErrorMsg
    echom 'Amp: Channel is not open'
    echohl None
    return v:false
  endif

  let l:wrapped_message = {
    \ 'method': 'broadcast',
    \ 'params': {
    \   'serverNotification': a:message_dict
    \ }
    \ }

  try
    " Use ch_sendraw with JSON encoding for nl mode channels
    let l:json_msg = json_encode(l:wrapped_message)
    call amp#logger#debug('message', 'Sending to Python: ' . l:json_msg[:80])
    call ch_sendraw(g:amp_channel, l:json_msg . "\n")
    return v:true
  catch
    echohl ErrorMsg
    echom 'Amp: Failed to send message: ' . v:exception
    echohl None
    return v:false
  endtry
endfunction

" Send a message to the agent using userSentMessage notification
" @param message string The message to send
" @return boolean Whether message was sent successfully
function! amp#message#send_message(message) abort
  return amp#message#send({'userSentMessage': {'message': a:message}})
endfunction

" Send a message to append to the prompt field in the IDE
" @param message string The message to append to the prompt
" @return boolean Whether message was sent successfully
function! amp#message#send_to_prompt(message) abort
  return amp#message#send({'appendToPrompt': {'message': a:message}})
endfunction
