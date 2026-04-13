# Claude Code StatusLine for Windows 11 — VS Code Terminal
# Adapted from working reference script pattern
# VERSION: 1.2.1

param()
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# ── Read stdin (proven pattern from working script) ───────────────────────────
$jsonInput = ""
try {
    $inputStream = [System.IO.StreamReader]::new([System.Console]::OpenStandardInput())
    $jsonInput = $inputStream.ReadToEnd()
    $inputStream.Close()
} catch {
    $jsonInput = '{"model":{"display_name":"Claude"}}'
}

# ── ANSI colors (using [char]27 — proven working on Windows) ─────────────────
$ESC    = [char]27
$blue   = "$ESC[38;2;0;153;255m"
$orange = "$ESC[38;5;208m"
$green  = "$ESC[38;2;0;160;0m"
$cyan   = "$ESC[38;2;46;149;153m"
$red    = "$ESC[38;2;255;85;85m"
$yellow = "$ESC[38;2;230;200;0m"
$purple = "$ESC[38;2;180;120;255m"
$dim    = "$ESC[2m"
$bold   = "$ESC[1m"
$reset  = "$ESC[0m"
$sep    = " $dim|$reset "

# ── Helpers ───────────────────────────────────────────────────────────────────
function UsageColor([int]$p) {
    if ($p -ge 90) { return $red }
    elseif ($p -ge 70) { return $orange }
    elseif ($p -ge 50) { return $yellow }
    else { return $green }
}

function MakeBar([int]$p, [int]$w = 10) {
    $f = [math]::Max(0, [math]::Min($w, [int][math]::Floor($p * $w / 100)))
    return ('█' * $f) + ('░' * ($w - $f))
}

function FmtTokens([long]$n) {
    if ($n -ge 1000000) { return "{0:F1}m" -f ($n / 1000000) }
    elseif ($n -ge 1000) { return "{0:F0}k" -f ($n / 1000) }
    else { return "$n" }
}

function FmtReset($val, [string]$style = 'time') {
    if (-not $val -or "$val" -eq 'null') { return '' }
    try {
        $epoch = if ("$val" -match '^\d+$') { [long]$val } else { [DateTimeOffset]::Parse("$val").ToUnixTimeSeconds() }
        $dt = [DateTimeOffset]::FromUnixTimeSeconds($epoch).LocalDateTime
        if ($style -eq 'datetime') { return $dt.ToString("MMM d, HH:mm") }
        else { return $dt.ToString("HH:mm") }
    } catch { return '' }
}

function Dig($obj, [string[]]$path, $default = $null) {
    $cur = $obj
    foreach ($k in $path) {
        if ($null -eq $cur) { return $default }
        try { $cur = $cur.$k } catch { return $default }
    }
    if ($null -eq $cur) { return $default }
    return $cur
}

# ── Parse JSON ────────────────────────────────────────────────────────────────
$data = $null
try { $data = $jsonInput | ConvertFrom-Json } catch {}

if ($null -eq $data) {
    [System.Console]::Write("$orange$bold`Claude$reset")
    [System.Console]::Out.Flush()
    exit 0
}

# ── Config ────────────────────────────────────────────────────────────────────
$cfgDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { "$env:USERPROFILE\.claude" }
$sf     = $null
try {
    $sfPath = "$cfgDir\settings.json"
    if (Test-Path $sfPath) { $sf = Get-Content $sfPath -Raw | ConvertFrom-Json }
} catch {}

# ── Core fields ───────────────────────────────────────────────────────────────
try {
    $model = Dig $data @('model','display_name') 'Claude'
    $cwd   = Dig $data @('cwd') ''

    $size = [long](Dig $data @('context_window','context_window_size') 200000)
    if ($size -le 0) { $size = 200000 }

    $tIn  = [long](Dig $data @('context_window','current_usage','input_tokens') 0)
    $tCc  = [long](Dig $data @('context_window','current_usage','cache_creation_input_tokens') 0)
    $tCr  = [long](Dig $data @('context_window','current_usage','cache_read_input_tokens') 0)
    $tOut = [long](Dig $data @('context_window','current_usage','output_tokens') 0)
    $used = $tIn + $tCc + $tCr
    $pct  = if ($size -gt 0) { [int][math]::Floor($used * 100 / $size) } else { 0 }

    $costRaw = Dig $data @('cost','total_cost_usd') $null
    $cost = if ($costRaw) {
        "{0:F4}" -f [double]$costRaw
    } else {
        $ti = [double](Dig $data @('context_window','total_input_tokens') 0)
        $to = [double](Dig $data @('context_window','total_output_tokens') 0)
        "{0:F4}" -f (($ti * 3 / 1e6) + ($to * 15 / 1e6))
    }
    $turn = "{0:F4}" -f (($tIn*3/1e6) + ($tCc*3.75/1e6) + ($tCr*0.30/1e6) + ($tOut*15/1e6))

    $thinking = 'unset'
    if ($sf -and $null -ne $sf.alwaysThinkingEnabled) {
        $thinking = "$($sf.alwaysThinkingEnabled)".ToLower()
    }

    $effort = 'medium'
    if ($env:CLAUDE_CODE_EFFORT_LEVEL) { $effort = $env:CLAUDE_CODE_EFFORT_LEVEL }
    elseif ($sf -and $sf.effortLevel) { $effort = "$($sf.effortLevel)" }
} catch {
    $model = 'Claude'; $cwd = ''; $used = 0; $size = 200000; $pct = 0
    $cost = '0.0000'; $turn = '0.0000'; $thinking = 'unset'; $effort = 'medium'
}

