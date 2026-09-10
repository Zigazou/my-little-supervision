#!/bin/sh
# Keep runtime discovery usable even when PowerShell has not been installed.
set -eu
if ! command -v pwsh >/dev/null 2>&1; then
  echo 'My Little Supervision requires PowerShell 7 (pwsh) and a browser on Linux.' >&2
  exit 127
fi
script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec pwsh -NoProfile -File "$script_directory/src/MyLittleSupervision.ps1" "$@"
