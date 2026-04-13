#!/bin/bash
# Claude Code status line — 3 lines + optional update notice
# Line 1: Model | Thinking | Effort | Tokens (%) | Cost
# Line 2: 5h bar @reset | 7d bar @reset | extra (if enabled)
# Line 3: Folder | Worktree | Branch (+N -N)
VERSION="1.2.0"

set -f  # disable globbing

input=$(cat)
[ -z "$input" ] && { printf "Claude"; exit 0; }

# ── Colors ────────────────────────────────────────────────────────────────────
blue='\033[38;2;0;153;255m'
orange='\033[38;2;255;176;85m'
green='\033[38;2;0;160;0m'
cyan='\033[38;2;46;149;153m'
red='\033[38;2;255;85;85m'
yellow='\033[38;2;230;200;0m'
white='\033[38;2;220;220;220m'
purple='\033[38;2;180;120;255m'
pink='\033[38;2;255;120;180m'
dim='\033[2m'
bold='\033[1m'
reset='\033[0m'

sep=" ${dim}|${reset} "

# ── Helpers ───────────────────────────────────────────────────────────────────
usage_color() {
    local pct=$1
    if   [ "$pct" -ge 90 ]; then echo "$red"
    elif [ "$pct" -ge 70 ]; then echo "$orange"
    elif [ "$pct" -ge 50 ]; then echo "$yellow"
    else echo "$green"
    fi
}

make_bar() {
    local pct=$1 width=${2:-10}
    local filled=$(( pct * width / 100 ))
    local empty=$(( width - filled ))
    local bar="" i
    for (( i=0; i<filled; i++ )); do bar+="█"; done
    for (( i=0; i<empty; i++ )); do bar+="░"; done
    echo "$bar"
}

format_tokens() {
    local num=$1
    if   [ "$num" -ge 1000000 ]; then awk "BEGIN {printf \"%.1fm\", $num/1000000}"
    elif [ "$num" -ge 1000 ];    then awk "BEGIN {printf \"%.0fk\", $num/1000}"
    else printf "%d" "$num"
    fi
}

iso_to_epoch() {
    local s="$1"
    local e
    e=$(date -d "$s" +%s 2>/dev/null) && { echo "$e"; return 0; }
    local stripped="${s%%.*}"; stripped="${stripped%%Z}"; stripped="${stripped%%+*}"
    stripped="${stripped%%-[0-9][0-9]:[0-9][0-9]}"
    if [[ "$s" == *"Z"* ]] || [[ "$s" == *"+00:00"* ]]; then
        e=$(env TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "$stripped" +%s 2>/dev/null)
    else
        e=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$stripped" +%s 2>/dev/null)
    fi
    [ -n "$e" ] && { echo "$e"; return 0; }
    return 1
}

fmt_reset() {
    # fmt_reset <epoch_or_iso> <style: time|datetime>
    local val="$1" style="${2:-time}"
    [ -z "$val" ] || [ "$val" = "null" ] && return
    local epoch
    # If numeric, it's already epoch
    if [[ "$val" =~ ^[0-9]+$ ]]; then
        epoch="$val"
    else
        epoch=$(iso_to_epoch "$val") || return
    fi
    case "$style" in
        datetime)
            date -d "@$epoch" +"%b %-d, %H:%M" 2>/dev/null || \
            date -j -r "$epoch" +"%b %-d, %H:%M" 2>/dev/null ;;
        *)
            date -d "@$epoch" +"%H:%M" 2>/dev/null || \
            date -j -r "$epoch" +"%H:%M" 2>/dev/null ;;
    esac
}

version_gt() {
    local a="${1#v}" b="${2#v}"
    local IFS='.'; read -r a1 a2 a3 <<< "$a"; read -r b1 b2 b3 <<< "$b"
    a1=${a1:-0}; a2=${a2:-0}; a3=${a3:-0}
    b1=${b1:-0}; b2=${b2:-0}; b3=${b3:-0}
    [ "$a1" -gt "$b1" ] 2>/dev/null && return 0
    [ "$a1" -lt "$b1" ] 2>/dev/null && return 1
    [ "$a2" -gt "$b2" ] 2>/dev/null && return 0
    [ "$a2" -lt "$b2" ] 2>/dev/null && return 1
    [ "$a3" -gt "$b3" ] 2>/dev/null && return 0
    return 1
}

