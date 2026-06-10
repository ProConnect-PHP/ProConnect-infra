#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/proconnect"
COMPOSE="docker compose -f docker-compose.yml"

cd "$APP_DIR"

if [ ! -f .env ]; then
  echo "ERROR: .env file not found in $APP_DIR"
  exit 1
fi

set -a
source .env
set +a

reload_nginx_container() {
  local container_name="$1"

  if docker ps --format '{{.Names}}' | grep -q "^${container_name}$"; then
    echo "==> Testing nginx config in ${container_name}"

    if ! docker exec "$container_name" nginx -t; then
      echo "ERROR: nginx config test failed in ${container_name}"
      echo "==> Last logs from ${container_name}"
      docker logs --tail=120 "$container_name" || true
      exit 1
    fi

    echo "==> Reloading nginx in ${container_name}"
    docker exec "$container_name" nginx -s reload
  else
    echo "==> ${container_name} not found, skipping nginx reload"
  fi
}

echo "==> Pull images"
$COMPOSE pull

echo "==> Start postgres and redis first"
$COMPOSE up -d postgres redis

echo "==> Wait for PostgreSQL"

MAX_RETRIES=45
RETRY=0

until $COMPOSE exec -T postgres pg_isready -U "$DB_USERNAME" -d "$DB_DATABASE" >/dev/null 2>&1; do
  RETRY=$((RETRY + 1))

  if [ "$RETRY" -ge "$MAX_RETRIES" ]; then
    echo "ERROR: PostgreSQL did not become ready in time"

    echo "==> Postgres status"
    $COMPOSE ps postgres || true

    echo "==> Postgres logs"
    $COMPOSE logs --tail=120 postgres || true

    exit 1
  fi

  echo "Waiting for PostgreSQL... ($RETRY/$MAX_RETRIES)"
  sleep 2
done

echo "==> Run Laravel preparation using one-off containers"

echo "==> Clear Laravel caches"
$COMPOSE run --rm backend php artisan optimize:clear || true

echo "==> Database setup"

if [ "${DB_FRESH_SEED:-false}" = "true" ]; then
  echo "WARNING: DB_FRESH_SEED=true -> running migrate:fresh --force"
  echo "WARNING: This will DROP all tables in database: $DB_DATABASE"
  $COMPOSE run --rm backend php artisan migrate:fresh --force
else
  echo "Running safe migrations"
  $COMPOSE run --rm backend php artisan migrate --force

  if [ "${DB_SEED:-false}" = "true" ]; then
    echo "DB_SEED=true -> running db:seed"
    $COMPOSE run --rm backend php artisan db:seed --force
  fi
fi

echo "==> Storage link"
$COMPOSE run --rm backend php artisan storage:link || true

echo "==> Cache Laravel"
$COMPOSE run --rm backend php artisan config:cache
$COMPOSE run --rm backend php artisan route:cache
$COMPOSE run --rm backend php artisan view:cache

echo "==> Start application stack"
$COMPOSE up -d --remove-orphans

echo "==> Reload nginx containers"
reload_nginx_container "proconnect_nginx"
reload_nginx_container "edge_nginx"

if $COMPOSE config --services | grep -q '^horizon$'; then
  echo "==> Restart Horizon gracefully"
  $COMPOSE run --rm backend php artisan horizon:terminate || true
  $COMPOSE restart horizon || true
fi

if $COMPOSE config --services | grep -q '^scheduler$'; then
  echo "==> Restart scheduler"
  $COMPOSE restart scheduler || true
fi

echo "==> Containers status"
$COMPOSE ps

echo "==> Internal health checks"

if docker ps --format '{{.Names}}' | grep -q '^proconnect_nginx$'; then
  echo "==> Checking frontend upstream from proconnect_nginx"
  docker exec proconnect_nginx sh -lc "wget -qO- http://frontend:4000 >/dev/null" || {
    echo "WARNING: frontend upstream check failed from proconnect_nginx"
  }

  echo "==> Checking backend upstream from proconnect_nginx"
  docker exec proconnect_nginx sh -lc "wget -qO- http://backend:8080 >/dev/null" || {
    echo "WARNING: backend upstream check failed from proconnect_nginx"
  }

  if $COMPOSE config --services | grep -q '^livekit$'; then
    echo "==> Checking livekit upstream from proconnect_nginx"
    docker exec proconnect_nginx sh -lc "wget -qO- http://livekit:7880 >/dev/null" || {
      echo "WARNING: livekit upstream check failed from proconnect_nginx"
    }
  fi
fi

echo "==> Cleanup old images"
docker image prune -f

echo "==> Deploy finished"