# ── Rate limits (builtin JSON) ────────────────────────────────────────────────
$b5p = Dig $data @('rate_limits','five_hour','used_percentage') $null
$b5r = Dig $data @('rate_limits','five_hour','resets_at') $null
$b7p = Dig $data @('rate_limits','seven_day','used_percentage') $null
$b7r = Dig $data @('rate_limits','seven_day','resets_at') $null
$hasBuiltin = ($null -ne $b5p) -or ($null -ne $b7p)

# ── Cached API call for extra_usage ──────────────────────────────────────────
$apiData = $null
try {
    $tmpDir = "$env:TEMP\claude"
    if (-not (Test-Path $tmpDir)) { New-Item -ItemType Directory $tmpDir -Force | Out-Null }

    $hashBytes = [System.Text.Encoding]::UTF8.GetBytes($cfgDir)
    $hashHex   = [BitConverter]::ToString(
        [System.Security.Cryptography.SHA256]::Create().ComputeHash($hashBytes)
    ).Replace('-','').ToLower().Substring(0,8)
    $cacheF  = "$tmpDir\statusline-usage-$hashHex.json"
    $doFetch = $true

    if (Test-Path $cacheF) {
        $age = ((Get-Date) - (Get-Item $cacheF).LastWriteTime).TotalSeconds
        if ($age -lt 60) {
            $apiData = Get-Content $cacheF -Raw | ConvertFrom-Json
            $doFetch = $false
        }
    }

    if ($doFetch) {
        $token = ''
        if ($env:CLAUDE_CODE_OAUTH_TOKEN) {
            $token = $env:CLAUDE_CODE_OAUTH_TOKEN
        } else {
            $credsF = "$cfgDir\.credentials.json"
            if (Test-Path $credsF) {
                $token = (Get-Content $credsF -Raw | ConvertFrom-Json).claudeAiOauth.accessToken
            }
        }
        if ($token -and $token -ne 'null') {
            $apiData = Invoke-RestMethod 'https://api.anthropic.com/api/oauth/usage' -TimeoutSec 10 -Headers @{
                Authorization    = "Bearer $token"
                'anthropic-beta' = 'oauth-2025-04-20'
                'User-Agent'     = 'claude-code/2.1.92'
            }
            if ($apiData -and $apiData.five_hour) {
                $apiData | ConvertTo-Json -Depth 10 | Set-Content $cacheF
            }
        }
        if (-not $apiData) { '{}' | Set-Content $cacheF }
    }
} catch {}

# ── Update check (24h cache) ──────────────────────────────────────────────────
$updateNotice = ''
try {
    $vCacheF  = "$env:TEMP\claude\statusline-version.json"
    $vData    = $null
    $doVFetch = $true

    if (Test-Path $vCacheF) {
        if (((Get-Date) - (Get-Item $vCacheF).LastWriteTime).TotalSeconds -lt 86400) {
            $vData = Get-Content $vCacheF -Raw | ConvertFrom-Json
            $doVFetch = $false
        }
    }
    if ($doVFetch) {
        $vData = Invoke-RestMethod `
            'https://api.github.com/repos/daniel3303/ClaudeCodeStatusLine/releases/latest' `
            -Headers @{ Accept = 'application/vnd.github+json' } -TimeoutSec 5
        if ($vData -and $vData.tag_name) { $vData | ConvertTo-Json | Set-Content $vCacheF }
    }
    if ($vData -and $vData.tag_name) {
        $latest = [version]($vData.tag_name.TrimStart('v'))
        if ($latest -gt [version]'1.2.0') {
            $updateNotice = "`n$dim↑ Update available: $($vData.tag_name) — github.com/daniel3303/ClaudeCodeStatusLine$reset"
        }
    }
} catch {}

# ═══════════════════════════════════════════════════════════════════════════════
# LINE 1: Model | Thinking | Effort | Tokens | Cost
# ═══════════════════════════════════════════════════════════════════════════════
try {
    $cc = UsageColor $pct
    $L1 = "🤖 $blue$bold$model$reset"

    $L1 += $sep + "🧠 " + $(switch ($thinking) {
        'false' { "${dim}off${reset}" }
        'true'  { "${purple}on${reset}" }
        default { "${dim}auto${reset}" }
    })

    $L1 += $sep + "💪 " + $(switch ($effort) {
        'low'    { "${dim}low${reset}" }
        'high'   { "${green}high${reset}" }
        'max'    { "${red}max${reset}" }
        default  { "${orange}med${reset}" }
    })

    $L1 += "$sep`📖 $cc$(FmtTokens $used)/$(FmtTokens $size)$reset $dim($reset$cc$pct%$reset$dim)$reset"
    $L1 += "$sep`💰 $orange`$$cost (`$$turn)$reset"
} catch {
    $L1 = "$orange$bold`Claude$reset"
}

