#!/bin/bash
# Status line — Tokyo Night theme with gradient progress bar + usage limits
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

# Extract values
MODEL_DISPLAY=$(echo "$input" | jq -r '.model.display_name // "Claude"')
PROJECT_DIR=$(echo "$input" | jq -r '.workspace.project_dir // "/"')
CURRENT_DIR=$(echo "$input" | jq -r '.workspace.current_dir // "/"')
CONTEXT_SIZE=$(echo "$input" | jq -r '.context_window.context_window_size // 200000')
USED_PCT=$(echo "$input" | jq -r '.context_window.used_percentage // empty')

# Cache percentage for when it's not available
if [ -n "$USED_PCT" ] && [ "$USED_PCT" != "null" ]; then
    USED_PCT_INT=$(printf "%.0f" "$USED_PCT" 2>/dev/null || echo "0")
    echo "$USED_PCT" > /tmp/claude_statusline_cache.json
elif [ -f /tmp/claude_statusline_cache.json ]; then
    USED_PCT=$(cat /tmp/claude_statusline_cache.json 2>/dev/null || echo "")
    [ -n "$USED_PCT" ] && USED_PCT_INT=$(printf "%.0f" "$USED_PCT" 2>/dev/null || echo "0")
fi

format_tokens() {
    local t=$1
    if [ "$t" -ge 1000000 ] 2>/dev/null; then
        printf "%.1fM" $(echo "scale=1; $t/1000000" | bc)
    elif [ "$t" -ge 1000 ] 2>/dev/null; then
        printf "%.0fk" $(echo "$t/1000" | bc)
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

# Gradient progress bar — green/yellow/red zones
progress_bar() {
    local pct=$1 width=${2:-30}
    local filled=$(echo "scale=0; $width * $pct / 100" | bc 2>/dev/null || echo "0")
    [ "$filled" -gt "$width" ] && filled=$width
    local green_end=$((width * 50 / 100))
    local yellow_end=$((width * 75 / 100))

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

# Mini bar for usage limits — half-height blocks
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

# Git branch + dirty count
get_git_info() {
    git -C "${CURRENT_DIR}" rev-parse --git-dir > /dev/null 2>&1 || return
    local branch
    branch=$(git -C "${CURRENT_DIR}" branch --show-current 2>/dev/null)
    [ -z "$branch" ] && branch=$(git -C "${CURRENT_DIR}" rev-parse --short HEAD 2>/dev/null)
    local changes
    changes=$(git -C "${CURRENT_DIR}" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    [ "$changes" -gt 0 ] 2>/dev/null && echo "${branch} *${changes}" || echo "${branch}"
}

# --- Usage limits (5-hour + weekly) via OAuth API ---
USAGE_CACHE="/tmp/claude_usage_limits.json"
USAGE_LOCK="/tmp/claude_usage_fetch.lock"
USAGE_LAST_ATTEMPT="/tmp/claude_usage_last_attempt"
USAGE_CACHE_TTL=300  # 5 minutes

fetch_usage() {
    # Prevent concurrent fetches — skip if another is already running
    if [ -f "$USAGE_LOCK" ]; then
        local lock_mtime
        if [[ "$OSTYPE" == "darwin"* ]]; then
            lock_mtime=$(stat -f%m "$USAGE_LOCK" 2>/dev/null || echo 0)
        else
            lock_mtime=$(stat -c%Y "$USAGE_LOCK" 2>/dev/null || echo 0)
        fi
        local lock_age=$(( $(date +%s) - lock_mtime ))
        # Stale lock (>30s) — remove it; otherwise skip
        [ "$lock_age" -lt 30 ] && return 0
    fi
    echo $$ > "$USAGE_LOCK"
    trap 'rm -f "$USAGE_LOCK"' EXIT

    local creds token response
    # macOS: Keychain, Linux: credentials file
    if [[ "$OSTYPE" == "darwin"* ]]; then
        creds=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null) || { rm -f "$USAGE_LOCK"; return 1; }
    else
        [ -f ~/.claude/.credentials.json ] || { rm -f "$USAGE_LOCK"; return 1; }
        creds=$(<~/.claude/.credentials.json)
    fi
    token=$(echo "$creds" | jq -r '.claudeAiOauth.accessToken' 2>/dev/null) || { rm -f "$USAGE_LOCK"; return 1; }
    [ -z "$token" ] || [ "$token" = "null" ] && { rm -f "$USAGE_LOCK"; return 1; }

    response=$(curl -s --max-time 5 "https://api.anthropic.com/api/oauth/usage" \
        -H "Authorization: Bearer $token" \
        -H "anthropic-beta: oauth-2025-04-20" \
        -H "Content-Type: application/json" 2>/dev/null) || { rm -f "$USAGE_LOCK"; return 1; }

    # Always record that we attempted, so we don't retry for TTL seconds
    touch "$USAGE_LAST_ATTEMPT"

    # Validate response — only update cache on success
    if echo "$response" | jq -e '.five_hour' >/dev/null 2>&1; then
        echo "$response" > "$USAGE_CACHE"
    fi
    rm -f "$USAGE_LOCK"
}

get_usage_limits() {
    # Check when we last attempted a fetch (successful or not)
    local now=$(date +%s)
    local last_attempt_age=9999
    if [ -f "$USAGE_LAST_ATTEMPT" ]; then
        local attempt_mtime
        if [[ "$OSTYPE" == "darwin"* ]]; then
            attempt_mtime=$(stat -f%m "$USAGE_LAST_ATTEMPT" 2>/dev/null || echo 0)
        else
            attempt_mtime=$(stat -c%Y "$USAGE_LAST_ATTEMPT" 2>/dev/null || echo 0)
        fi
        last_attempt_age=$((now - attempt_mtime))
    fi

    if [ "$last_attempt_age" -gt "$USAGE_CACHE_TTL" ]; then
        fetch_usage 2>/dev/null &
    fi

    [ -f "$USAGE_CACHE" ] || return

    USAGE_5H=$(jq -r '.five_hour.utilization // empty' "$USAGE_CACHE" 2>/dev/null | cut -d. -f1)
    USAGE_7D=$(jq -r '.seven_day.utilization // empty' "$USAGE_CACHE" 2>/dev/null | cut -d. -f1)
}

# --- Assemble output ---
PROJECT_NAME="${PROJECT_DIR##*/}"
[ -z "$PROJECT_NAME" ] || [ "$PROJECT_NAME" = "/" ] && PROJECT_NAME="${CURRENT_DIR##*/}"
GIT_INFO=$(get_git_info)

# Line 1: Model | Project | Git | Date/Time
LINE1="${TN_ORANGE}${MODEL_DISPLAY}${RESET}"
LINE1+=" ${TN_COMMENT}|${RESET} ${TN_BLUE}${PROJECT_NAME}${RESET}"
[ -n "$GIT_INFO" ] && LINE1+=" ${TN_PURPLE}${GIT_INFO}${RESET}"
LINE1+=" ${TN_COMMENT}|${RESET} ${TN_COMMENT}$(date "+%a %d")${RESET} ${TN_TEAL}$(date "+%H")${TN_COMMENT}:${TN_TEAL}$(date "+%M")${RESET}"

# Compute target width from line 1 visible characters
# MODEL " | " PROJECT [" " GIT] " | " "Thu 12 18:26"(12)
TARGET_W=$((${#MODEL_DISPLAY} + 3 + ${#PROJECT_NAME} + 3 + 12))
[ -n "$GIT_INFO" ] && TARGET_W=$((TARGET_W + 1 + ${#GIT_INFO}))

# Line 2: Context window bar (width derived from line 1)
LINE2=""
if [ -n "$USED_PCT_INT" ]; then
    USED_FMT=$(format_tokens "$(echo "scale=0; $CONTEXT_SIZE * $USED_PCT / 100" | bc 2>/dev/null || echo 0)")
    TOTAL_FMT=$(format_tokens "$CONTEXT_SIZE")

    if [ "$USED_PCT_INT" -le 50 ] 2>/dev/null; then PCT_COLOR="$TN_GREEN"
    elif [ "$USED_PCT_INT" -le 75 ] 2>/dev/null; then PCT_COLOR="$TN_YELLOW"
    else PCT_COLOR="$TN_RED"; fi

    # suffix visible: " " pct(4) " " used "/" total
    BAR_W=$((TARGET_W - 1 - 4 - 1 - ${#USED_FMT} - 1 - ${#TOTAL_FMT}))
    [ "$BAR_W" -lt 10 ] && BAR_W=10
    PCT_DISPLAY=$(printf "%3d%%" "$USED_PCT_INT")
    LINE2="$(progress_bar "$USED_PCT_INT" "$BAR_W") ${PCT_COLOR}${PCT_DISPLAY}${RESET} ${TN_COMMENT}${USED_FMT}/${TOTAL_FMT}${RESET}"
fi

# Line 3: Usage limits — equal-width sections (total derived from line 1)
# Layout: "5h " bar " " pct(4) SEP "wk " bar " " pct(4)
# Fixed chars: 3 + 1 + 4 + SEP + 3 + 1 + 4 = 16 + SEP
get_usage_limits
LINE3=""
REMAINDER=$((TARGET_W - 16))
if [ $((REMAINDER % 2)) -eq 0 ]; then
    # even remainder — use 4-char separator to keep bars equal
    SEP_TEXT="  | "
    MINI_W=$(( (REMAINDER - 4) / 2 ))
else
    # odd remainder — use 3-char separator to keep bars equal
    SEP_TEXT=" | "
    MINI_W=$(( (REMAINDER - 3) / 2 ))
fi
[ "$MINI_W" -lt 4 ] && MINI_W=4
if [ -n "$USAGE_5H" ]; then
    U5_COLOR=$(color_for_pct "$USAGE_5H")
    U5_PCT=$(printf "%3d%%" "$USAGE_5H")
    LINE3+="${U5_COLOR}5h $(mini_bar "$USAGE_5H" "$MINI_W") ${U5_COLOR}${U5_PCT}${RESET}"
fi
if [ -n "$USAGE_7D" ]; then
    U7_COLOR=$(color_for_pct "$USAGE_7D")
    U7_PCT=$(printf "%3d%%" "$USAGE_7D")
    [ -n "$LINE3" ] && LINE3+="${TN_COMMENT}${SEP_TEXT}${RESET}"
    LINE3+="${U7_COLOR}wk $(mini_bar "$USAGE_7D" "$MINI_W") ${U7_COLOR}${U7_PCT}${RESET}"
fi

echo -e "$LINE1"
[ -n "$LINE2" ] && echo -e "$LINE2"
[ -n "$LINE3" ] && echo -e "$LINE3"
exit 0
