#!/bin/bash
input=$(cat)

# Tokyo Night palette
RESET="\033[0m"
TN_COMMENT="\033[38;5;60m"
TN_BLUE="\033[38;5;111m"
TN_PURPLE="\033[38;5;141m"
TN_GREEN="\033[38;5;115m"
TN_ORANGE="\033[38;5;215m"
TN_RED="\033[38;5;203m"
TN_YELLOW="\033[38;5;222m"
TN_TEAL="\033[38;5;73m"

# Single jq call to extract all input values
IFS=$'\t' read -r MODEL_DISPLAY PROJECT_DIR CURRENT_DIR CONTEXT_SIZE USED_PCT < <(
    jq -r '[
        (.model.display_name // "Claude"),
        (.workspace.project_dir // "/"),
        (.workspace.current_dir // "/"),
        (.context_window.context_window_size // 200000 | tostring),
        (.context_window.used_percentage // "" | tostring)
    ] | @tsv' <<< "$input"
)
: "${MODEL_DISPLAY:=Claude}" "${PROJECT_DIR:=/}" "${CURRENT_DIR:=/}" "${CONTEXT_SIZE:=200000}"

if [ -n "$USED_PCT" ] && [ "$USED_PCT" != "null" ]; then
    USED_PCT_INT=$(printf "%.0f" "$USED_PCT" 2>/dev/null || echo "0")
    echo "$USED_PCT" > /tmp/claude_statusline_pct_cache
elif [ -f /tmp/claude_statusline_pct_cache ]; then
    USED_PCT=$(cat /tmp/claude_statusline_pct_cache 2>/dev/null || echo "")
    [ -n "$USED_PCT" ] && USED_PCT_INT=$(printf "%.0f" "$USED_PCT" 2>/dev/null || echo "0")
fi

format_tokens() {
    local t=$1
    if [ "$t" -ge 1000000 ] 2>/dev/null; then
        printf "%d.%dM" $((t / 1000000)) $(( (t / 100000) % 10 ))
    elif [ "$t" -ge 1000 ] 2>/dev/null; then
        printf "%dk" $((t / 1000))
    else
        echo "${t:-0}"
    fi
}

color_for_pct() {
    local pct=$1
    if [ "$pct" -ge 80 ] 2>/dev/null; then
        echo "$TN_RED"
    elif [ "$pct" -ge 50 ] 2>/dev/null; then
        echo "$TN_YELLOW"
    else
        echo "$TN_GREEN"
    fi
}

progress_bar() {
    local pct=$1 width=${2:-30}
    local filled=$(( width * pct / 100 ))
    [ "$filled" -gt "$width" ] && filled=$width
    local green_end=$((width / 2))
    local yellow_end=$((width * 3 / 4))

    local bar="" i
    for ((i=0; i<width; i++)); do
        if [ "$i" -lt "$green_end" ]; then
            bar+="${TN_GREEN}"
        elif [ "$i" -lt "$yellow_end" ]; then
            bar+="${TN_YELLOW}"
        else
            bar+="${TN_RED}"
        fi
        [ "$i" -lt "$filled" ] && bar+="█" || bar+="░"
    done
    echo "${bar}${RESET}"
}

mini_bar() {
    local pct=$1 width=${2:-8}
    local filled=$(( (pct * width + 50) / 100 ))
    [ "$filled" -gt "$width" ] && filled=$width
    local color=$(color_for_pct "$pct")
    local bar="${color}"
    for ((i=0; i<width; i++)); do
        [ "$i" -lt "$filled" ] && bar+="▄" || bar+="▁"
    done
    echo "${bar}${RESET}"
}

# ISO 8601 timestamp → local time (bash builtins instead of sed)
parse_reset_time() {
    local raw="$1" fmt="$2"
    [ -z "$raw" ] || [ "$raw" = "null" ] && return 1
    if [[ "$OSTYPE" == "darwin"* ]]; then
        local base="${raw:0:19}" tz="${raw: -6}"
        date -j -f "%Y-%m-%dT%H:%M:%S%z" "${base}${tz/:/}" "+$fmt" 2>/dev/null
    else
        date -d "$raw" "+$fmt" 2>/dev/null
    fi
}

file_mtime() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        stat -f%m "$1" 2>/dev/null || echo 0
    else
        stat -c%Y "$1" 2>/dev/null || echo 0
    fi
}

get_git_info() {
    local branch
    branch=$(git -C "${CURRENT_DIR}" symbolic-ref --short HEAD 2>/dev/null) ||
        branch=$(git -C "${CURRENT_DIR}" rev-parse --short HEAD 2>/dev/null) ||
        return
    local changes
    changes=$(git -C "${CURRENT_DIR}" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    [ "$changes" -gt 0 ] 2>/dev/null && echo "${branch} *${changes}" || echo "${branch}"
}

# --- Usage limits via OAuth API ---
USAGE_CACHE="/tmp/claude_usage_limits.json"
USAGE_LOCK="/tmp/claude_usage_fetch.lock"
USAGE_LAST_ATTEMPT="/tmp/claude_usage_last_attempt"
USAGE_CACHE_TTL=300

fetch_usage() {
    if [ -f "$USAGE_LOCK" ]; then
        local lock_age=$(( $(date +%s) - $(file_mtime "$USAGE_LOCK") ))
        [ "$lock_age" -lt 30 ] && return 0
    fi
    echo $$ > "$USAGE_LOCK"
    trap 'rm -f "$USAGE_LOCK"' EXIT

    local creds token response
    if [[ "$OSTYPE" == "darwin"* ]]; then
        creds=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null) || return 1
    else
        [ -f ~/.claude/.credentials.json ] || return 1
        creds=$(<~/.claude/.credentials.json)
    fi
    token=$(echo "$creds" | jq -r '.claudeAiOauth.accessToken' 2>/dev/null) || return 1
    [ -z "$token" ] || [ "$token" = "null" ] && return 1

    response=$(curl -s --max-time 5 "https://api.anthropic.com/api/oauth/usage" \
        -H "Authorization: Bearer $token" \
        -H "anthropic-beta: oauth-2025-04-20" \
        -H "Content-Type: application/json" 2>/dev/null) || return 1

    touch "$USAGE_LAST_ATTEMPT"

    if echo "$response" | jq -e '.five_hour' >/dev/null 2>&1; then
        echo "$response" > "$USAGE_CACHE"
    fi
}

get_usage_limits() {
    local now=$(date +%s)
    local last_attempt_age=9999
    if [ -f "$USAGE_LAST_ATTEMPT" ]; then
        last_attempt_age=$(( now - $(file_mtime "$USAGE_LAST_ATTEMPT") ))
    fi

    [ "$last_attempt_age" -gt "$USAGE_CACHE_TTL" ] && fetch_usage 2>/dev/null &

    [ -f "$USAGE_CACHE" ] || return

    # Single jq call to extract all usage data
    local r5_raw r7_raw
    IFS=$'\t' read -r USAGE_5H USAGE_7D r5_raw r7_raw < <(
        jq -r '[
            (.five_hour.utilization // "" | tostring | split(".")[0]),
            (.seven_day.utilization // "" | tostring | split(".")[0]),
            (.five_hour.resets_at // ""),
            (.seven_day.resets_at // "")
        ] | @tsv' "$USAGE_CACHE" 2>/dev/null
    )

    RESET_5H_FMT=$(parse_reset_time "$r5_raw" "%H:%M")
    [ -z "$RESET_5H_FMT" ] && RESET_5H_FMT="--:--"

    RESET_7D_FMT=$(parse_reset_time "$r7_raw" "%a %H:%M")
    if [ -n "$RESET_7D_FMT" ]; then
        # Truncate day to 3 chars for locale safety (e.g., "lun." → "lun")
        RESET_7D_FMT="$(printf "%.3s" "${RESET_7D_FMT%% *}") ${RESET_7D_FMT##* }"
    else
        RESET_7D_FMT="--- --:--"
    fi
}

# --- Assemble output ---
PROJECT_NAME="${PROJECT_DIR##*/}"
[ -z "$PROJECT_NAME" ] || [ "$PROJECT_NAME" = "/" ] && PROJECT_NAME="${CURRENT_DIR##*/}"
GIT_INFO=$(get_git_info)

# Single date call for all time values
read -r _dow _day _hour _min <<< "$(date "+%a %d %H %M")"

# Line 1: Model | Project | Git | Date/Time
LINE1="${TN_ORANGE}${MODEL_DISPLAY}${RESET}"
LINE1+=" ${TN_COMMENT}|${RESET} ${TN_BLUE}${PROJECT_NAME}${RESET}"
[ -n "$GIT_INFO" ] && LINE1+=" ${TN_PURPLE}${GIT_INFO}${RESET}"
LINE1+=" ${TN_COMMENT}|${RESET} ${TN_COMMENT}${_dow} ${_day}${RESET} ${TN_TEAL}${_hour}${TN_COMMENT}:${TN_TEAL}${_min}${RESET}"

TARGET_W=$((${#MODEL_DISPLAY} + 3 + ${#PROJECT_NAME} + 3 + 12))
[ -n "$GIT_INFO" ] && TARGET_W=$((TARGET_W + 1 + ${#GIT_INFO}))

# Line 2: Context window bar
LINE2=""
if [ -n "$USED_PCT_INT" ]; then
    USED_FMT=$(format_tokens "$(( CONTEXT_SIZE * USED_PCT_INT / 100 ))")
    TOTAL_FMT=$(format_tokens "$CONTEXT_SIZE")

    if [ "$USED_PCT_INT" -le 50 ] 2>/dev/null; then PCT_COLOR="$TN_GREEN"
    elif [ "$USED_PCT_INT" -le 75 ] 2>/dev/null; then PCT_COLOR="$TN_YELLOW"
    else PCT_COLOR="$TN_RED"; fi

    BAR_W=$((TARGET_W - 1 - 4 - 1 - ${#USED_FMT} - 1 - ${#TOTAL_FMT}))
    [ "$BAR_W" -lt 10 ] && BAR_W=10
    PCT_DISPLAY=$(printf "%3d%%" "$USED_PCT_INT")
    LINE2="$(progress_bar "$USED_PCT_INT" "$BAR_W") ${PCT_COLOR}${PCT_DISPLAY}${RESET} ${TN_COMMENT}${USED_FMT}/${TOTAL_FMT}${RESET}"
fi

# Line 3: Usage limits with reset times
# Fixed visible chars (excl. sep & bars): (3+1+4+1+5) + (3+1+4+1+9) = 32
get_usage_limits
LINE3=""
REMAINDER=$((TARGET_W - 32))
if [ $((REMAINDER % 2)) -eq 0 ]; then
    SEP_TEXT="  | "
    MINI_W=$(( (REMAINDER - 4) / 2 ))
else
    SEP_TEXT=" | "
    MINI_W=$(( (REMAINDER - 3) / 2 ))
fi
[ "$MINI_W" -lt 3 ] && MINI_W=3
if [ -n "$USAGE_5H" ]; then
    U5_COLOR=$(color_for_pct "$USAGE_5H")
    U5_PCT=$(printf "%3d%%" "$USAGE_5H")
    LINE3+="${U5_COLOR}5h $(mini_bar "$USAGE_5H" "$MINI_W") ${U5_COLOR}${U5_PCT}${RESET} ${TN_COMMENT}${RESET_5H_FMT}${RESET}"
fi
if [ -n "$USAGE_7D" ]; then
    U7_COLOR=$(color_for_pct "$USAGE_7D")
    U7_PCT=$(printf "%3d%%" "$USAGE_7D")
    [ -n "$LINE3" ] && LINE3+="${TN_COMMENT}${SEP_TEXT}${RESET}"
    LINE3+="${U7_COLOR}wk $(mini_bar "$USAGE_7D" "$MINI_W") ${U7_COLOR}${U7_PCT}${RESET} ${TN_COMMENT}${RESET_7D_FMT}${RESET}"
fi

echo -e "$LINE1"
[ -n "$LINE2" ] && echo -e "$LINE2"
[ -n "$LINE3" ] && echo -e "$LINE3"
exit 0
