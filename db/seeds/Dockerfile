FROM alpine:3.18

# Install both clients in one layer.
#   - mysql-client: for applying the MySQL schema
#   - mongodb-tools: for mongorestore (not bundled in the mongo:3.4 official image we used previously)
# Use bash for /dev/tcp support in the seed.sh wait_for helper.
RUN apk add --no-cache \
        bash \
        mysql-client \
        mongodb-tools

WORKDIR /

COPY seed.sh /seed.sh
RUN chmod +x /seed.sh

ENTRYPOINT ["/seed.sh"]
