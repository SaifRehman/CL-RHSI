#!/usr/bin/env bash
# Deploy everything to OpenShift in dependency order.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

DOMAIN="travels.sandbox3259.opentlc.com"
TODO_URL="https://todo.${DOMAIN}"
WEATHER_URL="https://weather.${DOMAIN}"

step() { echo; echo "=== $* ==="; }

step "00 namespaces"
oc apply -f "$HERE/manifests/00-namespaces.yaml"

step "10 postgres"
oc apply -f "$HERE/manifests/10-db/"
oc -n demo-db rollout status deploy/postgres --timeout=240s

step "20 todo backend"
oc apply -f "$HERE/manifests/20-todo/"
oc -n demo-todo rollout status deploy/todo-backend --timeout=240s

step "40 skupper site + listener + grant"
oc apply -f "$HERE/manifests/40-weather-skupper/"
oc -n demo-weather wait --for=condition=Ready site/demo-weather --timeout=240s
oc -n demo-weather wait --for=condition=Resolved accessgrant/weather-grant --timeout=120s 2>&1 || \
  oc -n demo-weather wait --for=condition=Ready accessgrant/weather-grant --timeout=60s

step "extract AccessToken for RHEL"
URL=$(oc -n demo-weather get accessgrant weather-grant -o jsonpath='{.status.url}')
CODE=$(oc -n demo-weather get accessgrant weather-grant -o jsonpath='{.status.code}')
CA=$(oc -n demo-weather get accessgrant weather-grant -o jsonpath='{.status.ca}')
{
  echo "apiVersion: skupper.io/v2alpha1"
  echo "kind: AccessToken"
  echo "metadata:"
  echo "  name: link-to-cluster"
  echo "spec:"
  echo "  url: ${URL}"
  echo "  code: ${CODE}"
  echo "  ca: |"
  echo "${CA}" | sed 's/^/    /'
} > "$HERE/rhel/link-token.yaml"
echo "wrote $HERE/rhel/link-token.yaml"

step "60 api-key secrets"
oc apply -f "$HERE/manifests/60-policies/01-api-keys.yaml"

step "render frontend configmap with real api keys"
KEY_FREE=$(oc -n kuadrant-system get secret api-key-free -o jsonpath='{.data.api_key}' | base64 -d)
KEY_PREMIUM=$(oc -n kuadrant-system get secret api-key-premium -o jsonpath='{.data.api_key}' | base64 -d)
CFG=$(mktemp)
cp "$HERE/apps/frontend/config.js.template" "$CFG"
# Use a delimiter that won't appear in URLs
sed -i.bak "s|__TODO_URL__|${TODO_URL}|g; s|__WEATHER_URL__|${WEATHER_URL}|g; s|__KEY_FREE__|${KEY_FREE}|g; s|__KEY_PREMIUM__|${KEY_PREMIUM}|g" "$CFG"
rm -f "${CFG}.bak"

oc -n demo-frontend create configmap frontend-static \
  --from-file=index.html="$HERE/apps/frontend/index.html" \
  --from-file=style.css="$HERE/apps/frontend/style.css" \
  --from-file=app.js="$HERE/apps/frontend/app.js" \
  --from-file=config.js="$CFG" \
  --dry-run=client -o yaml | oc apply -f -
rm -f "$CFG"

step "30 frontend deployment + service"
oc apply -f "$HERE/manifests/30-frontend/02-deployment.yaml" -f "$HERE/manifests/30-frontend/03-service.yaml"
# Restart so the new ConfigMap is picked up (in case it changed)
oc -n demo-frontend rollout restart deploy/frontend 2>/dev/null || true
oc -n demo-frontend rollout status deploy/frontend --timeout=180s

step "50 reference grants + httproutes"
oc apply -f "$HERE/manifests/50-routes/"

step "60 auth + rate-limit policies"
oc apply -f "$HERE/manifests/60-policies/02-todo-auth.yaml"
oc apply -f "$HERE/manifests/60-policies/03-todo-ratelimit.yaml"
oc apply -f "$HERE/manifests/60-policies/04-weather-auth.yaml"
oc apply -f "$HERE/manifests/60-policies/05-weather-ratelimit.yaml"

step "wait for policies enforced"
for ns in demo-todo demo-weather; do
  oc -n "$ns" wait --for=condition=Enforced authpolicy --all --timeout=180s
  oc -n "$ns" wait --for=condition=Enforced ratelimitpolicy --all --timeout=180s
done

step "summary"
oc get httproute -A | grep -E 'NAMESPACE|demo-'
oc get authpolicy -A
oc get ratelimitpolicy -A

echo
echo "Frontend:  https://app.${DOMAIN}"
echo "Todo API:  https://todo.${DOMAIN}"
echo "Weather:   https://weather.${DOMAIN}"
echo
echo "Run RHEL setup next:  ./scripts/deploy-rhel.sh"
