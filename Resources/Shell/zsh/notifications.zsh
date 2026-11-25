# Record foreground external commands. Only the shell reports after it regains the prompt.
# Emit directory changes and listing boundaries only. No command output is captured.
_yaaterm_context() {
    local dir=${2:-$PWD}
    [[ $dir != *[[:cntrl:]]* ]] || dir=''
    builtin printf '\033]777;yaaterm-context;%s;%s;%s\007' "$_yaaterm_exit_token" "$1" "$dir" > "$TTY"
}
_yaaterm_prompt_context() {
    if [[ -n $_yaaterm_listing || ${_yaaterm_last_dir-} != "$PWD" ]]; then
        _yaaterm_context cwd
        _yaaterm_last_dir=$PWD _yaaterm_listing=''
    fi
    return 0
}
_yaaterm_command_start() {
    emulate -L zsh
    setopt extendedglob
    _yaaterm_job=''
    # Mark the output boundary before filtering builtins and unknown command names.
    if [[ -d $_yaaterm_ai_dir ]]; then
        _yaaterm_ai_line=${1[1,384]}
        _yaaterm_ai_line=${_yaaterm_ai_line//[[:cntrl:]]/␣}
        (( ${#1} > 384 )) && _yaaterm_ai_line+=…
        builtin printf '\033]777;yaaterm-begin;%s;%s\007' "$_yaaterm_exit_token" "$_yaaterm_next_id" > "$TTY"
    fi
    if [[ -n $_yaaterm_next_id ]]; then
        _yaaterm_next_id=''
        return 0  # The owning assistant reports completion for this command.
    fi
    local line=${2##[[:space:]]#}
    [[ -n $line && $line != *('&'|'&!'|'&|') ]] || return 0
    local -a words=(${(z)line})
    local command_only=0 name
    while (( $#words )); do
        name=${(Q)words[1]}
        shift words
        case $name in
            command) command_only=1 ;;
            noglob|time|[a-zA-Z_][a-zA-Z0-9_]#=*) ;;
            *) break ;;
        esac
    done
    if [[ $name == fg || $name == %* ]]; then
        local ref=${words[1]:-%+}
        [[ $name == %* ]] && ref=$name
        words=(${(z)jobtexts[$ref]})
        name=${(Q)words[1]}
    fi
    local agent=0
    case ${name:t} in codex|claude|agy|qodercn|qoder-cn|qoderclicn|qodercli|omp) agent=1 ;; esac
    if [[ $name == */* ]]; then
        [[ -f $name && -x $name ]] || return 0
    else
        (( agent || command_only || (! $+builtins[$name] && ! $+functions[$name]) )) || return 0
        (( $+commands[$name] )) || return 0
    fi
    name=${name:t}
    [[ -n $name && ${#name} -le 64 && $name != *[^a-zA-Z0-9_.+-]* ]] || return 0
    _yaaterm_job=$name _yaaterm_started=$SECONDS
    if (( agent )); then
        builtin printf '\033]777;yaaterm-agent;%s;%s\007' "$_yaaterm_exit_token" "$name" > "$TTY"
        return 0
    fi
    case $name in
        ls|docker|kubectl|df|ps|git|launchctl|pip|pip3|pip3.<->|python|python3|python3.<->) ;;
        *) return 0 ;;
    esac
    # Only simple invocations with the standard output columns qualify.
    local arg operand= list_dir=$PWD long=0 valid=1
    if [[ $name == ls ]]; then
        for arg in "${words[@]}"; do
            if [[ $arg == (--|--color|--color=auto|--color=always) ]]; then
                continue
            elif [[ $arg == -[alhAGrtS]## ]]; then
                [[ $arg == *l* ]] && long=1
            elif [[ -z $operand && ${(Q)arg} == [[:alnum:]~./_][[:alnum:][:space:]~./_-]# ]]; then
                operand=${(Q)arg}
            else
                valid=0; break
            fi
        done
        if (( valid && long )); then
            if [[ -n $operand ]]; then
                case $operand in
                    /*) list_dir=$operand ;;
                    '~') list_dir=$HOME ;;
                    '~/'*) list_dir=$HOME/${operand#*/} ;;
                    *) list_dir=$PWD/$operand ;;
                esac
                [[ -d $list_dir ]] || valid=0
            fi
            (( valid )) && _yaaterm_listing=ls
        fi
    elif [[ $name == docker ]]; then
        case ${words[1]} in
            ps) _yaaterm_listing=docker; shift words ;;
            images) _yaaterm_listing=images; shift words ;;
            container|image|network|volume)
                if [[ ${words[2]} == ls ]]; then
                    case ${words[1]} in
                        container) _yaaterm_listing=docker ;;
                        image) _yaaterm_listing=images ;;
                        network) _yaaterm_listing=networks ;;
                        volume) _yaaterm_listing=volumes ;;
                    esac
                    shift 2 words
                fi ;;
        esac
        for arg in "${words[@]}"; do
            [[ $arg == (-a|--all|--no-trunc) ]] || { _yaaterm_listing=''; break; }
        done
    elif [[ $name == kubectl && $#words -ge 2 && ${words[1]} == get ]]; then
        case ${words[2]} in
            pod|pods|po) _yaaterm_listing=pods ;;
            service|services|svc) _yaaterm_listing=services ;;
            deployment|deployments|deploy) _yaaterm_listing=deployments ;;
            namespace|namespaces|ns) _yaaterm_listing=namespaces ;;
        esac
        shift 2 words
        while (( $#words )); do
            arg=$words[1]; shift words
            case $arg in
                -A|--all-namespaces) ;;
                -n|--namespace)
                    [[ ${words[1]} == [[:alnum:]][[:alnum:].-]# ]] || { _yaaterm_listing=''; break; }
                    shift words ;;
                [[:alnum:]][[:alnum:].-]#|--namespace=[[:alnum:]][[:alnum:].-]#) ;;
                *) _yaaterm_listing=''; break ;;
            esac
        done
    elif [[ $name == df ]]; then
        _yaaterm_listing=df
        for arg in "${words[@]}"; do
            [[ $arg == -[hHkmgP]## || ${(Q)arg} == [./~[:alnum:]][[:alnum:][:space:]._~/-]# ]] || { _yaaterm_listing=''; break; }
        done
    elif [[ $name == ps ]]; then
        case ${(j: :)words} in
            ''|-A|-e|ax|-ax) _yaaterm_listing=ps ;;
            aux|-aux|auxw|auxww) _yaaterm_listing=ps-user ;;
            -ef|-Af) _yaaterm_listing=ps-full ;;
        esac
    elif [[ $name == git ]]; then
        case ${(j: :)words} in
            'remote -v'|'remote --verbose') _yaaterm_listing=remotes ;;
            'worktree list') _yaaterm_listing=worktrees ;;
        esac
    elif [[ $name == launchctl && $#words == 1 && ${words[1]} == list ]]; then
        _yaaterm_listing=jobs
    elif [[ $name == (pip|pip3|pip3.<->) && ${(j: :)words} == list ]] ||
         [[ $name == (python|python3|python3.<->) && ${(j: :)words} == '-m pip list' ]]; then
        _yaaterm_listing=packages
    fi
    [[ -n $_yaaterm_listing ]] && _yaaterm_context "$_yaaterm_listing" "$list_dir"
    return 0
}
_yaaterm_command_end() {
    local code=$?
    emulate -L zsh
    [[ -d $_yaaterm_ai_dir ]] && builtin printf '\033]777;yaaterm-end;%s;%d;%s\007' "$_yaaterm_exit_token" "$code" "$_yaaterm_ai_line" > "$TTY"
    _yaaterm_ai_line='' _yaaterm_next_id=''
    _yaaterm_prompt_context
    local name=$_yaaterm_job
    _yaaterm_job=''
    [[ -n $name ]] || return 0
    # Ctrl-Z also returns to the prompt, with 128 + the stop signal, while the job is alive.
    if (( code > 128 )) && [[ ${jobstates[%+]-} == suspended:* ]]; then
        case ${signals[code-127]-} in TSTP|STOP|TTIN|TTOU)
            builtin printf '\033]777;yaaterm-agent;%s;\007' "$_yaaterm_exit_token" > "$TTY"
            return 0 ;;
        esac
    fi
    builtin printf '\033]777;yaaterm-exit;%s;%s;%d;%d\007' "$_yaaterm_exit_token" "$name" "$code" "$((SECONDS-_yaaterm_started))" > "$TTY"
    return 0
}
builtin source "${${(%):-%x}:A:h}/agents.zsh"
typeset -ga preexec_functions precmd_functions
preexec_functions+=(_yaaterm_command_start)
precmd_functions=(_yaaterm_command_end "${precmd_functions[@]}")