# ── Config paths ──────────────────────────────────────────────────────────────
claude_config_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
settings_file="$claude_config_dir/settings.json"

# ── OAuth token (cross-platform) ──────────────────────────────────────────────
get_oauth_token() {
    [ -n "$CLAUDE_CODE_OAUTH_TOKEN" ] && { echo "$CLAUDE_CODE_OAUTH_TOKEN"; return 0; }

    if command -v security >/dev/null 2>&1; then
        local svc="Claude Code-credentials"
        [ -n "$CLAUDE_CONFIG_DIR" ] && {
            local h; h=$(echo -n "$CLAUDE_CONFIG_DIR" | shasum -a 256 | cut -c1-8)
            svc="Claude Code-credentials-${h}"
        }
        local blob; blob=$(security find-generic-password -s "$svc" -w 2>/dev/null)
        [ -n "$blob" ] && {
            local t; t=$(echo "$blob" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
            [ -n "$t" ] && [ "$t" != "null" ] && { echo "$t"; return 0; }
        }
    fi

    local creds="$claude_config_dir/.credentials.json"
    [ -f "$creds" ] && {
        local t; t=$(jq -r '.claudeAiOauth.accessToken // empty' "$creds" 2>/dev/null)
        [ -n "$t" ] && [ "$t" != "null" ] && { echo "$t"; return 0; }
    }

    if command -v secret-tool >/dev/null 2>&1; then
        local blob; blob=$(timeout 2 secret-tool lookup service "Claude Code-credentials" 2>/dev/null)
        [ -n "$blob" ] && {
            local t; t=$(echo "$blob" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
            [ -n "$t" ] && [ "$t" != "null" ] && { echo "$t"; return 0; }
        }
    fi

    echo ""
}

# ── Extract core fields ───────────────────────────────────────────────────────
model_name=$(echo "$input" | jq -r '.model.display_name // "Claude"')
cwd=$(echo "$input" | jq -r '.cwd // empty')

# Context window + tokens
size=$(echo "$input" | jq -r '.context_window.context_window_size // 200000')
[ "$size" -le 0 ] 2>/dev/null && size=200000
input_tokens=$(echo "$input" | jq -r '.context_window.current_usage.input_tokens // 0')
cache_create=$(echo "$input" | jq -r '.context_window.current_usage.cache_creation_input_tokens // 0')
cache_read=$(echo "$input"   | jq -r '.context_window.current_usage.cache_read_input_tokens // 0')
current=$(( input_tokens + cache_create + cache_read ))
pct_used=$(( size > 0 ? current * 100 / size : 0 ))
used_tokens=$(format_tokens "$current")
total_tokens=$(format_tokens "$size")

# Cost — total session + current turn estimate
cost_raw=$(echo "$input" | jq -r '.cost.total_cost_usd // empty')
if [ -n "$cost_raw" ]; then
    cost=$(LC_NUMERIC=C awk "BEGIN {printf \"%.4f\", $cost_raw}")
else
    ti=$(echo "$input" | jq -r '.context_window.total_input_tokens // 0')
    to=$(echo "$input" | jq -r '.context_window.total_output_tokens // 0')
    cost=$(LC_NUMERIC=C awk "BEGIN {printf \"%.4f\", ($ti*3/1000000)+($to*15/1000000)}")
fi
# Current turn cost from current_usage tokens (Sonnet baseline rates)
cur_in=$(echo "$input"     | jq -r '.context_window.current_usage.input_tokens // 0')
cur_cc=$(echo "$input"     | jq -r '.context_window.current_usage.cache_creation_input_tokens // 0')
cur_cr=$(echo "$input"     | jq -r '.context_window.current_usage.cache_read_input_tokens // 0')
cur_out=$(echo "$input"    | jq -r '.context_window.current_usage.output_tokens // 0')
turn_cost=$(LC_NUMERIC=C awk "BEGIN {printf \"%.4f\", \
    ($cur_in*3/1000000) + ($cur_cc*3.75/1000000) + ($cur_cr*0.30/1000000) + ($cur_out*15/1000000)}")

# Thinking mode
thinking_enabled=$(jq -r '.alwaysThinkingEnabled // "unset"' "$settings_file" 2>/dev/null)

# Effort level
effort_level="medium"
if [ -n "$CLAUDE_CODE_EFFORT_LEVEL" ]; then
    effort_level="$CLAUDE_CODE_EFFORT_LEVEL"
elif [ -f "$settings_file" ]; then
    ev=$(jq -r '.effortLevel // empty' "$settings_file" 2>/dev/null)
    [ -n "$ev" ] && effort_level="$ev"
fi

# Rate limits from built-in JSON
builtin_5h_pct=$(echo "$input"   | jq -r '.rate_limits.five_hour.used_percentage // empty')
builtin_5h_reset=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
builtin_7d_pct=$(echo "$input"   | jq -r '.rate_limits.seven_day.used_percentage // empty')
builtin_7d_reset=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')
use_builtin=false
{ [ -n "$builtin_5h_pct" ] || [ -n "$builtin_7d_pct" ]; } && use_builtin=true

# Extra usage via cached API call (only when builtin has no extra_usage)
dir_hash=$(echo -n "$claude_config_dir" | sha256sum 2>/dev/null || echo -n "$claude_config_dir" | shasum -a 256 2>/dev/null)
dir_hash=$(echo "$dir_hash" | cut -c1-8)
mkdir -p /tmp/claude
cache_file="/tmp/claude/statusline-usage-cache-${dir_hash}.json"
usage_data=""

if ! $use_builtin || true; then
    # Always try the API cache for extra_usage (builtin JSON never has it)
    needs_refresh=true
    if [ -f "$cache_file" ] && [ -s "$cache_file" ]; then
        cache_mtime=$(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file" 2>/dev/null)
        cache_age=$(( $(date +%s) - cache_mtime ))
        [ "$cache_age" -lt 60 ] && needs_refresh=false
        usage_data=$(cat "$cache_file" 2>/dev/null)
    fi
    if $needs_refresh; then
        touch "$cache_file"
        token=$(get_oauth_token)
        if [ -n "$token" ] && [ "$token" != "null" ]; then
            resp=$(curl -s --max-time 10 \
                -H "Accept: application/json" \
                -H "Content-Type: application/json" \
                -H "Authorization: Bearer $token" \
                -H "anthropic-beta: oauth-2025-04-20" \
                -H "User-Agent: claude-code/2.1.92" \
                "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)
            if [ -n "$resp" ] && echo "$resp" | jq -e '.five_hour' >/dev/null 2>&1; then
                usage_data="$resp"
                echo "$resp" > "$cache_file"
            fi
        fi
    fi
fi

# ── Update check (cached 24h) ─────────────────────────────────────────────────
vcache="/tmp/claude/statusline-version-cache.json"
vdata=""
vnr=true
[ -f "$vcache" ] && {
    vm=$(stat -c %Y "$vcache" 2>/dev/null || stat -f %m "$vcache" 2>/dev/null)
    [ $(( $(date +%s) - vm )) -lt 86400 ] && vnr=false
    vdata=$(cat "$vcache" 2>/dev/null)
}
if $vnr; then
    touch "$vcache" 2>/dev/null
    vr=$(curl -s --max-time 5 \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/daniel3303/ClaudeCodeStatusLine/releases/latest" 2>/dev/null)
    if [ -n "$vr" ] && echo "$vr" | jq -e '.tag_name' >/dev/null 2>&1; then
        vdata="$vr"; echo "$vr" > "$vcache"
    fi
fi
update_notice=""
if [ -n "$vdata" ]; then
    latest=$(echo "$vdata" | jq -r '.tag_name // empty')
    version_gt "$latest" "$VERSION" && \
        update_notice="\n${dim}↑ Update available: ${latest} — github.com/daniel3303/ClaudeCodeStatusLine${reset}"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# LINE 1: Model | Thinking | Effort | Tokens (%) | Cost
# ═══════════════════════════════════════════════════════════════════════════════
ctx_color=$(usage_color "$pct_used")

line1="🤖 ${blue}${bold}${model_name}${reset}"

# Thinking
case "$thinking_enabled" in
    "false") line1+="${sep}🧠 ${dim}off${reset}" ;;
    "true")  line1+="${sep}🧠 ${purple}on${reset}" ;;
    *)       line1+="${sep}🧠 ${dim}auto${reset}" ;;
esac

# Effort
case "$effort_level" in
    low)    line1+="${sep}💪 ${dim}low${reset}" ;;
    medium) line1+="${sep}💪 ${orange}med${reset}" ;;
    high)   line1+="${sep}💪 ${green}high${reset}" ;;
    max)    line1+="${sep}💪 ${red}max${reset}" ;;
    *)      line1+="${sep}💪 ${orange}${effort_level}${reset}" ;;
