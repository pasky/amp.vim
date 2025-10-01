" server.vim - Server lifecycle management
" Manages Python subprocess that handles WebSocket server

let s:job = v:null
let s:channel = v:null

" Start the Python WebSocket server subprocess
function! amp#server#start() abort
  if s:job isnot v:null
    call amp#logger#warn('server', 'Server is already running on port ' . g:amp_state.port)
    return
  endif

  " Generate random auth token (Python will handle lockfile)
  let l:chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
  let l:auth_token = ''
  for l:i in range(32)
    let l:auth_token .= l:chars[rand() % len(l:chars)]
  endfor

  let g:amp_state.auth_token = l:auth_token

  " Get path to Python script
  " When sourced from autoload, use the &runtimepath to find python3/amp_server.py
  let l:rtp_dirs = split(&runtimepath, ',')
  let l:python_script = ''
  for l:rtp_dir in l:rtp_dirs
    let l:candidate = l:rtp_dir . '/python3/amp_server.py'
    if filereadable(l:candidate)
      let l:python_script = l:candidate
      break
    endif
  endfor

  if empty(l:python_script) || !filereadable(l:python_script)
    call amp#logger#error('server', 'Python server script not found: ' . l:python_script)
    return
  endif

  call amp#logger#debug('server', 'Starting Python WebSocket server subprocess')

  " Start Python subprocess with line-based channel (unbuffered)
  " CRITICAL: Must specify in_io: 'pipe' for stdin to work!
  let s:job = job_start(
        \ ['python3', '-u', l:python_script, l:auth_token],
        \ {
        \   'in_io': 'pipe',
        \   'in_mode': 'nl',
        \   'out_io': 'pipe',
        \   'out_mode': 'nl',
        \   'out_cb': function('s:OnLine'),
        \   'err_io': 'pipe',
        \   'err_mode': 'raw',
        \   'err_cb': function('s:OnError'),
        \   'exit_cb': function('s:OnExit')
        \ }
        \ )

  if job_status(s:job) !=# 'run'
    call amp#logger#error('server', 'Failed to start Python subprocess')
    let s:job = v:null
    return
  endif

  let s:channel = job_getchannel(s:job)
  let g:amp_channel = s:channel
  call amp#logger#debug('server', 'Python subprocess started, waiting for server...')
  
  " Poll for port update (workaround for async callback timing)
  call timer_start(100, {-> s:CheckServerStarted()}, {'repeat': 30})
endfunction

" Check if server has started and port is set
function! s:CheckServerStarted() abort
  if s:job is v:null || job_status(s:job) !=# 'run'
    return
  endif
  
  if g:amp_state.port isnot v:null
    return
  endif
  
  " Callback should fire automatically, just wait
endfunction

" Stop the Python subprocess
function! amp#server#stop() abort
  if s:job is v:null
    "call amp#logger#info('server', 'Server is not running')
    return
  endif

  call amp#logger#debug('server', 'Stopping server...')

  " Disable IDE features first
  call amp#selection#stop()
  call amp#visible_files#stop()

  " Save job reference (OnExit callback might set s:job to v:null)
  let l:job = s:job
  let l:channel = s:channel

  " Send stop notification to Python and wait for it to process
  call s:SendJson({'method': 'stop', 'params': {}})
  sleep 50m
  
  " Stop job (Python should exit on its own after stop message)
  if l:job isnot v:null && job_status(l:job) ==# 'run'
    call job_stop(l:job, 'term')
    " Give it time to terminate gracefully and clean up lockfile
    sleep 100m
    if job_status(l:job) ==# 'run'
      call job_stop(l:job, 'kill')
    endif
  endif
  
  " Close channel after job is stopped
  if l:channel isnot v:null
    silent! call ch_close(l:channel)
  endif

  let s:job = v:null
  let s:channel = v:null
  
  if exists('g:amp_state')
    let g:amp_state.port = v:null
    let g:amp_state.auth_token = v:null
    let g:amp_state.connected = v:false
  endif

  call amp#logger#info('server', 'Server stopped')
endfunction

" Check if server is running
function! amp#server#is_running() abort
  return s:job isnot v:null && job_status(s:job) ==# 'run'
endfunction

" Send message to Python subprocess
function! amp#server#send(data) abort
  if s:channel is v:null || ch_status(s:channel) !=# 'open'
    call amp#logger#warn('server', 'Cannot send: channel not open')
    return
  endif

  call s:SendJson( a:data)
endfunction

" Send JSON message to Python without expecting reply
function! s:SendJson(msg) abort
  if s:channel is v:null || ch_status(s:channel) !=# 'open'
    return
  endif
  call ch_sendraw(s:channel, json_encode(a:msg) . "\n")
endfunction

" Handle line from Python subprocess (nl mode)
function! s:OnLine(channel, line) abort
  try
    " Parse JSON from line
    let l:msg = json_decode(a:line)
    
    call amp#logger#debug('server', 'recv: ' . string(l:msg))
    
    let l:method = get(l:msg, 'method', '')
    let l:params = get(l:msg, 'params', {})
    let l:id = get(l:msg, 'id', v:null)

    " Handle notifications from Python
    if l:method ==# 'serverStarted'
      call s:OnServerStarted(l:params)
    elseif l:method ==# 'clientConnected'
      call s:OnClientConnected()
    elseif l:method ==# 'clientDisconnected'
      call s:OnClientDisconnected()
    elseif l:method ==# 'readFile'
      call s:OnReadFile(l:id, l:params)
    elseif l:method ==# 'editFile'
      call s:OnEditFile(l:id, l:params)
    else
      call amp#logger#warn('server', 'Unknown message from Python: ' . l:method)
    endif
  catch
    call amp#logger#error('server', 'OnLine error: ' . v:exception . ' line=' . a:line)
  endtry
