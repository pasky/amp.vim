" amp#config - Configuration management
" Port of lua/amp/config.lua

if exists('g:autoloaded_amp_config')
  finish
endif
let g:autoloaded_amp_config = 1

let s:defaults = {
      \ 'port_range': { 'min': 10000, 'max': 65535 },
      \ 'auto_start': v:true,
      \ 'log_level': 'info',
      \ }

let s:config = {}

function! s:validate(config) abort
  if type(a:config.port_range) != v:t_dict
    throw 'Invalid port range: not a dictionary'
  endif

  if !has_key(a:config.port_range, 'min') || type(a:config.port_range.min) != v:t_number
    throw 'Invalid port range: min must be a number'
  endif

  if !has_key(a:config.port_range, 'max') || type(a:config.port_range.max) != v:t_number
    throw 'Invalid port range: max must be a number'
  endif

  if a:config.port_range.min <= 0
    throw 'Invalid port range: min must be > 0'
  endif

  if a:config.port_range.max > 65535
    throw 'Invalid port range: max must be <= 65535'
  endif

  if a:config.port_range.min > a:config.port_range.max
    throw 'Invalid port range: min must be <= max'
  endif

  if type(a:config.auto_start) != v:t_bool
    throw 'auto_start must be a boolean'
  endif

  let l:valid_log_levels = ['trace', 'debug', 'info', 'warn', 'error']
  if index(l:valid_log_levels, a:config.log_level) == -1
    throw 'log_level must be one of: ' . join(l:valid_log_levels, ', ')
  endif

  return v:true
endfunction

function! amp#config#setup(user_config) abort
  let l:config = deepcopy(s:defaults)
  
  if !empty(a:user_config)
    call extend(l:config, a:user_config, 'force')
  endif

  call s:validate(l:config)
  let s:config = l:config

  return l:config
endfunction

function! amp#config#get() abort
  if empty(s:config)
    return deepcopy(s:defaults)
  endif
  return deepcopy(s:config)
endfunction

function! amp#config#defaults() abort
  return deepcopy(s:defaults)
endfunction
