# Scope integrations to this interactive shell. Keep user-defined commands and aliases.
typeset -g _yaaterm_agents_dir=${${(%):-%x}:A:h:h}/agents
_yaaterm_run_agent() {
    local tool=$1; shift
    if [[ ! -t 0 || ! -t 1 ]]; then
        command "$tool" "$@"; return $?
    fi
    case $tool in
        codex)
            command "$tool" -c 'tui.notifications=["agent-turn-complete"]' -c 'tui.notification_method="osc9"' \
                -c 'tui.notification_condition="always"' "$@" ;;
        qodercn|qoder-cn)
            # The dispatcher also opens files and forwards IDE subcommands.
            if [[ -n $1 && ( -e $1 || $1 == (ide|chat|serve-web|tunnel) ) ]]; then
                command "$tool" "$@"; return $?
            fi
            ;&
        claude|qoderclicn|qodercli)
            YAATERM_NOTICE_TTY=$TTY YAATERM_NOTICE_AGENT=$tool command "$tool" --plugin-dir "$_yaaterm_agents_dir/turn-notice" "$@" ;;
        omp)
            local arg
            for arg in "$@"; do
                case $arg in
                    --trusted-extension|--trusted-extension=*|--no-extensions|--no-tools|-p|--print|--mode|--mode=*)
                        command "$tool" "$@"; return $? ;;
                esac
            done
            command "$tool" --extension "$_yaaterm_agents_dir/omp-turn.ts" "$@" ;;
    esac
}
for _yaaterm_tool in codex claude qodercn qoder-cn qoderclicn qodercli omp; do
    if (( $+commands[$_yaaterm_tool] && ! $+functions[$_yaaterm_tool] )); then
        functions[$_yaaterm_tool]="_yaaterm_run_agent $_yaaterm_tool \"\$@\""
    fi
done
unset _yaaterm_tool