_yaaterm_prompt_context
[[ -d $_yaaterm_ai_dir ]] && builtin printf '\033]777;yaaterm-end;%s;0;\007' "$_yaaterm_exit_token" > "$TTY"

# The private key carries no text. A pending line can only be claimed by ZLE at an empty primary prompt.
_yaaterm_input_widget() {
    emulate -L zsh
    local id op line ok=0
    if [[ -n ${_yaaterm_editing-} ]]; then
        if [[ ! -r $_yaaterm_ai_dir/mode || $(<"$_yaaterm_ai_dir/mode") != $_yaaterm_mode ]]; then
            _yaaterm_edit_op=leave; zle .accept-line; return 0
        fi
        _yaaterm_draw_notes
    elif [[ ( -r $_yaaterm_ai_dir/mode || -n ${_yaaterm_mode-} ) && $CONTEXT == start && ! -f $_yaaterm_ai_dir/line ]]; then
        if (( ! $+functions[_yaaterm_compose] )); then
            builtin source "$_yaaterm_agents_dir/../zsh/agent-input.zsh"
        fi
        zmodload -F zsh/files b:zf_rm || return 0
        _yaaterm_compose
        return 0
    fi
    [[ -f $_yaaterm_ai_dir/line ]] || return 0
    { IFS= builtin read -r id && IFS= builtin read -r op && IFS= builtin read -r line } < "$_yaaterm_ai_dir/line" || return 0
    zmodload -F zsh/files b:zf_rm && zf_rm -- "$_yaaterm_ai_dir/line" 2>/dev/null || return 0
    local agent_run=0
    [[ -n ${_yaaterm_editing-} && $op == run ]] && agent_run=1
    if [[ ( -z $BUFFER || $agent_run == 1 ) && ( $CONTEXT == start || -n ${_yaaterm_editing-} ) && -n $line && $line != *[[:cntrl:]]* && $op == (run|fill) ]]; then
        ok=1
        if (( agent_run )) && [[ -n $BUFFER ]]; then
            typeset -g _yaaterm_agent_draft=$BUFFER _yaaterm_agent_caret=$CURSOR
            BUFFER='' CURSOR=0
            zle -R
        fi
        if [[ $line == 'command yaa-agent '* ]]; then
            builtin hash "yaa-agent=$_yaaterm_agents_dir/yaa-agent"
        elif [[ $line == 'command yaa-inspect '* ]]; then
            builtin hash "yaa-inspect=$_yaaterm_inspector"
        fi
        BUFFER=$line CURSOR=${#line}
    fi
    builtin printf '\033]777;yaaterm-input;%s;%s;%d\007' "$_yaaterm_exit_token" "$id" "$ok" > "$TTY"
    if (( ok )) && [[ $op == run ]]; then
        [[ -n ${_yaaterm_editing-} ]] && _yaaterm_edit_op=run
        _yaaterm_next_id=$id
        zle -R
        zle .accept-line
    fi
    return 0
}
typeset -g _yaaterm_inspector=${${(%):-%x}:A:h:h:h:h}/Helpers/yaa-inspect
zle -N _yaaterm_input_widget
for _yaaterm_map in emacs viins vicmd; do
    bindkey -M "$_yaaterm_map" $'\e[99;7~' _yaaterm_input_widget
done
unset _yaaterm_map