esac

# Tokens + context %
line1+="${sep}📖 ${ctx_color}${used_tokens}/${total_tokens}${reset} ${dim}(${reset}${ctx_color}${pct_used}%${reset}${dim})${reset}"

# Cost
line1+="${sep}💰 ${orange}\$${cost} (\$${turn_cost})${reset}"

# ═══════════════════════════════════════════════════════════════════════════════
# LINE 2: Rate limits + extra usage
# ═══════════════════════════════════════════════════════════════════════════════
line2=""

if $use_builtin; then
    if [ -n "$builtin_5h_pct" ]; then
        p5=$(printf "%.0f" "$builtin_5h_pct")
        c5=$(usage_color "$p5")
        bar5=$(make_bar "$p5" 10)
        line2+="⏱️  ${c5}${bar5} ${p5}%${reset}"
        rt5=$(fmt_reset "$builtin_5h_reset" "time")
        [ -n "$rt5" ] && line2+=" ${dim}→ ${rt5}${reset}"
        line2+=" ${dim}5h${reset}"
    fi
    if [ -n "$builtin_7d_pct" ]; then
        p7=$(printf "%.0f" "$builtin_7d_pct")
        c7=$(usage_color "$p7")
        bar7=$(make_bar "$p7" 10)
        line2+="${sep}📅 ${c7}${bar7} ${p7}%${reset}"
        rt7=$(fmt_reset "$builtin_7d_reset" "datetime")
        [ -n "$rt7" ] && line2+=" ${dim}→ ${rt7}${reset}"
        line2+=" ${dim}7d${reset}"
    fi
