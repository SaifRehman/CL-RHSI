#!/usr/bin/env bash
# Run ON the RHEL VM. Idempotent.
set -euo pipefail
echo "==> [rhel] start setup at $(date -u +%FT%TZ)"

# 1. Tools
if ! command -v podman >/dev/null; then sudo dnf install -y podman; fi
if ! command -v skupper >/dev/null; then
  echo "installing skupper CLI v2.1.1"
  TMP="$(mktemp -d)"
  curl -fLo "$TMP/skupper.tgz" https://github.com/skupperproject/skupper/releases/download/2.1.1/skupper-cli-2.1.1-linux-amd64.tgz
  tar -xzf "$TMP/skupper.tgz" -C "$TMP"
  mkdir -p "$HOME/.local/bin"
  mv "$TMP/skupper" "$HOME/.local/bin/skupper"
  rm -rf "$TMP"
fi
export PATH="$HOME/.local/bin:$PATH"
# Persist PATH on this account (only add once)
grep -q '.local/bin' ~/.bashrc 2>/dev/null || echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc

skupper version

# 2. Enable user systemd lingering so podman survives logout
sudo loginctl enable-linger "$(whoami)" || true

# 3. Pull and run weather (idempotent)
podman pull quay.io/rh-ee-srehman/weather:latest
podman rm -f weather-app 2>/dev/null || true
podman run -d --name weather-app --restart=unless-stopped \
  -p 8080:8080 \
  -e ALLOWED_ORIGIN='https://app.travels.sandbox3259.opentlc.com' \
  quay.io/rh-ee-srehman/weather:latest

# Smoke test
sleep 2
for i in 1 2 3 4 5; do
  if curl -sf http://127.0.0.1:8080/healthz | grep -q '"ok":true'; then break; fi
  sleep 1
done
curl -sf http://127.0.0.1:8080/healthz
echo
echo "==> [rhel] weather container healthy"

# 4. Skupper podman site
export SKUPPER_PLATFORM=podman
mkdir -p "$HOME/.local/share/skupper"

# site create is idempotent (errors gracefully if site exists)
skupper site create cl-rhsi-rhel 2>&1 | tail -5 || true

# Redeem token (idempotent — second time will say "already redeemed" or similar; ignore err)
skupper token redeem ~/cl-rhsi/link-token.yaml 2>&1 | tail -10 || true

# Determine the host IP for the connector target. Prefer podman bridge gateway so
# the router container can reach the weather-app's host-port mapping.
HOSTIP="$(ip -4 addr show podman0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 || true)"
if [ -z "$HOSTIP" ]; then
  HOSTIP="$(hostname -I | awk '{print $1}')"
fi
echo "==> [rhel] HOSTIP=$HOSTIP"

# Create connector resource declaration. routing-key matches the cluster's Listener routingKey.
skupper connector delete weather 2>&1 || true
skupper connector create weather 8080 --routing-key weather --host "$HOSTIP" 2>&1 | tail -5

# Bring up the local system infra + start the router. In v2 podman, site/link/connector
# resources are *declared* by the above commands; `system install`/`system start` is what
# actually deploys the router container and activates the link.
skupper system install 2>&1 | tail -10 || true
# If already started, `start` is a no-op; otherwise it boots the router systemd unit.
skupper system start 2>&1 | tail -20 || true

# If the site was already started before this run, declarations on disk need to be
# (re)applied so the router picks them up.
skupper system reload 2>&1 | tail -20 || true

# Wait briefly for the link to come up
sleep 8

echo
echo "==> [rhel] skupper site status:"
skupper site status || true
echo
echo "==> [rhel] skupper link status:"
skupper link status || true
echo
echo "==> [rhel] skupper connector status:"
skupper connector status || true
echo
echo "==> [rhel] skupper listener status:"
skupper listener status || true

echo "==> [rhel] done"
