# Sourced on demand by the primary ZLE widget. The explanation is literal terminal output.
# Invalidate ZLE with an empty draft so a partially typed command is never duplicated.
local line=$1 reason=$2
local draft=$BUFFER caret=$CURSOR mark=$MARK selection=$REGION_ACTIVE before=$PREDISPLAY after=$POSTDISPLAY
BUFFER='' CURSOR=0 PREDISPLAY='' POSTDISPLAY=''
() {
    local PROMPT='' RPROMPT='' POSTEDIT=''
    zle reset-prompt
    zle -I
}
BUFFER=$draft CURSOR=$caret MARK=$mark REGION_ACTIVE=$selection PREDISPLAY=$before POSTDISPLAY=$after
# ZLE left a blank editor row above us. Put the separation below the reason.
if (( LINES >= 3 )) && [[ ! -o singlelinezle && $TERM != dumb ]]; then
    builtin printf '\033[1A\r' > "$TTY"
fi
builtin printf '\033[1;34m错误解释\033[0m  %s\n\n' "${reason%$'\n'}" > "$TTY"
if [[ -n $line && $line != *[[:cntrl:]]* ]]; then
    if [[ -z $BUFFER ]]; then
        BUFFER=$line CURSOR=${#line}
        builtin printf '\033[2m可编辑 · 回车执行\033[0m\n' > "$TTY"
    else
        builtin printf '\033[36m建议命令\033[0m  %s\n' "$line" > "$TTY"
    fi
fi
# reset-prompt reclaims the blank editor row; keep the last line of the explanation above it.
builtin printf '\n' > "$TTY"
zle reset-prompt
