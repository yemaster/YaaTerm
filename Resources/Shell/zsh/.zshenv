# YaaTerm sets ZDOTDIR only long enough to install this one-shot prompt hook.
# Keep exit records on this PTY separate from notifications printed by its children.
typeset -g _yaaterm_exit_token=${YAATERM_EXIT_TOKEN-}
unset YAATERM_EXIT_TOKEN
typeset -g _yaaterm_zsh_dir=${${(%):-%x}:A:h}
if (( ${+YAATERM_ORIGINAL_ZDOTDIR} )); then
    export ZDOTDIR=$YAATERM_ORIGINAL_ZDOTDIR
    unset YAATERM_ORIGINAL_ZDOTDIR
else
    unset ZDOTDIR
fi

typeset -g _yaaterm_user_env=${ZDOTDIR-$HOME}/.zshenv
if [[ -f $_yaaterm_user_env && -r $_yaaterm_user_env && ${_yaaterm_user_env:A:h} != $_yaaterm_zsh_dir ]]; then
    builtin source "$_yaaterm_user_env"
fi
unset _yaaterm_user_env

if [[ -o interactive && -o rcs ]]; then
    _yaaterm_load_highlighter() {
        emulate -L zsh
        precmd_functions=("${(@)precmd_functions:#_yaaterm_load_highlighter}")
        local script=$_yaaterm_zsh_dir/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
        [[ -n $_yaaterm_exit_token ]] && builtin source "$_yaaterm_zsh_dir/notifications.zsh"
        unset _yaaterm_zsh_dir
        unfunction _yaaterm_load_highlighter

        # Let the user's .zshrc, theme and plugins initialize first.
        [[ -o zle && -r $script ]] || return 0
        (( $+functions[_zsh_highlight] || $+functions[-fast-highlight-process] )) && return 0
        typeset -g ZSH_HIGHLIGHT_MAXLENGTH=${ZSH_HIGHLIGHT_MAXLENGTH-512}
        typeset -gA ZSH_HIGHLIGHT_STYLES
        : ${ZSH_HIGHLIGHT_STYLES[unknown-token]=fg=red}
        : ${ZSH_HIGHLIGHT_STYLES[single-hyphen-option]=fg=blue}
        : ${ZSH_HIGHLIGHT_STYLES[double-hyphen-option]=fg=blue}
        : ${ZSH_HIGHLIGHT_STYLES[commandseparator]=fg=cyan}
        builtin source "$script"
        return 0
    }
    precmd_functions+=(_yaaterm_load_highlighter)
else
    unset _yaaterm_zsh_dir
fi
