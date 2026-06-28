#!/bin/bash
# docker-entrypoint.sh - SERVER (Spring Boot + Netty)
# Convert .env-style environment variables into JVM -D system properties
# so the Spring XML ${...} placeholders can resolve them.
set -e

mkdir -p "${SERVER_LOG_DIR}"

PROPS=""
add_prop() {
    name="$1"
    value="$2"
    if [ -n "$value" ]; then
        PROPS="$PROPS -D$name=$value"
    fi
}

add_prop "server.log.dir"          "${SERVER_LOG_DIR}"
add_prop "mongodb.host"            "${MONGODB_HOST}"
add_prop "mongodb.port"            "${MONGODB_PORT}"
add_prop "mongodb.database"        "${MONGODB_DATABASE}"
add_prop "mongodb.username"        "${MONGODB_USERNAME}"
add_prop "mongodb.password"        "${MONGODB_PASSWORD}"
add_prop "server.port"             "${SERVER_PORT}"
add_prop "server.context-path"     "${SERVER_CONTEXT_PATH}"

exec java $PROPS -jar /app/server.jar
