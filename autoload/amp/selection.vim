" Selection tracking for Amp Vim plugin

" State management
let s:state = {
      \ 'latest_selection': v:null,
      \ 'tracking_enabled': 0,
      \ 'debounce_timer': v:null,
      \ 'debounce_ms': 10,
      \ }

let s:server = v:null

" Start selection tracking
function! amp#selection#start() abort
  if s:state.tracking_enabled
    return
  endif

  let s:state.tracking_enabled = 1

  call s:create_autocommands()
  call amp#logger#debug('selection', 'Selection tracking enabled')
endfunction

" Stop selection tracking
function! amp#selection#stop() abort
  if !s:state.tracking_enabled
    return
  endif

  let s:state.tracking_enabled = 0
  call s:clear_autocommands()

  let s:state.latest_selection = v:null
  let s:server = v:null

  if s:state.debounce_timer isnot v:null
    call timer_stop(s:state.debounce_timer)
    let s:state.debounce_timer = v:null
  endif

  call amp#logger#debug('selection', 'Selection tracking disabled')
endfunction

" Convert internal selection format to IDE protocol format
function! s:to_ide_format(internal_selection) abort
  return {
        \ 'uri': a:internal_selection.fileUrl,
        \ 'selections': [{
        \   'range': {
        \     'startLine': a:internal_selection.selection.start.line,
        \     'startCharacter': a:internal_selection.selection.start.character,
        \     'endLine': a:internal_selection.selection.end.line,
        \     'endCharacter': a:internal_selection.selection.end.character,
        \   },
        \   'content': a:internal_selection.text,
        \ }],
        \ }
endfunction

" Get current cursor position as selection
function! s:get_cursor_position() abort
  let l:file_path = expand('%:p')

  if empty(l:file_path)
    return v:null
  endif

  let l:cursor_pos = getpos('.')
  let l:line_num = l:cursor_pos[1]
  let l:col_num = l:cursor_pos[2] - 1

  " Get the line content at cursor position
  let l:line_content = ''
  try
    let l:lines = getbufline('%', l:line_num)
    if !empty(l:lines)
      let l:line_content = l:lines[0]
    endif
  catch
  endtry

  return {
        \ 'text': '',
        \ 'fileUrl': 'file://' . l:file_path,
        \ 'selection': {
        \   'start': {'line': l:line_num - 1, 'character': l:col_num},
        \   'end': {'line': l:line_num - 1, 'character': l:col_num},
        \ },
        \ 'lineContent': l:line_content,
        \ }
endfunction

" Get current visual selection
function! s:get_visual_selection() abort
  let l:current_mode = mode()

  " Check if we're in visual mode (v, V, or Ctrl-V which is represented as "\<C-v>")
  if l:current_mode !=# 'v' && l:current_mode !=# 'V' && l:current_mode !=# "\<C-v>"
    return v:null
  endif

  let l:file_path = expand('%:p')

  if empty(l:file_path)
    return v:null
  endif

  " Get visual selection marks
  let l:start_pos = getpos('v')
  let l:end_pos = getpos('.')

  if l:start_pos[1] == 0 || l:end_pos[1] == 0
    return v:null
  endif

  " Convert to 0-indexed positions
  let l:start_line = l:start_pos[1] - 1
  let l:start_char = l:start_pos[2] - 1
  let l:end_line = l:end_pos[1] - 1
  let l:end_char = l:end_pos[2] - 1

  " Ensure start comes before end
  if l:start_line > l:end_line || (l:start_line == l:end_line && l:start_char > l:end_char)
    let [l:start_line, l:end_line] = [l:end_line, l:start_line]
    let [l:start_char, l:end_char] = [l:end_char, l:start_char]
  endif

  " Get selected text
  let l:lines = getbufline('%', l:start_line + 1, l:end_line + 1)
  let l:selected_text = ''

  if !empty(l:lines)
    if l:current_mode ==# 'V'
      " Line-wise selection
      let l:selected_text = join(l:lines, "\n")
    elseif len(l:lines) == 1
      " Single line selection
      let l:selected_text = strpart(l:lines[0], l:start_char, l:end_char - l:start_char + 1)
    else
      " Multi-line selection
      let l:text_parts = []
      call add(l:text_parts, strpart(l:lines[0], l:start_char))
      for l:i in range(1, len(l:lines) - 2)
        call add(l:text_parts, l:lines[l:i])
      endfor
      call add(l:text_parts, strpart(l:lines[-1], 0, l:end_char + 1))
      let l:selected_text = join(l:text_parts, "\n")
    endif
  endif

  return {
        \ 'text': l:selected_text,
        \ 'fileUrl': 'file://' . l:file_path,
        \ 'selection': {
        \   'start': {'line': l:start_line, 'character': l:start_char},
        \   'end': {'line': l:end_line, 'character': l:end_char},
        \ },
        \ }