else
    line2+="⏱️  ${dim}── 5h${reset}${sep}📅 ${dim}── 7d${reset}"
fi

# Extra usage from API (appended to line 2 regardless of builtin/fallback)
if [ -n "$usage_data" ] && echo "$usage_data" | jq -e '.extra_usage' >/dev/null 2>&1; then
    extra_enabled=$(echo "$usage_data" | jq -r '.extra_usage.is_enabled // false')
    if [ "$extra_enabled" = "true" ]; then
        extra_pct=$(echo "$usage_data" | jq -r '.extra_usage.utilization // 0' | awk '{printf "%.0f", $1}')
        extra_used=$(echo "$usage_data" | jq -r '.extra_usage.used_credits // 0' | LC_NUMERIC=C awk '{printf "%.2f", $1/100}')
        extra_limit=$(echo "$usage_data" | jq -r '.extra_usage.monthly_limit // 0' | LC_NUMERIC=C awk '{printf "%.2f", $1/100}')
        extra_bar=$(make_bar "$extra_pct" 10)
        ec=$(usage_color "$extra_pct")
        if [ -n "$extra_used" ] && [ -n "$extra_limit" ] && \
           [[ "$extra_used" != *'$'* ]] && [[ "$extra_limit" != *'$'* ]]; then
            line2+="${sep}⭐ ${ec}${extra_bar} \$${extra_used}/\$${extra_limit}${reset}"
        else
            line2+="${sep}⭐ ${green}extra enabled${reset}"
        fi
    fi
