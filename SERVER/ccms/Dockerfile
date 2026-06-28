FROM maven:3-eclipse-temurin-8 AS builder

WORKDIR /build
COPY pom.xml .
COPY src src/
RUN mvn clean package -DskipTests

FROM eclipse-temurin:8-jre-alpine

RUN apk add --no-cache bash

RUN mkdir -p /home/CCMS/roadmap/conf/
COPY conf/applicationContext-docker.xml /home/CCMS/roadmap/conf/applicationContext.xml
COPY conf/log4j2.properties /home/CCMS/roadmap/conf/
COPY conf/netty-server.properties /home/CCMS/roadmap/conf/

COPY --from=builder /build/target/spring-boot-mongodb-0.0.1-SNAPSHOT.jar /app/server.jar

EXPOSE 8102 9100

ENV SERVER_LOG_DIR=/home/CCMS/roadmap/logs \
    MONGODB_HOST=mongodb \
    MONGODB_PORT=27017 \
    MONGODB_DATABASE=ccms \
    SERVER_PORT=8102 \
    SERVER_CONTEXT_PATH=/user

# entrypoint.sh converts .env-derived environment variables to JVM -D system
# properties so the Spring XML ${...} placeholders resolve them.
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
