#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: tools/ios/scan-logs.sh [DEVICE_UDID [SECONDS]]

Build, install and launch CardBal, then capture matching scan logs for 180 seconds.
Select a device by its UDID argument or DEVICE_ID environment variable.
Only this app’s logs on that device are read. Logs stay in build/ios/logs.
Requires Xcode and idevicesyslog. Ctrl+C stops only this command’s log reader.

Environment:
  DURATION_SECONDS           Capture duration (default: 180; argument overrides).
  LOG_FILTER                 Case-insensitive grep pattern (default: KSX).
  CONFIGURATION              Build configuration (default: Debug).
  SCHEME                     Xcode scheme (default: CardBal).
  DEVELOPMENT_TEAM           Optional signing-team override; defaults to project.
  PRODUCT_BUNDLE_IDENTIFIER  Optional bundle-ID override; defaults to project.
EOF
}

case "${1:-}" in
    -h|--help) usage; exit 0 ;;
esac
[[ $# -le 2 ]] || { usage >&2; exit 2; }

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/common.sh"
CONFIGURATION="${CONFIGURATION:-Debug}"
ios_select_device "${1:-}"
duration="${2:-${DURATION_SECONDS:-180}}"
[[ "$duration" =~ ^[0-9]+$ && ${#duration} -le 6 ]] \
    || ios_error 'SECONDS must be a positive integer (up to 999999).'
duration=$((10#$duration))
[[ "$duration" -gt 0 ]] || ios_error 'SECONDS must be greater than zero.'
log_filter="${LOG_FILTER:-KSX}"
if printf '\n' | grep -i -- "$log_filter" >/dev/null; then
    :
elif [[ $? -ne 1 ]]; then
    ios_error 'LOG_FILTER must be a valid grep pattern.'
fi
ios_require_command idevicesyslog
ios_build_and_launch

log_directory="$ios_build_root/logs"
mkdir -p "$log_directory"
log_path="$log_directory/scan-$(date '+%Y%m%d-%H%M%S')-$$.log"
pipe_directory="$(mktemp -d "$log_directory/.scan.XXXXXX")"
log_pid=''
cleanup() {
    if [[ -n "$log_pid" ]]; then
        kill "$log_pid" 2>/dev/null || true
        wait "$log_pid" 2>/dev/null || true
    fi
    rm -f "$pipe_directory/stream"
    rmdir "$pipe_directory"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkfifo "$pipe_directory/stream"
touch "$log_path"
idevicesyslog --udid "$DEVICE_ID" --process "$ios_process_name" --exit --no-colors \
    > "$pipe_directory/stream" &
log_pid=$!

printf 'Capturing %s logs for %s seconds: %s\n' "$ios_process_name" "$duration" "$log_path"
deadline=$((SECONDS + duration))
exec 3< "$pipe_directory/stream"
while (( SECONDS < deadline )); do
    remaining=$((deadline - SECONDS))
    if IFS= read -r -t "$remaining" line <&3; then
        if printf '%s\n' "$line" | grep -qi -- "$log_filter"; then
            printf '%s\n' "$line" | tee -a "$log_path"
        fi
    else
        if (( SECONDS < deadline )); then
            logger_status=0
            wait "$log_pid" || logger_status=$?
            log_pid=''
            [[ "$logger_status" -eq 0 ]] \
                || ios_error "idevicesyslog exited with status $logger_status."
        fi
        break
    fi
done
exec 3<&-
printf '\nScan summary (%s):\n' "$log_path"
grep -m 50 -F 'SFI 14' "$log_path" || true
grep -m 50 -F 'KSX6924_TX' "$log_path" || true