# ═══════════════════════════════════════════════════════════════════════════════
# LINE 2: Rate limits
# ═══════════════════════════════════════════════════════════════════════════════
try {
    $L2 = ''

    if ($hasBuiltin) {
        if ($null -ne $b5p) {
            $p = [int][math]::Round([double]$b5p)
            $c = UsageColor $p
            $L2 += "⏱️  $c$(MakeBar $p) $p%$reset"
            $rt = FmtReset $b5r 'time'
            if ($rt) { $L2 += " $dim→ $rt$reset" }
            $L2 += " $dim`5h$reset"
        }
        if ($null -ne $b7p) {
            $p = [int][math]::Round([double]$b7p)
            $c = UsageColor $p
            $L2 += "$sep`📅 $c$(MakeBar $p) $p%$reset"
            $rt = FmtReset $b7r 'datetime'
            if ($rt) { $L2 += " $dim→ $rt$reset" }
            $L2 += " $dim`7d$reset"
        }
    } elseif ($apiData -and $apiData.five_hour) {
        $p5 = [int][math]::Round([double]$apiData.five_hour.utilization)
        $c5 = UsageColor $p5
        $L2  = "⏱️  $c5$(MakeBar $p5) $p5%$reset"
        $rt5 = FmtReset $apiData.five_hour.resets_at 'time'
        if ($rt5) { $L2 += " $dim→ $rt5$reset" }
        $L2 += " $dim`5h$reset"

        if ($apiData.seven_day) {
            $p7 = [int][math]::Round([double]$apiData.seven_day.utilization)
            $c7 = UsageColor $p7
            $L2 += "$sep`📅 $c7$(MakeBar $p7) $p7%$reset"
            $rt7 = FmtReset $apiData.seven_day.resets_at 'datetime'
            if ($rt7) { $L2 += " $dim→ $rt7$reset" }
            $L2 += " ${dim}7d${reset}"
        }
    } else {
        $L2 = "⏱️  $dim`── 5h$reset$sep`📅 $dim`── 7d$reset"
    }

    if ($apiData -and $apiData.extra_usage -and "$($apiData.extra_usage.is_enabled)" -match '(?i)true') {
        $ep = [int][math]::Round([double]$apiData.extra_usage.utilization)
        $eu = "{0:F2}" -f ([double]$apiData.extra_usage.used_credits / 100)
        $el = "{0:F2}" -f ([double]$apiData.extra_usage.monthly_limit / 100)
        $ec = UsageColor $ep
        $L2 += "$sep`⭐ $ec$(MakeBar $ep) `$$eu/`$$el$reset"
    }
} catch {
    $L2 = "⏱️  $dim`── 5h$reset$sep`📅 $dim`── 7d$reset"
}

# ═══════════════════════════════════════════════════════════════════════════════
# LINE 3: Folder | Worktree | Branch
# ═══════════════════════════════════════════════════════════════════════════════
try {
    $L3 = ''

    if ($cwd) { $L3 = "📁 $cyan$(Split-Path $cwd -Leaf)$reset" }

    $wt = Dig $data @('worktree','name') ''
    if ($wt -and $wt -ne 'null') {
        if ($L3) { $L3 += $sep }
        $L3 += "🌳 $green$wt$reset"
    }

    if ($cwd) {
        $branch = & git -C "$cwd" --no-optional-locks rev-parse --abbrev-ref HEAD 2>$null
        if ($LASTEXITCODE -eq 0 -and $branch) {
            if ($L3) { $L3 += $sep }
            $L3 += "🌿 $green$branch$reset"
            $adds = 0; $dels = 0
            & git -C "$cwd" --no-optional-locks diff --numstat 2>$null | ForEach-Object {
                $parts = $_ -split '\s+'
                if ($parts.Count -ge 2) {
                    # git uses '-' for binary files; treat as 0
                    if ($parts[0] -match '^\d+$') { $adds += [int]$parts[0] }
                    if ($parts[1] -match '^\d+$') { $dels += [int]$parts[1] }
                }
            }
            if (($adds + $dels) -gt 0) {
                $L3 += " $dim($reset$green+$adds$reset $red-$dels$reset$dim)$reset"
            }
        }
    }
} catch {
    $L3 = ''
}

# ── Output (exact pattern from working reference script) ──────────────────────
$output = "$L1`n$L2"
if ($L3) { $output += "`n$L3" }
if ($updateNotice) { $output += $updateNotice }
[System.Console]::Write($output)
[System.Console]::Out.Flush()
exit 0
