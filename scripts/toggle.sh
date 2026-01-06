#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-}"
case "$ACTION" in
open) exec "$(dirname "$0")/open_door.sh" ;;
close | lock) exec "$(dirname "$0")/close_door.sh" ;;
*)
  echo "Usage: $0 {open|close}"
  exit 2
  ;;
esac
