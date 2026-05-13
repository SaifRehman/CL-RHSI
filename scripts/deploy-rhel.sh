#!/usr/bin/env bash
# Copies rhel/ to the VM and runs setup.sh.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${RHEL_HOST:=rhel.rfztg.sandbox2786.opentlc.com}"
: "${RHEL_USER:=lab-user}"
: "${RHEL_PASS:=MjM4Mjcy}"

if ! command -v sshpass >/dev/null; then
  echo "sshpass required: brew install hudochenkov/sshpass/sshpass" >&2
  exit 1
fi

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

echo ">>> ensuring ~/cl-rhsi exists on $RHEL_USER@$RHEL_HOST"
sshpass -p "$RHEL_PASS" ssh $SSH_OPTS "$RHEL_USER@$RHEL_HOST" "mkdir -p ~/cl-rhsi"

echo ">>> rsync rhel/ to $RHEL_USER@$RHEL_HOST:~/cl-rhsi"
sshpass -p "$RHEL_PASS" rsync -az -e "ssh $SSH_OPTS" "$HERE/rhel/" "$RHEL_USER@$RHEL_HOST:~/cl-rhsi/"

echo ">>> running rhel/setup.sh"
sshpass -p "$RHEL_PASS" ssh $SSH_OPTS "$RHEL_USER@$RHEL_HOST" "bash ~/cl-rhsi/setup.sh"
