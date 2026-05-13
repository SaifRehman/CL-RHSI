#!/usr/bin/env bash
# Tear down the CL-RHSI demo.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "=== delete cluster policies, routes, manifests ==="
oc delete -f "$HERE/manifests/60-policies/" --ignore-not-found
oc delete -f "$HERE/manifests/50-routes/" --ignore-not-found
oc delete -f "$HERE/manifests/40-weather-skupper/" --ignore-not-found
oc delete -f "$HERE/manifests/30-frontend/" --ignore-not-found
oc -n demo-frontend delete configmap frontend-static --ignore-not-found
oc delete -f "$HERE/manifests/20-todo/" --ignore-not-found
oc delete -f "$HERE/manifests/10-db/" --ignore-not-found
oc delete -f "$HERE/manifests/00-namespaces.yaml" --ignore-not-found

echo "=== teardown on RHEL ==="
: "${RHEL_HOST:=rhel.rfztg.sandbox2786.opentlc.com}"
: "${RHEL_USER:=lab-user}"
: "${RHEL_PASS:=MjM4Mjcy}"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
if command -v sshpass >/dev/null; then
  sshpass -p "$RHEL_PASS" ssh $SSH_OPTS "$RHEL_USER@$RHEL_HOST" '
    export PATH="$HOME/.local/bin:$PATH"
    podman rm -f weather-app 2>/dev/null || true
    # Tear down skupper podman site (v2)
    skupper system stop 2>/dev/null || true
    skupper system uninstall --force 2>/dev/null || true
    rm -rf ~/cl-rhsi ~/.local/share/skupper
  '
else
  echo "sshpass not installed - skipping RHEL teardown; run manually:"
  echo "  ssh lab-user@rhel.rfztg.sandbox2786.opentlc.com"
  echo "  podman rm -f weather-app; skupper system stop; skupper system uninstall --force"
  echo "  rm -rf ~/cl-rhsi ~/.local/share/skupper"
fi

rm -f "$HERE/rhel/link-token.yaml"
echo "done."