endfunction

" Get current selection (visual or cursor)
function! s:get_current_selection() abort
  let l:visual_sel = s:get_visual_selection()
  if l:visual_sel isnot v:null
    return l:visual_sel
  endif

  return s:get_cursor_position()
endfunction

" Check if selection has changed
function! s:has_selection_changed(new_selection) abort
  let l:old_selection = s:state.latest_selection

  if a:new_selection is v:null
    return l:old_selection isnot v:null
  endif

  if l:old_selection is v:null
    return 1
  endif

  if l:old_selection.fileUrl !=# a:new_selection.fileUrl
    return 1
  endif

  if l:old_selection.text !=# a:new_selection.text
    return 1
  endif

  let l:old_sel = l:old_selection.selection
  let l:new_sel = a:new_selection.selection

  if l:old_sel.start.line != l:new_sel.start.line
        \ || l:old_sel.start.character != l:new_sel.start.character
        \ || l:old_sel.end.line != l:new_sel.end.line
        \ || l:old_sel.end.character != l:new_sel.end.character
    return 1
  endif

  return 0
endfunction

" Update and broadcast current selection
function! s:update_and_broadcast(...) abort
  let l:force = get(a:, 1, 0)

  if !s:state.tracking_enabled
    call amp#logger#debug('selection', 'Tracking not enabled')
    return
  endif

  let l:current_selection = s:get_current_selection()
  if l:current_selection is v:null
    call amp#logger#debug('selection', 'No current selection')
    return
  endif
  
  call amp#logger#debug('selection', 'Sending ' . l:current_selection.fileUrl)

  if l:force || s:has_selection_changed(l:current_selection)
    let s:state.latest_selection = l:current_selection

    let l:ide_notification = s:to_ide_format(l:current_selection)
    call amp#message#send({'selectionDidChange': l:ide_notification})

    call amp#logger#debug(
          \ 'selection',
          \ 'Selection changed:',
          \ l:ide_notification.uri,
          \ 'lines',
          \ l:ide_notification.selections[0].range.startLine + 1,
          \ '-',
          \ l:ide_notification.selections[0].range.endLine + 1
          \ )
  endif
endfunction

" Send current selection
function! amp#selection#send_current() abort
  call s:update_and_broadcast(1)
endfunction

" Debounced update function
function! s:debounced_update() abort
  if s:state.debounce_timer isnot v:null
    call timer_stop(s:state.debounce_timer)
  endif

  let s:state.debounce_timer = timer_start(s:state.debounce_ms, {-> s:debounce_callback()})
endfunction

" Debounce callback
function! s:debounce_callback() abort
  call s:update_and_broadcast()
  let s:state.debounce_timer = v:null
endfunction

" Create autocommands for selection tracking
function! s:create_autocommands() abort
  augroup AmpSelection
    autocmd!
    autocmd CursorMoved,CursorMovedI * call s:debounced_update()
    " ModeChanged is only available in Vim 8.2.4750+
    if exists('##ModeChanged')
      autocmd ModeChanged * call s:update_and_broadcast()
    endif
  augroup END
endfunction

" Clear autocommands
function! s:clear_autocommands() abort
  augroup AmpSelection
    autocmd!
  augroup END
endfunction
