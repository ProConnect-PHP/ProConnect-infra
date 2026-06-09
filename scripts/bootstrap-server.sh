#!/usr/bin/env bash

# Correr una vez en el servidor destino

set -euo pipefail

APP_DIR=/opt/proconnect

sudo mkdir -p "$APP_DIR"
sudo chown -R "$USER":"$USER" "$APP_DIR"

if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
  sudo usermod -aG docker "$USER"
fi

if ! docker compose version >/dev/null 2>&1; then
  echo "docker compose plugin missing"
  exit 1
fi

mkdir -p "$APP_DIR/nginx"
mkdir -p "$APP_DIR/scripts"

echo "server ready -> $APP_DIR"
