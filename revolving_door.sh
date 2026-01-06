#!/usr/bin/env bash
set -euo pipefail

NS="${NS:-default}"
URL="${URL:-http://demo.local:18200/api}"

CJ_OPEN="${CJ_OPEN:-door-open}"
CJ_CLOSE="${CJ_CLOSE:-door-close}"

TIMEOUT_JOB="${TIMEOUT_JOB:-180s}"
TRIES="${TRIES:-80}"
SLEEP_S="${SLEEP_S:-0.25}"
VERBOSE="${VERBOSE:-0}"

usage() {
  cat <<'EOF'
Usage:
  revolving_door.sh open
  revolving_door.sh close
  revolving_door.sh status
  revolving_door.sh cycle|toggle

  revolving_door.sh open [--verbose]
  revolving_door.sh close [--verbose]
  revolving_door.sh status [--json]

Env overrides:
  NS, URL, CJ_OPEN, CJ_CLOSE, TIMEOUT_JOB, TRIES, SLEEP_S
EOF
}

json_field() {
  local field="$1" body="$2"

  if command -v python3 >/dev/null 2>&1; then
    printf "%s" "$body" | python3 -c 'import json,sys
try:
  data=json.load(sys.stdin)
  print(data.get(sys.argv[1],""))
except Exception:
  print("")' "$field"
  else
    printf "%s" "$body" | tr -d '\n' | sed 's/[{}]//g' | tr ',' '\n' |
      sed 's/^ *"//; s/" *$//; s/" *: *"/=/; s/" *: */=/' |
      awk -F= -v k="$field" '$1==k{print $2; exit}'
  fi
}

http_get() {
  # outputs: "<code>\n<body>"
  local tmp code
  tmp="$(mktemp)"
  code="$(curl -sS -o "$tmp" -w '%{http_code}' "$URL" || true)"
  printf "%s\n" "$code"
  cat "$tmp" || true
  rm -f "$tmp"
}

door_state() {
  local resp code body
  resp="$(http_get)"
  code="$(printf "%s" "$resp" | head -n 1 | tr -d '\r')"
  body="$(printf "%s" "$resp" | tail -n +2)"
  printf "%s\n" "$code"
  printf "%s\n" "$body"
}

already_in_state() {
  local want="$1"
  local resp code body door

  resp="$(http_get)"
  code="$(printf "%s" "$resp" | head -n 1 | tr -d '\r')"
  body="$(printf "%s" "$resp" | tail -n +2)"

  door="$(json_field "door" "$body")"
  [ "$door" = "$want" ]
}

print_status() {
  local want_json="${1:-}" # pass --json to also print the raw JSON
  local resp code body door reason user lease ttl

  resp="$(http_get)"
  code="$(printf "%s" "$resp" | head -n 1 | tr -d '\r')"
  body="$(printf "%s" "$resp" | tail -n +2)"

  door="$(json_field "door" "$body")"
  reason="$(json_field "reason" "$body")"
  user="$(json_field "username" "$body")"
  lease="$(json_field "lease_id" "$body")"
  ttl="$(json_field "lease_duration" "$body")"

  if [ "$door" = "opened" ]; then
    if [ -n "$user" ]; then
      printf "🔓 Door is OPEN (user: %s, ttl: %ss)\n" "$user" "${ttl:-?}"
    else
      printf "🔓 Door is OPEN\n"
    fi
    [ "$VERBOSE" = "1" ] && [ -n "$lease" ] && printf "   lease: %s\n" "$lease"
  elif [ "$door" = "locked" ]; then
    if [ -n "$reason" ]; then
      printf "🔒 Door is LOCKED (reason: %s)\n" "$reason"
    else
      printf "🔒 Door is LOCKED\n"
    fi
  else
    printf "❔ Door state unknown (http: %s)\n" "${code:-?}"
  fi

  if [ "$want_json" = "--json" ] || [ "$VERBOSE" = "1" ]; then
    printf "%s\n" "$body"
  fi
}

wait_for_door() {
  local want="$1"

  for i in $(seq 1 "$TRIES"); do
    local resp code body door reason
    resp="$(http_get)"
    code="$(printf "%s" "$resp" | head -n 1 | tr -d '\r')"
    body="$(printf "%s" "$resp" | tail -n +2)"

    door="$(json_field "door" "$body")"
    reason="$(json_field "reason" "$body")"

    if [ "$VERBOSE" = "1" ]; then
      if [ -z "$door" ]; then
        printf "%02d  http=%s  door=?  body=%s\n" \
          "$i" "${code:-?}" "$(printf "%s" "$body" | tr '\n' ' ' | head -c 120)"
      else
        printf "%02d  http=%s  door=%s reason=%s\n" \
          "$i" "${code:-?}" "$door" "${reason:-}"
      fi
    fi

    if [ "$door" = "$want" ]; then
      if [ "$VERBOSE" = "1" ]; then
        echo
        echo "✅ reached door=$want"
        echo "$body"
      else
        # pretty final line only
        print_status
      fi
      return 0
    fi

    sleep "$SLEEP_S"
  done

  echo "❌ timed out waiting for door=$want" >&2
  print_status --json || true
  return 1
}

run_cronjob_as_job() {
  local cj="$1" want="$2" vault_ctr="$3"
  local job
  job="door-${want}-$(date +%s)"

  kubectl -n "$NS" create job --from=cronjob/"$cj" "$job" >/dev/null

  cleanup() { kubectl -n "$NS" delete job "$job" --ignore-not-found >/dev/null 2>&1 || true; }
  trap cleanup RETURN

  kubectl -n "$NS" wait --for=condition=complete job/"$job" --timeout="$TIMEOUT_JOB"

  echo
  kubectl -n "$NS" logs job/"$job" -c "$vault_ctr" || true
  kubectl -n "$NS" logs job/"$job" -c restart || true
  kubectl -n "$NS" logs job/"$job" -c status || true
  echo

  wait_for_door "$want"
  trap - RETURN
}

cmd="${1:-}"
shift || true

case "${1:-}" in
--verbose) VERBOSE=1 ;;
esac

case "$cmd" in
open)
  if already_in_state "opened"; then
    print_status
    exit 0
  fi
  run_cronjob_as_job "$CJ_OPEN" "opened" "vault-open"
  ;;
close)
  if already_in_state "locked"; then
    print_status
    exit 0
  fi
  run_cronjob_as_job "$CJ_CLOSE" "locked" "vault-close"
  ;;
status)
  if [ "${1:-}" = "--json" ]; then
    print_status --json
  else
    print_status
  fi
  ;;
cycle | toggle)
  # toggle: if locked -> open, if opened -> close
  resp="$(http_get)"
  body="$(printf "%s" "$resp" | tail -n +2)"
  door="$(json_field "door" "$body")"

  case "$door" in
  locked)
    "$0" open
    ;;
  opened)
    "$0" close
    ;;
  *)
    # unknown state: show status and exit non-zero
    print_status --json || true
    echo "❌ cannot cycle: unknown door state: ${door:-?}" >&2
    exit 1
    ;;
  esac
  ;;
-h | --help | "")
  usage
  exit 0
  ;;
*)
  echo "Unknown command: $cmd" >&2
  usage >&2
  exit 2
  ;;
esac
