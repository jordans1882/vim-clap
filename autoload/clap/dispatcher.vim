" Author: liuchengxu <xuliuchengxlc@gmail.com>
" Description: Job control of async provider.

let s:save_cpo = &cpoptions
set cpoptions&vim

let s:job_timer = -1
let s:dispatcher_delay = 300
let s:job_id = -1

let s:drop_cache = get(g:, 'clap_dispatcher_drop_cache', v:true)

function! s:jobstop() abort
  if s:job_id > 0
    call clap#job#stop(s:job_id)
    let s:job_id = -1
  endif
endfunction

if has('nvim')

  if s:drop_cache
    " to_cache is a List.
    function! s:handle_cache(to_cache) abort
      let s:dropped_size += len(a:to_cache)
    endfunction

    function! s:set_matches_count() abort
      let matches_count = s:loaded_size + s:dropped_size
      call clap#impl#refresh_matches_count(string(matches_count))
    endfunction
  else
    function! s:handle_cache(to_cache) abort
      call extend(g:clap.display.cache, a:to_cache)
    endfunction

    function! s:set_matches_count() abort
      let matches_count = s:loaded_size + len(g:clap.display.cache)
      call clap#impl#refresh_matches_count(string(matches_count))
    endfunction
  endif

  function! s:apply_append_or_cache(raw_output) abort
    let raw_output = a:raw_output

    " Here are dragons!
    let line_count = g:clap.display.line_count()

    " Reach the preload capacity for the first time
    " Append the minimum raw_output, the rest goes to the cache.
    if len(raw_output) + line_count >= g:clap.display.preload_capacity
      let start = g:clap.display.preload_capacity - line_count
      let to_append = raw_output[:start-1]
      let to_cache = raw_output[start :]

      " Discard?
      call s:handle_cache(to_cache)

      " Converter
      if s:has_converter
        let to_append = map(to_append, 's:Converter(v:val)')
      endif

      call g:clap.display.append_lines(to_append)

      let s:preload_is_complete = v:true
      let s:loaded_size = line_count + len(to_append)
    else
      if s:loaded_size == 0
        let s:loaded_size = len(raw_output)
      else
        let s:loaded_size = line_count + len(raw_output)
      endif
      if s:has_converter
        let raw_output = map(raw_output, 's:Converter(v:val)')
      endif
      call g:clap.display.append_lines(raw_output)
    endif

  endfunction

  function! s:append_output(data) abort
    if empty(a:data)
      return
    endif

    if s:preload_is_complete
      call s:handle_cache(a:data)
    else
      call s:apply_append_or_cache(a:data)
    endif

    call s:set_matches_count()
  endfunction

  function! s:on_event(job_id, data, event) abort
    " We only process the job that was spawned last time.
    if s:job_id == a:job_id
      if a:event ==# 'stdout'
        " Second last is the real last one for neovim.
        call s:append_output(a:data[:-2])
      elseif a:event ==# 'stderr'
        if !empty(a:data) && a:data != ['']
          let error_info = [
                \ 'Error occurs when dispatching the command',
                \ 'job_id: '.a:job_id,
                \ 'working directory: '.(exists('g:__clap_provider_cwd') ? g:__clap_provider_cwd : getcwd()),
                \ 'command: '.s:executed_cmd,
                \ 'message: '
                \ ]
          let error_info += a:data
          call s:abort_job(error_info)
        endif
      else
        call s:on_exit_common()
      endif
    endif
  endfunction

  function! s:job_start(cmd) abort
    " We choose the lcd way instead of the cwd option of job for the
    " consistence purpose.
    let s:job_id = jobstart(a:cmd, {
          \ 'on_exit': function('s:on_event'),
          \ 'on_stdout': function('s:on_event'),
          \ 'on_stderr': function('s:on_event'),
          \ })
  endfunction

