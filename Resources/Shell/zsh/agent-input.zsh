# Called from ZLE. recursive-edit accepts a task as text; only the outer editor
# can accept a command for the real login shell.
_yaaterm_draw_notes() {
    local note done_file="$_yaaterm_ai_dir/done-$_yaaterm_mode"
    local -a notes=("$_yaaterm_ai_dir"/note-"$_yaaterm_mode"-*(N))
    (( $#notes )) || [[ -e $done_file ]] || return 0
    BUFFER='' POSTDISPLAY='' CURSOR=0
    if [[ -e $done_file ]]; then
        zf_rm -f -- "$done_file"
        unset _yaaterm_task_active _yaaterm_review_id _yaaterm_review_line
    fi
    _yaaterm_agent_prompt
    zle reset-prompt
    if (( $#notes )); then
        zle -R
        zle -I
        if (( COLUMNS > 8 && LINES > 1 )); then
            builtin printf '\033[1A\r\033[K' > "$TTY"
        fi
        for note in "${notes[@]}"; do
            builtin print -r -- "$(<"$note")" > "$TTY"
            zf_rm -f -- "$note"
        done
    fi
}

_yaaterm_resume_input() {
    # Let the outer line editor finish its normal initialization (including bracketed paste).
    [[ -n ${_yaaterm_editing-} ]] || zle -U $'\e[99;7~'
}

# Let the theme update its real prompt between commands, then select the editor prompt
# before ZLE paints. Keep the prompt used for the accepted command until ZLE finishes.
_yaaterm_restore_prompt() {
    if (( ${+_yaaterm_shell_prompt} )); then
        PROMPT=$_yaaterm_shell_prompt RPROMPT=$_yaaterm_shell_right
        unset _yaaterm_shell_prompt _yaaterm_shell_right
    fi
}
_yaaterm_agent_prompt() {
    [[ -r $_yaaterm_ai_dir/mode ]] || return 0
    if (( ! ${+_yaaterm_shell_prompt} )); then
        typeset -g _yaaterm_shell_prompt=$PROMPT _yaaterm_shell_right=$RPROMPT
    fi
    RPROMPT=''
    if [[ -n ${_yaaterm_task_active-} ]]; then
        PROMPT=''
    else
        # Leave room for typing, keeping the tail of a long path in a split.
        PROMPT='%-15(l.%-16<…<%~%<< .)Agent > '
    fi
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
        preexec_functions=(_yaaterm_restore_prompt "${preexec_functions[@]}")
        precmd_functions=(_yaaterm_restore_prompt "${precmd_functions[@]}" _yaaterm_agent_prompt)
    fi
    [[ -n ${_yaaterm_mode-} ]] || return 0
    local prefix=$PREDISPLAY suffix=$POSTDISPLAY _yaaterm_review_id _yaaterm_review_line suffix=$POSTDISPLAY
    _yaaterm_agent_prompt
    BUFFER='' CURSOR=0 PREDISPLAY='' POSTDISPLAY='' POSTDISPLAY=''
    zle reset-prompt
    if [[ $current == $_yaaterm_mode ]]; then
        builtin printf '\033]777;yaaterm-editor;%s;%s;ready\007' "$_yaaterm_exit_token" "$_yaaterm_mode" > "$TTY"
    fi
    while [[ -r $_yaaterm_ai_dir/mode && $(<"$_yaaterm_ai_dir/mode") == $_yaaterm_mode ]]; do
        _yaaterm_draw_notes
        _yaaterm_edit_op=''
        zle -R
        # The task is prose, even when it contains shell syntax.
        if ! () { local ZSH_HIGHLIGHT_MAXLENGTH=0; zle recursive-edit }; then
            [[ -n ${_yaaterm_task_active-} ]] || break
            builtin printf '\033]777;yaaterm-editor;%s;%s;cancel\007' "$_yaaterm_exit_token" "$_yaaterm_mode" > "$TTY"
            continue
        fi
        case $_yaaterm_edit_op in
            run)
                PROMPT='$ ' POSTDISPLAY=''
                zle reset-prompt
                zle .accept-line
                return 0 ;;
            leave) break ;;
        esac
        # Only a matching approval packet may hand a proposed line to the outer shell.
        if [[ -n ${_yaaterm_task_active-} ]]; then
            BUFFER=${_yaaterm_review_line-} CURSOR=${#_yaaterm_review_line}
            continue
        fi
        goal=${BUFFER//$'\n'/ }
        if (( ${#goal} > 4000 )) || [[ $goal == *[[:cntrl:]]* ]]; then
            zle -M '请输入 4000 字以内的任务'; continue
        fi
        [[ -n ${goal//[[:space:]]/} ]] || { BUFFER='' CURSOR=0; continue; }
        if [[ -e $_yaaterm_ai_dir/task-$_yaaterm_mode ]]; then
            zle -M '正在提交任务'; continue
        fi
        builtin print -rn -- "$goal" >| "$_yaaterm_ai_dir/task-$_yaaterm_mode" || break
        # Commit the submitted line, with an empty cached prompt for the next redraw.
        PREDISPLAY=${(%)PROMPT} PROMPT=''
        zle reset-prompt
        zle -R
        zle -I
        typeset -g _yaaterm_task_active=1
        BUFFER='' CURSOR=0 PREDISPLAY=''
        builtin printf '\033]777;yaaterm-editor;%s;%s;task\007' "$_yaaterm_exit_token" "$_yaaterm_mode" > "$TTY"
    done
    PREDISPLAY=$prefix POSTDISPLAY=$suffix BUFFER=$_yaaterm_saved_buffer CURSOR=$_yaaterm_saved_cursor
    _yaaterm_restore_prompt
    zle reset-prompt
    builtin printf '\033]777;yaaterm-editor;%s;%s;closed\007' "$_yaaterm_exit_token" "$_yaaterm_mode" > "$TTY"
    unset _yaaterm_task_active _yaaterm_mode _yaaterm_saved_buffer _yaaterm_saved_cursor
    add-zle-hook-widget -d line-init _yaaterm_resume_input
    preexec_functions=(${preexec_functions:#_yaaterm_restore_prompt})
    precmd_functions=(${${precmd_functions:#_yaaterm_restore_prompt}:#_yaaterm_agent_prompt})
    zle -R
}
