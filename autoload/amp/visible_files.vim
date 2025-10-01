" Visible files tracking for Amp Vim plugin

" State management
let s:tracking_enabled = 0
let s:latest_files = []

" Start visible files tracking
function! amp#visible_files#start() abort
  if s:tracking_enabled
    return
  endif

  let s:tracking_enabled = 1
  call s:create_autocommands()
  call amp#logger#debug('visible_files', 'Visible files tracking enabled')

  " Send initial visible files after delay
  call timer_start(100, {-> amp#visible_files#send_current()})
endfunction

" Stop visible files tracking
function! amp#visible_files#stop() abort
  if !s:tracking_enabled
    return
  endif

  let s:tracking_enabled = 0
  call s:clear_autocommands()
  let s:latest_files = []
  call amp#logger#debug('visible_files', 'Visible files tracking disabled')
endfunction

" Get all currently visible files
function! s:get_current_visible_files() abort
  let l:uris = []
  let l:seen = {}

  " Get all buffers that are displayed in windows
  for l:win in range(1, winnr('$'))
    let l:bufnr = winbufnr(l:win)
    if l:bufnr != -1
      let l:name = bufname(l:bufnr)
      if l:name != '' && !has_key(l:seen, l:name)
        " Check if file exists before adding to URIs
        if filereadable(l:name)
          let l:seen[l:name] = 1
          " Convert to absolute path
          let l:abspath = fnamemodify(l:name, ':p')
          call add(l:uris, 'file://' . l:abspath)
        endif
      endif
    endif
  endfor

  return l:uris
endfunction

" Check if visible files have changed
function! s:have_files_changed(new_files) abort
  let l:old_files = s:latest_files

  if len(l:old_files) != len(a:new_files)
    return 1
  endif

  " Create sets for comparison
  let l:old_set = {}
  for l:uri in l:old_files
    let l:old_set[l:uri] = 1
  endfor

  for l:uri in a:new_files
    if !has_key(l:old_set, l:uri)
      return 1
    endif
  endfor

  return 0
endfunction

" Send visible files if changed
function! amp#visible_files#send_current(...) abort
  let l:force = a:0 > 0 ? a:1 : 0
  
  if !s:tracking_enabled
    return
  endif

  let l:current_files = s:get_current_visible_files()

  if l:force || s:have_files_changed(l:current_files)
    let s:latest_files = l:current_files

    call amp#message#send({
          \ 'visibleFilesDidChange': {'uris': l:current_files}
          \ })

    call amp#logger#debug('visible_files', 'Visible files changed, count:', len(l:current_files))
    let l:i = 0
    for l:uri in l:current_files
      let l:i += 1
      if l:i <= 3
        let l:filename = matchstr(l:uri, 'file://.*/\zs.*')
        if l:filename == ''
          let l:filename = l:uri
        endif
        call amp#logger#debug('visible_files', '  ' . l:i . ':', l:filename)
      elseif l:i == 4 && len(l:current_files) > 3
        call amp#logger#debug('visible_files', '  ... and', len(l:current_files) - 3, 'more files')
        break
      endif
    endfor
  endif
endfunction

" Create autocommands for visible files tracking
function! s:create_autocommands() abort
  augroup AmpVisibleFiles
    autocmd!
    " Buffer events
    autocmd BufWinEnter,BufWinLeave * call timer_start(10, {-> amp#visible_files#send_current()})
    " Window events
    autocmd WinNew,WinClosed * call timer_start(10, {-> amp#visible_files#send_current()})
    " Tab events
    autocmd TabEnter,TabClosed,TabNew * call timer_start(10, {-> amp#visible_files#send_current()})
    " File events
    autocmd BufRead,BufNewFile * call timer_start(10, {-> amp#visible_files#send_current()})
  augroup END
endfunction

" Clear autocommands
function! s:clear_autocommands() abort
  augroup AmpVisibleFiles
    autocmd!
  augroup END
endfunction
