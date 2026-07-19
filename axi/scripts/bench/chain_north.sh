#!/usr/bin/env bash
# Wait for the closing driver to fully finish (incl. its restore), then
# launch North as its own self-contained systemd unit (re-frees VRAM).
until ! systemctl --user is-active axi-audit-closing.service >/dev/null 2>&1; do
  sleep 30
done
sleep 20  # let the closing restore settle
systemd-run --user --unit=axi-audit-north --collect \
  --property=WorkingDirectory=/home/hectormr/LifeOS/lifeos/axi \
  /home/hectormr/LifeOS/lifeos/lifeos/.venv/bin/python \
  /home/hectormr/LifeOS/lifeos/axi/scripts/bench/audit_batches.py run \
  --plan /home/hectormr/LifeOS/lifeos/axi/scripts/bench/results/north_plan.json
echo "NORTH_LAUNCHED"
