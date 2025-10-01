" logger.vim - Logging utilities for amp.vim

let s:log_levels = {
    \ 'trace': 1,
    \ 'debug': 2,
    \ 'info': 3,
    \ 'warn': 4,
    \ 'error': 5,
    \ }

let s:current_level = 3
let s:last_error = {}

function! amp#logger#setup(config) abort
    if has_key(a:config, 'log_level') && has_key(s:log_levels, a:config.log_level)
        let s:current_level = s:log_levels[a:config.log_level]
    endif
endfunction

function! s:log(level, context, ...) abort
    if s:log_levels[a:level] >= s:current_level
        let l:message = join(a:000, ' ')
        let l:formatted = printf('[%s] %s: %s', toupper(a:level), a:context, l:message)
        if a:level ==# 'debug' || a:level ==# 'trace'
            echo l:formatted
        else
            echom l:formatted
        endif
    endif
endfunction

function! amp#logger#trace(context, ...) abort
    call call('s:log', ['trace', a:context] + a:000)
endfunction

function! amp#logger#debug(context, ...) abort
    call call('s:log', ['debug', a:context] + a:000)
endfunction

function! amp#logger#info(context, ...) abort
    call call('s:log', ['info', a:context] + a:000)
endfunction

function! amp#logger#warn(context, ...) abort
    call call('s:log', ['warn', a:context] + a:000)
endfunction

function! amp#logger#error(context, ...) abort
    let l:message = join(a:000, ' ')
    let s:last_error = {
        \ 'context': a:context,
        \ 'message': l:message,
        \ 'timestamp': localtime(),
        \ }
    call call('s:log', ['error', a:context] + a:000)
endfunction

function! amp#logger#get_last_error() abort
    return s:last_error
endfunction
