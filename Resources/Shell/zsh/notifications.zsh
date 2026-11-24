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
    if [[ $name == */* ]]; then
        [[ -f $name && -x $name ]] || return 0
    else
        (( command_only || (! $+builtins[$name] && ! $+functions[$name]) )) || return 0
        (( $+commands[$name] )) || return 0
    fi
    name=${name:t}
    [[ -n $name && ${#name} -le 64 && $name != *[^a-zA-Z0-9_.+-]* ]] || return 0
    _yaaterm_job=$name _yaaterm_started=$SECONDS
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
    _yaaterm_prompt_context
    local name=$_yaaterm_job
    _yaaterm_job=''
    [[ -n $name ]] || return 0
    # Ctrl-Z also returns to the prompt, with 128 + the stop signal, while the job is alive.
    if (( code > 128 )) && [[ ${jobstates[%+]-} == suspended:* ]]; then
        case ${signals[code-127]-} in TSTP|STOP|TTIN|TTOU) return 0 ;; esac
    fi
    builtin printf '\033]777;yaaterm-exit;%s;%s;%d;%d\007' "$_yaaterm_exit_token" "$name" "$code" "$((SECONDS-_yaaterm_started))" > "$TTY"
    return 0
}
typeset -ga preexec_functions precmd_functions
preexec_functions+=(_yaaterm_command_start)
precmd_functions=(_yaaterm_command_end "${precmd_functions[@]}")

_yaaterm_prompt_context
