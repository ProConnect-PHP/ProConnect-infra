#!/usr/bin/env bash
set -eu

cd /opt/proconnect
docker compose -f docker-compose.yml pull
docker compose -f docker-compose.yml up -d
docker image prune -af
