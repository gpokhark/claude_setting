# Claude Code Settings

Personal Claude Code configuration files — settings and status line scripts for Windows and Raspberry Pi (Linux).

## Contents

| File | Description |
|------|-------------|
| `setting_windows.json` | Claude Code `settings.json` for Windows — enables the PowerShell status line |
| `setting_rasp.json` | Claude Code `settings.json` for Raspberry Pi / Linux — enables the Bash status line, hooks, model, and plugins |
| `statusline.ps1` | Status line script for Windows (PowerShell) |
| `statusline.sh` | Status line script for Linux/macOS (Bash) |

## Status Line

The status line scripts display a 3-line HUD inside the Claude Code terminal, showing:

**Line 1** — `Model | Thinking | Effort | Context tokens (%) | Cost`

**Line 2** — `5-hour rate limit bar | 7-day rate limit bar | Extra usage (if enabled)`

**Line 3** — `Working folder | Worktree | Git branch (+adds -dels)`

Color coding:
- Green → under 50% used
- Yellow → 50–69%
- Orange → 70–89%
- Red → 90%+

Both scripts also check for upstream updates once every 24 hours and append a notice when a newer version is available.

## Setup

### Windows

1. Copy `statusline.ps1` to `%USERPROFILE%\.claude\statusline.ps1`
2. Merge `setting_windows.json` into `%USERPROFILE%\.claude\settings.json`

```json
{
  "statusLine": {
    "type": "command",
    "command": "powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"C:\\Users\\<YourUser>\\.claude\\statusline.ps1\""
  }
}
```

### Raspberry Pi / Linux

1. Copy `statusline.sh` to `~/.claude/statusline.sh` and make it executable:
   ```bash
   chmod +x ~/.claude/statusline.sh
   ```
2. Merge `setting_rasp.json` into `~/.claude/settings.json`

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash /home/<user>/.claude/statusline.sh"
  }
}
```

## Dependencies

| Platform | Requirements |
|----------|-------------|
| Windows  | PowerShell 5+, internet access for rate-limit API calls |
| Linux    | `bash`, `jq`, `curl`, `git` |

## Credits

Status line scripts adapted from [daniel3303/ClaudeCodeStatusLine](https://github.com/daniel3303/ClaudeCodeStatusLine).
