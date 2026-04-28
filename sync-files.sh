#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if command -v pwsh >/dev/null 2>&1; then
  POWERSHELL_BIN="pwsh"
elif command -v powershell >/dev/null 2>&1; then
  POWERSHELL_BIN="powershell"
else
  echo "PowerShell is required. Install PowerShell 7+ and ensure pwsh is available in PATH." >&2
  exit 1
fi

exec "$POWERSHELL_BIN" -NoProfile -File "$SCRIPT_DIR/sync-files.ps1" "$@"