else

  if s:drop_cache
    function! s:handle_cache(chunks) abort
      let s:dropped_size += len(a:chunks)
    endfunction

    function! s:matched_count_when_preload_is_complete() abort
      return s:loaded_size + s:dropped_size
    endfunction
  else
    function! s:handle_cache(chunks) abort
      call extend(g:clap.display.cache, a:chunks)
    endfunction

    function! s:matched_count_when_preload_is_complete() abort
      return s:loaded_size + len(g:clap.display.cache)
    endfunction
  endif

  function! s:update_indicator() abort
    if s:preload_is_complete
      let matches_count = s:matched_count_when_preload_is_complete()
    else
      let matches_count = g:clap.display.line_count()
    endif
    echom "[update_indicator] matches_count:".matches_count." dropped_size:".s:dropped_size." loaded_size:".s:loaded_size." preload_is_complete:".s:preload_is_complete

    call clap#impl#refresh_matches_count(string(matches_count))
  endfunction

  function! s:post_check() abort
    call s:on_exit_common()
    call s:update_indicator()
  endfunction

  function! s:out_cb(channel, message) abort
    if s:job_id > 0 && clap#job#vim8_job_id_of(a:channel) == s:job_id
      if s:preload_is_complete
        call s:handle_cache(a:message)
      else
        call add(s:vim_output, a:message)
        if len(s:vim_output) >= g:clap.display.preload_capacity
          call s:append_output(s:vim_output)
        endif
      endif
    endif
  endfunction

  function! s:err_cb(channel, message) abort
    if s:job_id > 0 && clap#job#vim8_job_id_of(a:channel) == s:job_id
      let error_info = [
            \ 'Error occurs when dispatching the command',
            \ 'working directory: '.(exists('g:__clap_provider_cwd') ? g:__clap_provider_cwd : getcwd()),
            \ 'channel: '.a:channel,
            \ 'message: '.string(a:message),
            \ 'command: '.s:executed_cmd,
            \ ]
      call s:abort_job(error_info)
    endif
  endfunction

  function! s:close_cb(channel) abort
    if s:job_id > 0 && clap#job#vim8_job_id_of(a:channel) == s:job_id
      echom "channel: ".string(a:channel)." closed"
      " if ch_status(a:channel) !=# 'closed'
      if ch_canread(s:poll_channel)
        let chunks = split(ch_readraw(a:channel), "\n")
        if s:preload_is_complete
          let s:dropped_size += len(chunks)
        else
          call s:apply_append_or_cache(chunks)
        endif
      endif

      call s:post_check()
    endif
  endfunction

  function! s:exit_cb(job, _exit_code) abort
    if s:job_id > 0 && clap#job#parse_vim8_job_id(a:job) == s:job_id
      echom "job: ".string(a:job)." is exited, exit_code: ".a:_exit_code ." ch_status: ".ch_status(s:poll_channel)

      " if ch_status(s:poll_channel) ==# 'open'
      if ch_canread(s:poll_channel)
        let chunks = split(ch_readraw(s:poll_channel), "\n")
        if s:preload_is_complete
          call s:handle_cache(chunks)
        else
          call s:apply_append_or_cache(chunks)
        endif
      endif

      call s:post_check()
    endif
  endfunction

  function! s:apply_append_or_cache(chunks) abort
    let chunks = a:chunks

    " Here are dragons!
    let line_count = g:clap.display.line_count()

    " Reach the preload capacity for the first time
    " Append the minimum raw_output, the rest goes to the cache.
    if len(chunks) + line_count >= g:clap.display.preload_capacity
      let start = g:clap.display.preload_capacity - line_count
      let to_append = chunks[:start-1]
      let to_cache = chunks[start :]

      " Discard?
      call s:handle_cache(to_cache)

      " Converter
      if s:has_converter
        let to_append = map(to_append, 's:Converter(v:val)')
      endif

      call extend(s:vim_output, to_append)
      call g:clap.display.append_lines(to_append)

      let s:preload_is_complete = v:true
      let s:loaded_size = line_count + len(to_append)
    else
      if s:loaded_size == 0
        let s:loaded_size = len(chunks)
      else
        let s:loaded_size = line_count + len(chunks)
      endif
      if s:has_converter
        let chunks = map(chunks, 's:Converter(v:val)')
      endif
      call extend(s:vim_output, chunks)
      call g:clap.display.append_lines(chunks)
    endif
  endfunction

  function! s:read_poll(timer) abort
    if s:job_id > 0 && clap#job#parse_vim8_job_id(s:poll_job) == s:job_id
      let channel_status = ch_status(s:poll_channel)
      if channel_status ==# 'closed'
        if exists('s:poll_timer')
          call timer_stop(s:poll_timer)
          unlet s:poll_timer
        endif
      endif
      " E906 can not read from a closed channel.
      if ch_canread(s:poll_channel)
        let chunks = split(ch_readraw(s:poll_channel), "\n")
        if s:preload_is_complete
          call s:handle_cache(chunks)
        else
          call s:apply_append_or_cache(chunks)
        endif
      endif
    endif
  endfunction

  function! s:close_cb(channel) abort
    if s:job_id > 0 && clap#job#parse_vim8_job_id(a:channel) == s:job_id
      call timer_stop(s:poll_timer)
      call s:post_check()
    endif
  endfunction

  function! s:job_start(cmd) abort
    let job = job_start(clap#job#wrap_cmd(a:cmd), {
          \ 'in_io': 'null',
          \ 'close_cb': function('s:close_cb'),
          \ 'exit_cb': function('s:exit_cb'),
          \ 'noblock': 1,
          \ 'mode': 'raw',
          \ })
    let s:poll_job = job
    let s:poll_channel = job_getchannel(job)
    let s:job_id = clap#job#parse_vim8_job_id(string(job))
    let s:poll_timer = timer_start(100, function('s:read_poll'), { 'repeat': -1 })
  endfunction