elif [ -n "$usage_data" ] && echo "$usage_data" | jq -e '.five_hour' >/dev/null 2>&1 && ! $use_builtin; then
    # API fallback for 5h/7d too (no builtin data)
    p5=$(echo "$usage_data" | jq -r '.five_hour.utilization // 0' | awk '{printf "%.0f", $1}')
    r5=$(echo "$usage_data" | jq -r '.five_hour.resets_at // empty')
    c5=$(usage_color "$p5"); bar5=$(make_bar "$p5" 10)
    line2="⏱️  ${c5}${bar5} ${p5}%${reset}"
    rt5=$(fmt_reset "$r5" "time"); [ -n "$rt5" ] && line2+=" ${dim}→ ${rt5}${reset}"
    line2+=" ${dim}5h${reset}"

    p7=$(echo "$usage_data" | jq -r '.seven_day.utilization // 0' | awk '{printf "%.0f", $1}')
    r7=$(echo "$usage_data" | jq -r '.seven_day.resets_at // empty')
    c7=$(usage_color "$p7"); bar7=$(make_bar "$p7" 10)
    line2+="${sep}📅 ${c7}${bar7} ${p7}%${reset}"
    rt7=$(fmt_reset "$r7" "datetime"); [ -n "$rt7" ] && line2+=" ${dim}→ ${rt7}${reset}"
    line2+=" ${dim}7d${reset}"

    extra_enabled=$(echo "$usage_data" | jq -r '.extra_usage.is_enabled // false')
    if [ "$extra_enabled" = "true" ]; then
        extra_pct=$(echo "$usage_data" | jq -r '.extra_usage.utilization // 0' | awk '{printf "%.0f", $1}')
        extra_used=$(echo "$usage_data" | jq -r '.extra_usage.used_credits // 0' | LC_NUMERIC=C awk '{printf "%.2f", $1/100}')
        extra_limit=$(echo "$usage_data" | jq -r '.extra_usage.monthly_limit // 0' | LC_NUMERIC=C awk '{printf "%.2f", $1/100}')
        extra_bar=$(make_bar "$extra_pct" 10)
        ec=$(usage_color "$extra_pct")
        if [ -n "$extra_used" ] && [ -n "$extra_limit" ] && \
           [[ "$extra_used" != *'$'* ]] && [[ "$extra_limit" != *'$'* ]]; then
            line2+="${sep}⭐ ${ec}${extra_bar} \$${extra_used}/\$${extra_limit}${reset}"
        else
            line2+="${sep}⭐ ${green}extra enabled${reset}"
        fi
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════════
# LINE 3: Folder | Worktree | Branch (+N -N)
# ═══════════════════════════════════════════════════════════════════════════════
line3=""

if [ -n "$cwd" ]; then
    folder="${cwd##*/}"
    line3+="📁 ${cyan}${folder}${reset}"
fi

worktree_name=$(echo "$input" | jq -r '.worktree.name // empty')
if [ -n "$worktree_name" ] && [ "$worktree_name" != "null" ]; then
    line3+="${sep}🌳 ${green}${worktree_name}${reset}"
fi

if [ -n "$cwd" ]; then
    git_branch=$(git -C "$cwd" --no-optional-locks rev-parse --abbrev-ref HEAD 2>/dev/null)
    if [ -n "$git_branch" ]; then
        [ -n "$line3" ] && line3+="$sep"
        line3+="🌿 ${green}${git_branch}${reset}"
        git_stat=$(git -C "$cwd" --no-optional-locks diff --numstat 2>/dev/null \
            | awk '{a+=$1; d+=$2} END {if (a+d>0) printf "+%d -%d", a, d}')
        if [ -n "$git_stat" ]; then
            added="${git_stat%% *}"; removed="${git_stat##* }"
            line3+=" ${dim}(${reset}${green}${added}${reset} ${red}${removed}${reset}${dim})${reset}"
        fi
    fi
fi

# ── Output ────────────────────────────────────────────────────────────────────
printf "%b\n%b\n%b%b" "$line1" "$line2" "$line3" "$update_notice"

exit 0
