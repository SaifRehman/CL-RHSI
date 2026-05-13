#!/usr/bin/env bash
# Runs the full demo policy assertion sequence.
set -euo pipefail
TODO="https://todo.travels.sandbox3259.opentlc.com"
WEATHER="https://weather.travels.sandbox3259.opentlc.com"

KEY_FREE=$(oc -n kuadrant-system get secret api-key-free -o jsonpath='{.data.api_key}' | base64 -d)
KEY_PREMIUM=$(oc -n kuadrant-system get secret api-key-premium -o jsonpath='{.data.api_key}' | base64 -d)

pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; exit 1; }

assert_code() {
  local expected="$1"; shift
  local got
  got=$(curl -sk -o /dev/null -w "%{http_code}" "$@")
  [ "$got" = "$expected" ] || { echo "  expected $expected, got $got for: $*"; return 1; }
}

echo "==> A. Anonymous request to todo -> 401"
assert_code 401 "$TODO/api/todos" && pass "401 without API key on /api/todos" || fail "anon not blocked"

# Drain any residual counter from previous calls
echo "==> waiting 65s for any prior free-tier counter window to reset"
sleep 65

echo "==> B. Free key -> 5x 200 then 2x 429 within 1 minute"
ok_count=0; limit_count=0
for i in $(seq 1 7); do
  code=$(curl -sk -o /dev/null -w "%{http_code}" -H "Authorization: APIKEY $KEY_FREE" "$TODO/api/todos")
  if [ "$code" = "200" ]; then ok_count=$((ok_count+1)); fi
  if [ "$code" = "429" ]; then limit_count=$((limit_count+1)); fi
  sleep 0.1
done
[ "$ok_count" = "5" ] && [ "$limit_count" = "2" ] && pass "free tier: 5x 200, 2x 429" || fail "free tier counts: 200=$ok_count 429=$limit_count"

echo "==> C. Wait 65s for free window to reset"
sleep 65

echo "==> D. Premium key -> 30x 200 within 1 minute"
ok_count=0
for i in $(seq 1 30); do
  code=$(curl -sk -o /dev/null -w "%{http_code}" -H "Authorization: APIKEY $KEY_PREMIUM" "$TODO/api/todos")
  [ "$code" = "200" ] && ok_count=$((ok_count+1))
  sleep 0.1
done
[ "$ok_count" = "30" ] && pass "premium tier: 30x 200" || fail "premium tier: only $ok_count succeeded"

echo "==> E. Weather IP rate-limit (10/min): 12 calls -> >=10x 200, >=1x 429"
sleep 65
ok=0; lim=0
for i in $(seq 1 12); do
  code=$(curl -sk -o /dev/null -w "%{http_code}" -H "Authorization: APIKEY $KEY_FREE" "$WEATHER/current?city=Berlin")
  [ "$code" = "200" ] && ok=$((ok+1))
  [ "$code" = "429" ] && lim=$((lim+1))
  sleep 0.1
done
[ "$ok" -ge "10" ] && [ "$lim" -ge "1" ] && pass "weather rate-limit: 200=$ok 429=$lim" || fail "weather counts: 200=$ok 429=$lim"

echo
echo "ALL CHECKS PASS"
