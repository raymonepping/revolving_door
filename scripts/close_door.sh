#!/usr/bin/env bash
set -euo pipefail

NS="default"
CJ="door-close"
JOB="door-close-$(date +%s)"
URL="http://demo.local:18200/api"

# fast-path: already in desired state
if curl -sS "$URL" | grep -q "\"door\": \"locked\""; then
  echo "✅ already locked"
  exit 0
fi

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
    # fallback for machines without python3
    printf "%s" "$body" | tr -d '\n' | sed 's/[{}]//g' | tr ',' '\n' |
      sed 's/^ *"//; s/" *$//; s/" *: *"/=/; s/" *: */=/' |
      awk -F= -v k="$field" '$1==k{print $2; exit}'
  fi
}

http_get() {
  local tmp
  tmp="$(mktemp)"
  local code
  code="$(curl -sS -o "$tmp" -w '%{http_code}' "$URL" || true)"
  printf "%s\n" "$code"
  cat "$tmp" || true
  rm -f "$tmp"
}

wait_for_door() {
  local want="$1" tries="${2:-80}" sleep_s="${3:-0.25}"

  for i in $(seq 1 "$tries"); do
    local resp code body door reason
    resp="$(http_get)"
    code="$(printf "%s" "$resp" | head -n 1 | tr -d '\r')"
    body="$(printf "%s" "$resp" | tail -n +2)"

    door="$(json_field "door" "$body")"
    reason="$(json_field "reason" "$body")"

    if [ -z "$door" ]; then
      printf "%02d  http=%s  door=?  body=%s\n" \
        "$i" "${code:-?}" "$(printf "%s" "$body" | tr '\n' ' ' | head -c 120)"
    else
      printf "%02d  http=%s  door=%s reason=%s\n" \
        "$i" "${code:-?}" "$door" "${reason:-}"
    fi

    if [ "$door" = "$want" ]; then
      echo
      echo "✅ reached door=$want"
      echo "$body"
      return 0
    fi

    sleep "$sleep_s"
  done

  echo
  echo "❌ timed out waiting for door=$want"
  curl -sS "$URL" || true
  return 1
}

kubectl -n "$NS" create job --from=cronjob/"$CJ" "$JOB" >/dev/null

cleanup() { kubectl -n "$NS" delete job "$JOB" --ignore-not-found >/dev/null 2>&1 || true; }
trap cleanup EXIT

kubectl -n "$NS" wait --for=condition=complete job/"$JOB" --timeout=180s

echo
kubectl -n "$NS" logs job/"$JOB" -c vault-close || true
kubectl -n "$NS" logs job/"$JOB" -c restart || true
kubectl -n "$NS" logs job/"$JOB" -c status || true
echo

wait_for_door "locked"
