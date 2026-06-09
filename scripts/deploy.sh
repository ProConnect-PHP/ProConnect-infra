#!/usr/bin/env bash
set -euo pipefail

APP_DIR=/opt/proconnect

cd "$APP_DIR"

echo "$GHCR_READ_TOKEN" | docker login ghcr.io -u "$GHCR_USERNAME" --password-stdin

docker compose pull
docker compose up -d

docker image prune -af
