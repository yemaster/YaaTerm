# Called from ZLE. recursive-edit accepts a task as text; only the outer editor
# can accept a command for the real login shell.
_yaaterm_draw_notes() {
    local note
    local -a notes=("$_yaaterm_ai_dir"/note-"$_yaaterm_mode"-*(N))
    (( $#notes )) || return 0
    zle -I
    for note in "${notes[@]}"; do
        builtin print -r -- "$(<"$note")" > "$TTY"
        zf_rm -f -- "$note"
    done
}

_yaaterm_resume_input() {
    # Let the outer line editor finish its normal initialization (including bracketed paste).
    [[ -n ${_yaaterm_editing-} ]] || zle -U $'\e[99;7~'
}
_yaaterm_compose() {
    emulate -L zsh
    [[ -z ${_yaaterm_editing-} ]] || return 0
    local _yaaterm_editing=1 _yaaterm_edit_op='' goal current=''
    [[ -r $_yaaterm_ai_dir/mode ]] && current=$(<"$_yaaterm_ai_dir/mode")
    if [[ -n $current && -z ${_yaaterm_mode-} ]]; then
        typeset -g _yaaterm_mode=$current _yaaterm_saved_buffer=$BUFFER _yaaterm_saved_cursor=$CURSOR
        autoload -Uz add-zle-hook-widget
        add-zle-hook-widget line-init _yaaterm_resume_input
    fi
    [[ -n ${_yaaterm_mode-} ]] || return 0
    local prefix=$PREDISPLAY
    BUFFER='' CURSOR=0
    PREDISPLAY="${prefix}Agent › "
    if [[ $current == $_yaaterm_mode ]]; then
        builtin printf '\033]777;yaaterm-editor;%s;%s;ready\007' "$_yaaterm_exit_token" "$_yaaterm_mode" > "$TTY"
    fi
    while [[ -r $_yaaterm_ai_dir/mode && $(<"$_yaaterm_ai_dir/mode") == $_yaaterm_mode ]]; do
        _yaaterm_draw_notes
        _yaaterm_edit_op=''
        zle -R
        # The task is prose, even when it contains shell syntax.
        () { local ZSH_HIGHLIGHT_MAXLENGTH=0; zle recursive-edit } || break
        case $_yaaterm_edit_op in
            run) PREDISPLAY=$prefix; zle -R; zle .accept-line; return 0 ;;
            leave) break ;;
        esac
        goal=${BUFFER//$'\n'/ }
        if (( ${#goal} > 4000 )) || [[ $goal == *[[:cntrl:]]* ]]; then
            zle -M '请输入 4000 字以内的任务'; continue
        fi
        [[ -n $goal ]] || continue
        if [[ -e $_yaaterm_ai_dir/task-$_yaaterm_mode ]]; then
            zle -M '正在提交任务'; continue
        fi
        builtin print -rn -- "$goal" >| "$_yaaterm_ai_dir/task-$_yaaterm_mode" || break
        zle -R
        zle -I
        BUFFER='' CURSOR=0
        builtin printf '\033]777;yaaterm-editor;%s;%s;task\007' "$_yaaterm_exit_token" "$_yaaterm_mode" > "$TTY"
    done
    PREDISPLAY=$prefix BUFFER=$_yaaterm_saved_buffer CURSOR=$_yaaterm_saved_cursor
    builtin printf '\033]777;yaaterm-editor;%s;%s;closed\007' "$_yaaterm_exit_token" "$_yaaterm_mode" > "$TTY"
    unset _yaaterm_mode _yaaterm_saved_buffer _yaaterm_saved_cursor
    add-zle-hook-widget -d line-init _yaaterm_resume_input
    zle -R
}