endif

function! s:abort_job(error_info) abort
  call s:jobstop()
  call g:clap.display.set_lines(a:error_info)
  call clap#spinner#set_idle()
endfunction

function! s:on_exit_common() abort
  if s:has_no_matches()
    call g:clap.display.set_lines([g:clap_no_matches_msg])
    call clap#indicator#set_matches('[0]')
    call clap#sign#disable_cursorline()
  else
    call clap#sign#reset_to_first_line()
  endif
  call clap#spinner#set_idle()
  if exists('g:__clap_maple_fuzzy_matched')
    let hl_lines = g:__clap_maple_fuzzy_matched[:g:clap.display.line_count()-1]
    " call clap#impl#add_highlight_for_fuzzy_indices(hl_lines)
  endif
endfunction

function! s:has_no_matches() abort
  if g:clap.display.is_empty()
    let g:__clap_has_no_matches = v:true
    return v:true
  else
    let g:__clap_has_no_matches = v:false
    return v:false
  endif
endfunction

function! s:apply_job_start(_timer) abort
  call clap#rooter#run(function('s:job_start'), s:cmd)

  let s:executed_time = strftime('%Y-%m-%d %H:%M:%S')
  let s:executed_cmd = s:cmd
endfunction

function! s:prepare_job_start(cmd) abort
  call s:jobstop()
  if exists('s:poll_timer')
    call timer_stop(s:poll_timer)
  endif

  let s:cache_size = 0
  let s:loaded_size = 0
  let g:clap.display.cache = []
  let s:preload_is_complete = v:false
  let s:dropped_size = 0

  let s:cmd = a:cmd

  let s:vim_output = []

  if has_key(g:clap.provider._(), 'converter')
    let s:has_converter = v:true
    let s:Converter = g:clap.provider._().converter
  else
    let s:has_converter = v:false
  endif

endfunction

function! s:job_strart_with_delay() abort
  if s:job_timer != -1
    call timer_stop(s:job_timer)
  endif

  let s:job_timer = timer_start(s:dispatcher_delay, function('s:apply_job_start'))
endfunction

" Start a job immediately given the command.
function! clap#dispatcher#job_start(cmd) abort
  call s:prepare_job_start(a:cmd)
  call s:apply_job_start('')
endfunction

" Start a job with a delay given the command.
function! clap#dispatcher#job_start_with_delay(cmd) abort
  call s:prepare_job_start(a:cmd)
  call s:job_strart_with_delay()
endfunction

function! clap#dispatcher#jobstop() abort
  call s:jobstop()
endfunction

let &cpoptions = s:save_cpo
unlet s:save_cpo
