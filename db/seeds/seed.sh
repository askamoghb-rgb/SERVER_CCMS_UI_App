#!/bin/bash
# db/seeds/seed.sh
# Orchestrator for first-run database seeding.
# Runs inside the 'seed' compose service. Exits 0 on success.
#
# NOTE: must run under bash (not sh) because the mongo:3.4 image
# ships busybox sh which does not support /dev/tcp/* for the
# wait_for() helper.
set -e

MONGO_HOST="${MONGO_HOST:-mongodb}"
MONGO_PORT="${MONGO_PORT:-27017}"
MYSQL_HOST="${MYSQL_HOST:-mysql}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:?MYSQL_ROOT_PASSWORD is required}"
MYSQL_DATABASE="${MYSQL_DATABASE:-employee_db}"
SEED_DATA="${SEED_DATA:-true}"

SEEDS_DIR="/seeds"
MONGO_ARCHIVE="${SEEDS_DIR}/mongo.archive"
MYSQL_SCHEMA="${SEEDS_DIR}/mysql/01-schema.sql"

red()   { printf "\033[31m%s\033[0m\n" "$*"; }
green() { printf "\033[32m%s\033[0m\n" "$*"; }
blue()  { printf "\033[34m%s\033[0m\n" "$*"; }

wait_for() {
    host="$1"
    port="$2"
    name="$3"
    i=0
    blue "Waiting for $name at $host:$port ..."
    # Use bash's /dev/tcp (busybox sh does not support this).
    while ! (echo > "/dev/tcp/${host}/${port}") 2>/dev/null; do
        i=$((i + 1))
        if [ "$i" -gt 60 ]; then
            red "Timed out waiting for $name at $host:$port after 60s"
            exit 1
        fi
        sleep 1
    done
    green "  $name is up"
}

if [ "$SEED_DATA" != "true" ]; then
    blue "SEED_DATA=$SEED_DATA - skipping seed"
    exit 0
fi

wait_for "$MONGO_HOST" "$MONGO_PORT" "MongoDB"
wait_for "$MYSQL_HOST" "$MYSQL_PORT" "MySQL"

# --- MongoDB ---
if [ -f "$MONGO_ARCHIVE" ]; then
    blue "Restoring MongoDB from $MONGO_ARCHIVE ..."
    if mongorestore \
        --host="${MONGO_HOST}" \
        --port="${MONGO_PORT}" \
        --archive="$MONGO_ARCHIVE" \
        --drop \
        --quiet \
        --nsInclude='ccms.*'; then
        green "  MongoDB restore complete"
    else
        red "  MongoDB restore FAILED"
        exit 1
    fi
else
    red "MongoDB archive not found at $MONGO_ARCHIVE - skipping"
fi

# --- MySQL ---
if [ -f "$MYSQL_SCHEMA" ]; then
    blue "Applying MySQL schema from $MYSQL_SCHEMA ..."
    out=$(mysql \
        -h "$MYSQL_HOST" \
        -P "$MYSQL_PORT" \
        -u root \
        -p"${MYSQL_ROOT_PASSWORD}" \
        "$MYSQL_DATABASE" < "$MYSQL_SCHEMA" 2>&1 || true)
    if echo "$out" | grep -qiE "^ERROR "; then
        red "  MySQL schema apply FAILED:"
        echo "$out" | sed 's/^/    /'
        exit 1
    fi
    green "  MySQL schema applied"
else
    blue "No MySQL schema at $MYSQL_SCHEMA - skipping"
fi

green ""
green "============================================"
green "  CCMS seed complete"
green "============================================"
green ""