endfunction

" Handle serverStarted notification
function! s:OnServerStarted(params) abort
  let l:port = get(a:params, 'port', 0)
  let g:amp_state.port = l:port

  call amp#logger#info('server', 'Server started on port ' . l:port)

  " Lockfile created by Python subprocess

  " Enable IDE features
  call amp#selection#start()
  call amp#visible_files#start()

  call amp#logger#debug('server', 'IDE protocol features enabled')
endfunction

" Handle clientConnected notification
function! s:OnClientConnected() abort
  let l:was_connected = g:amp_state.connected
  let g:amp_state.connected = v:true

  if !l:was_connected
    call amp#logger#info('server', 'Connected to Amp')
    " Send current state to new client
    call amp#selection#send_current()
    call amp#visible_files#send_current()
  endif
endfunction

" Handle clientDisconnected notification
function! s:OnClientDisconnected() abort
  let l:was_connected = g:amp_state.connected
  let g:amp_state.connected = v:false

  if l:was_connected
    call amp#logger#info('server', 'Disconnected from Amp')
  endif
endfunction

" Handle readFile request from Python
function! s:OnReadFile(id, params) abort
  let l:path = get(a:params, 'path', '')

  if empty(l:path)
    call s:SendJson( {
          \ 'id': a:id,
          \ 'error': {'code': -1, 'message': 'Missing path parameter'}
          \ })
    return
  endif

  if !filereadable(l:path)
    call s:SendJson( {
          \ 'id': a:id,
          \ 'error': {'code': -1, 'message': 'File not found or not readable'}
          \ })
    return
  endif

  try
    let l:content = join(readfile(l:path, 'b'), "\n")
    call s:SendJson( {
          \ 'id': a:id,
          \ 'result': {'content': l:content, 'encoding': 'utf-8'}
          \ })
  catch
    call s:SendJson( {
          \ 'id': a:id,
          \ 'error': {'code': -1, 'message': 'Failed to read file: ' . v:exception}
          \ })
  endtry
endfunction

" Handle editFile request from Python
function! s:OnEditFile(id, params) abort
  let l:path = get(a:params, 'path', '')
  let l:content = get(a:params, 'fullContent', '')

  if empty(l:path)
    call s:SendJson( {
          \ 'id': a:id,
          \ 'error': {'code': -1, 'message': 'Missing path parameter'}
          \ })
    return
  endif

  if !has_key(a:params, 'fullContent')
    call s:SendJson( {
          \ 'id': a:id,
          \ 'error': {'code': -1, 'message': 'Missing fullContent parameter'}
          \ })
    return
  endif

  try
    " Normalize to absolute path
    let l:full_path = fnamemodify(l:path, ':p')

    " Get or create buffer for this file
    let l:bufnr = bufnr(l:full_path, 1)

    " Load buffer if not loaded
    if !bufloaded(l:bufnr)
      silent! execute 'buffer ' . l:bufnr
    endif

    " Split content into lines, preserving empty lines
    let l:lines = split(l:content, "\n", 1)
    
    " Remove trailing empty line if present (from final newline)
    if len(l:lines) > 0 && l:lines[-1] ==# ''
      call remove(l:lines, -1)
    endif

    " Save cursor position if editing current buffer
    let l:is_current = bufnr('%') == l:bufnr
    if l:is_current
      let l:save_pos = getcurpos()
    endif

    " Replace buffer content
    call amp#logger#info('server', 'EditFile: updating buffer ' . l:bufnr . ' (current=' . bufnr('%') . ')')
    call deletebufline(l:bufnr, 1, '$')
    call setbufline(l:bufnr, 1, l:lines)

    " Write buffer to disk using Vim's write command
    if l:is_current
      " Current buffer - write it directly without autocommands
      noautocmd write!
      " Restore cursor position
      call setpos('.', l:save_pos)
    else
      " Not current buffer - use bufdo to write it
      let l:cur_buf = bufnr('%')
      execute 'noautocmd buffer ' . l:bufnr
      noautocmd write!
      execute 'noautocmd buffer ' . l:cur_buf
    endif

    call s:SendJson( {
          \ 'id': a:id,
          \ 'result': {'success': v:true, 'message': 'Edit applied successfully'}
          \ })
  catch
    call s:SendJson( {
          \ 'id': a:id,
          \ 'error': {'code': -1, 'message': 'Failed to edit file: ' . v:exception}
          \ })
  endtry
endfunction

" Handle subprocess exit
function! s:OnExit(job, status) abort
  call amp#logger#debug('server', 'Python subprocess exited with status ' . a:status)

  " Status -1 is normal when Vim sends SIGTERM, don't report as error
  if a:status != 0 && a:status != -1
    call amp#logger#error('server', 'Python subprocess crashed (status ' . a:status . ')')
  endif

  let s:job = v:null
  let s:channel = v:null
  if exists('g:amp_state')
    let g:amp_state.port = v:null
    let g:amp_state.connected = v:false
  endif
endfunction

" Handle stderr from subprocess
function! s:OnError(channel, msg) abort
  if !empty(a:msg)
    call amp#logger#debug('server', 'Python: ' . a:msg)
  endif
endfunction


