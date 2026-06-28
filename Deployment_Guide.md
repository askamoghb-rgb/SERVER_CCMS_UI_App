# CCMS Deployment Guide

## Environment Configuration (`.env`)

All runtime secrets and host/port/database configuration live in a single file
at the project root: **`.env`**. This file is **gitignored**. A template with
all required keys is provided as **`.env.example`** and IS committed.

```bash
cp .env.example .env
# then edit .env and set real values
```

`docker-compose.yml` reads `.env` automatically (via `env_file:` and `${VAR}`
substitution). The Spring XML configs read environment values through JVM
`-D` system properties injected by the service `ENTRYPOINT` scripts:

- `SERVER/ccms/Dockerfile` injects `-Dserver.log.dir=...` for log4j2
- `CCMS_UI/STARTUP/ccms_ui/docker-entrypoint.sh` injects `-Dmongodb.*`,
  `-Dmysql.*`, `-Dccms.server.host`, etc., so Spring's
  `<context:property-placeholder>` resolves them
- `nginx/docker-entrypoint.sh` runs `envsubst` against
  `nginx.conf.template` to render `nginx.conf` with `PUBLIC_DOMAIN` and
  `LETSENCRYPT_LIVE_DIR`

### Key reference

| Variable | Default | Used by | Purpose |
|---|---|---|---|
| `MYSQL_ROOT_PASSWORD` | `root` | MySQL container, UI Spring config, scripts | MySQL root password |
| `MYSQL_DATABASE` | `employee_db` | MySQL container, UI Spring config, scripts | MySQL schema name |
| `MONGODB_DATABASE` | `ccms` | SERVER + UI Spring configs | MongoDB database name |
| `MONGODB_HOST` | `mongodb` | SERVER + UI Spring configs | MongoDB service hostname |
| `MONGODB_PORT` | `27017` | SERVER + UI Spring configs | MongoDB port |
| `MONGODB_USERNAME` | (empty) | UI Spring config | Optional MongoDB auth user |
| `MONGODB_PASSWORD` | (empty) | UI Spring config | Optional MongoDB auth password |
| `SERVER_PORT` | `8102` | SERVER, docker-compose | Spring Boot HTTP port |
| `NETTY_PORT` | `9100` | SERVER, docker-compose | Netty TCP port for DCUs |
| `SERVER_CONTEXT_PATH` | `/user` | SERVER | Spring context path |
| `TOMCAT_PORT` | `8080` | CCMS_UI, docker-compose | Tomcat port |
| `APP_CONTEXT` | `/CCMS` | CCMS_UI | WAR context path |
| `CCMS_SERVER_HOST` | `server` | CCMS_UI | SERVER hostname (Docker DNS) |
| `BACKEND_HTTP_PORT` | `8102` | CCMS_UI | SERVER HTTP port (UI → SERVER) |
| `BACKEND_HTTP_CONTEXT` | `/user` | CCMS_UI | SERVER context path |
| `SMOKE_ADMIN_EMAIL` | – | `scripts/api-smoke-test.sh` | Test admin login |
| `SMOKE_ADMIN_PASSWORD` | – | `scripts/api-smoke-test.sh` | Test admin password |
| `PUBLIC_DOMAIN` | `ccms.yourdomain.com` | nginx | Public hostname (SSL cert) |
| `LETSENCRYPT_LIVE_DIR` | `/etc/letsencrypt/live/ccms.yourdomain.com` | nginx | Let's Encrypt cert path |
| `SERVER_LOG_DIR` | `/home/CCMS/roadmap/logs` | SERVER, log4j2 | SERVER log directory |
| `SEED_DATA` | `true` | `seed` service, `mysql` | Whether to auto-seed databases on first start |

> Never commit `.env`. Only `.env.example` is tracked.

---

## First-Run Setup (Seed Data)

On a fresh clone, the MySQL and MongoDB containers start empty. The
`seed` service in `docker-compose.yml` automatically populates them
from files committed under `db/seeds/`.

### What gets seeded

| Source | Target | Contents |
|---|---|---|
| `db/seeds/mongo.archive` | MongoDB `ccms` database | Full snapshot: 21 collections (users, DCUs, events, meter data, scheduler configurations, handshake info, etc.) — 4 MB compressed, ~95 MB uncompressed |
| `db/seeds/mysql/01-schema.sql` | MySQL `employee_db` | A `ccms_meta` marker table (the app uses MongoDB for all data; see the file's header for context) |
| `./data/dontdelete/` | `ccms_ui` container `/home/data/dontdelete/` | (Empty by default — drop CSVs in this directory before `docker compose up` if needed) |

### The seed flow

```
docker compose up -d --build
   ├── builds 3 images (server, ccms_ui, nginx)  — first run: 5–10 min
   ├── starts mongodb + mysql (with healthchecks)
   ├── starts seed container
   │      ├── waits for mongodb:27017 and mysql:3306
   │      ├── runs `mongorestore` from /seeds/mongo.archive
   │      └── applies /seeds/mysql/01-schema.sql
   ├── on seed exit 0:
   │      ├── starts server  (waits for mongodb + seed)
   │      └── starts ccms_ui (waits for mongodb + mysql + server + seed)
   └── starts nginx
```

The `seed` container has `restart: "no"`, so it runs once on first
start and exits. Subsequent `docker compose up` runs skip the seed
(but the data volumes persist).

### Disabling seeding

Set `SEED_DATA=false` in `.env`. The `seed` container will exit 0
without touching the databases — useful when you want to start with
an empty MongoDB or restore from your own backup.

### Re-seeding from scratch

To wipe the volumes and re-run the seed:

```bash
docker compose down -v         # removes all named + anonymous volumes (mongodb, mysql data)
docker compose up -d --build   # seed runs again because volumes are now empty
```

### Regenerating the seed archive (maintainers only)

If you change the live data and want to update the committed seed:

```bash
docker exec cspl-mongodb \
    mongodump --db ccms --archive --gzip > db/seeds/mongo.archive
git add db/seeds/mongo.archive
git commit -m "Update MongoDB seed snapshot"
```

---

## System Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                      Docker Network (cspl_default)               │
│                                                                   │
│  ┌──────────────┐    TCP :9100    ┌──────────────────┐           │
│  │  IoT Devices  ├───────────────►│  SERVER (Netty)   │           │
│  │  (DCUs)       │                │  + Spring Boot    │           │
│  └──────────────┘                │  container: cspl-server  │   │
│                                   └─────────┬──────────┘           │
│                                             │ REST :8102           │
│                                   ┌─────────▼──────────┐           │
│                                   │  CCMS_UI (Tomcat)   │           │
│                                   │  container: cspl-ccms-ui │     │
│                                   └──┬──────┬──────┬───┘           │
│                                      │      │      │               │
│                              ┌───────▼┐ ┌───▼────┐ ┌▼──────────┐  │
│                              │ MySQL  │ │ MongoDB│ │ Redis     │  │
│                              │:3306   │ │:27017  │ │:6379      │  │
│                              └────────┘ └────────┘ └───────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

| Component | Port | Technology | Container Name |
|---|---|---|---|
| CCMS_UI | 8080 | Tomcat 7 + Spring MVC + AngularJS 1.x | `cspl-ccms-ui` |
| SERVER | 8102 (REST), 9100 (TCP) | Spring Boot 1.5.9 + Netty | `cspl-server` |
| MySQL | 3306 | MySQL 5.7 | `cspl-mysql` |
| MongoDB | 27017 | MongoDB 3.4 | `cspl-mongodb` |

---

## Prerequisites

- **Java**: JDK 7 (for CCMS_UI) and JDK 8 (for SERVER)
- **Maven**: 3.x
- **Docker & Docker Compose**: for containerized deployment
- **Tomcat 7+**: for local CCMS_UI deployment
- **MySQL 5.7+**
- **MongoDB 3.4+**

---

## Configuration: The `ccms.server.host` Setting

The CCMS_UI communicates with the SERVER via REST calls. The server host is configured through the `ccms.server.host` property, which is externalized via `.env`.

| Deployment Mode | `ccms.server.host` value | Why |
|---|---|---|
| **Local (non-Docker)** | `localhost` | SERVER runs on the same machine |
| **Docker Compose** | `server` | Docker Compose service name — resolved via internal Docker DNS |
| **Production** | `<server-ip-or-domain>` | Actual IP/DNS of the production server |

Override the default by setting `CCMS_SERVER_HOST` in `.env`.

### How it works

1. **Default value** is in `CCMS_UI/STARTUP/ccms_ui/src/main/resources/application.properties`:
   ```properties
   ccms.server.host=${ccms.server.host:localhost}
   ```

2. **For Docker**, `docker-compose.yml` reads `CCMS_SERVER_HOST` from `.env` and the `docker-entrypoint.sh` converts it to a `-Dccms.server.host=...` system property. No edits to `application.properties` are needed.

3. **For production**, set `CCMS_SERVER_HOST=<your-host>` in `.env` and rebuild.

### File locations

| File | Purpose |
|---|---|
| `.env` (gitignored) | All runtime secrets and env-specific config |
| `.env.example` (committed) | Template showing required keys |
| `CCMS_UI/.../src/main/resources/application.properties` | Default config (bundled in WAR) |
| `CCMS_UI/.../conf/spring-config-docker.xml` | Docker Spring config (activates property placeholder) |
| `CCMS_UI/.../src/main/webapp/WEB-INF/spring-config.xml` | Local Spring config (activates property placeholder) |
| `CCMS_UI/.../DeviceConfigurationController.java` | Reads `ccms.server.host` via `@Value` |
| `CCMS_UI/.../docker-entrypoint.sh` | Converts `.env` env vars → `-D` JVM system properties |
| `docker-compose.yml` | Reads `.env` and passes env vars to each service |

---

## Local Deployment

### 1. Database Setup

Start MySQL and MongoDB. Using Docker for databases only:

```bash
docker compose up -d mysql mongodb
```

Verify databases are reachable:
```bash
docker compose exec mysql mysql -u root -proot -e "SHOW DATABASES;"
docker compose exec mongodb mongo --eval "db.adminCommand('ping')"
```

### 2. Build and Run the SERVER

```bash
cd SERVER/ccms
mvn clean package -DskipTests
java -jar target/spring-boot-mongodb-0.0.1-SNAPSHOT.jar
```

The SERVER starts on port `8102` (REST) and `9100` (TCP/Netty).

### 3. Build and Deploy CCMS_UI

```bash
cd CCMS_UI/STARTUP/ccms_ui
mvn clean package -DskipTests
```

This produces `target/CCMS.war`. Deploy it to Tomcat:

```bash
# Copy WAR to Tomcat's webapps directory
cp target/CCMS.war /path/to/tomcat/webapps/

# Start Tomcat
/path/to/tomcat/bin/startup.sh
```

The CCMS_UI is available at `http://localhost:8080/CCMS/`.

### 4. Verify

```bash
# Check CCMS_UI loads
curl -s http://localhost:8080/CCMS/ | head -5

# Check SERVER REST API
curl -s http://localhost:8102/user/push/hafe_open_connections
```

---

## Docker Deployment

### 1. Build and Start All Services

```bash
docker compose build
docker compose up -d
```

### 2. Access the Application

| URL | Service |
|---|---|
| `http://localhost:8080/CCMS/` | CCMS_UI web app |
| `http://localhost:8102/user/push/...` | SERVER REST API |

### 3. Useful Commands

```bash
# View logs
docker compose logs -f ccms_ui
docker compose logs -f server

# Rebuild a single service
docker compose build ccms_ui
docker compose up -d ccms_ui

# Access MySQL
docker compose exec mysql mysql -u root -p employee_db

# Access MongoDB
docker compose exec mongodb mongo ccms

# Stop everything
docker compose down
```

### 4. Docker Networking

Containers communicate via Docker Compose's internal network using service names:

| From | To | Hostname |
|---|---|---|
| CCMS_UI | SERVER | `server` |
| CCMS_UI | MySQL | `mysql` |
| CCMS_UI | MongoDB | `mongodb` |
| SERVER | MongoDB | `mongodb` |

---

## Deployment + Subdomain + SSL for CCMS_UI

This section covers exposing CCMS_UI securely over HTTPS via a subdomain, using **nginx** as a reverse proxy with automatic SSL certificates from Let's Encrypt.

### Architecture

```
                            Firewall
                         ┌──────────┐
Internet ──:443 (HTLS)──►│  :443    │──► nginx ──► http://ccms_ui:8080/CCMS/
Internet ──:80  (HTTP)──►│  :80     │──► nginx ──► redirect to :443
Internet ──:9100 (TCP)──►│  :9100   │──► SERVER (direct, for DCUs)
                         │  :8080   │── (blocked — internal only)
                         │  :8102   │── (blocked — internal only)
                         │  :3306   │── (blocked — internal only)
                         │  :27017  │── (blocked — internal only)
                         └──────────┘
```

| Component | Role |
|---|---|
| **nginx** | SSL termination, reverse proxy to Tomcat, HTTP→HTTPS redirect |
| **CCMS_UI** | Tomcat on port 8080 — no longer exposed directly to the internet |
| **SERVER** | Unchanged — DCUs still connect via TCP:9100 |

### 1. DNS Setup

At your domain registrar, add an **A record**:

| Record | Type | Value |
|---|---|---|
| `ccms` | A | `<your-server-public-ip>` |

This makes `https://ccms.yourdomain.com` resolve to your server. DNS propagation may take a few minutes to a few hours.

### 2. Firewall Configuration

Only the minimum required ports should be open to the public:

| Port | Protocol | Public | Purpose |
|---|---|---|---|
| 80 | TCP | ✅ | HTTP → redirect to HTTPS |
| 443 | TCP | ✅ | HTTPS → CCMS_UI web dashboard |
| 9100 | TCP | ✅ | DCU device connections (TCP) |
| 8080 | TCP | ❌ | Tomcat — internal only (nginx proxies to it) |
| 8102 | TCP | ❌ | SERVER REST — internal only |
| 3306 | TCP | ❌ | MySQL — internal only |
| 27017 | TCP | ❌ | MongoDB — internal only |
| 22 | TCP | ✅ (optional) | SSH access to the server |

Example using `ufw`:

```bash
ufw allow 22/tcp          # SSH
ufw allow 80/tcp           # HTTP
ufw allow 443/tcp          # HTTPS
ufw allow 9100/tcp         # DCU TCP connections
ufw deny 8080              # block direct Tomcat access
ufw deny 8102              # block direct SERVER REST access
ufw deny 3306              # block direct MySQL access
ufw deny 27017             # block direct MongoDB access
ufw enable
```

### 3. Nginx Reverse Proxy

The nginx container is already wired into `docker-compose.yml`. The domain and
Let's Encrypt paths are templated via `nginx.conf.template` and rendered at
container start by `nginx/docker-entrypoint.sh` using `envsubst`. To deploy
under a new domain, simply set `PUBLIC_DOMAIN` and `LETSENCRYPT_LIVE_DIR` in
`.env` — no source edits required.

#### Files involved

| File | Purpose |
|---|---|
| `nginx/Dockerfile` | Builds the nginx container (alpine + certbot + entrypoint) |
| `nginx/docker-entrypoint.sh` | Runs `envsubst` to render `nginx.conf` from the template |
| `nginx/nginx.conf.template` | Template with `${PUBLIC_DOMAIN}` and `${LETSENCRYPT_LIVE_DIR}` |

**`nginx/Dockerfile`**:

```dockerfile
FROM nginx:alpine
RUN apk add --no-cache certbot certbot-nginx
EXPOSE 80 443
COPY nginx.conf.template /etc/nginx/nginx.conf.template
COPY docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh
ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["nginx", "-g", "daemon off;"]
```

**`nginx/docker-entrypoint.sh`**:

```sh
#!/bin/sh
set -e
: "${PUBLIC_DOMAIN:=ccms.example.com}"
: "${LETSENCRYPT_LIVE_DIR:=/etc/letsencrypt/live/ccms.example.com}"
export PUBLIC_DOMAIN LETSENCRYPT_LIVE_DIR
envsubst '${PUBLIC_DOMAIN} ${LETSENCRYPT_LIVE_DIR}' \
    < /etc/nginx/nginx.conf.template \
    > /etc/nginx/nginx.conf
exec "$@"
```

**`nginx/nginx.conf.template`**:

```nginx
events {}

http {
    upstream ccms_ui {
        server ccms_ui:8080;
    }

    server {
        listen 80;
        server_name ${PUBLIC_DOMAIN};

        location / {
            return 301 https://$host$request_uri;
        }
    }

    server {
        listen 443 ssl;
        server_name ${PUBLIC_DOMAIN};

        ssl_certificate     ${LETSENCRYPT_LIVE_DIR}/fullchain.pem;
        ssl_certificate_key ${LETSENCRYPT_LIVE_DIR}/privkey.pem;

        location / {
            proxy_pass http://ccms_ui/CCMS/;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
        }
    }
}
```

#### Docker Compose updates

Add the nginx service and remove the public 8080 exposure from CCMS_UI:

```yaml
services:
  # ... existing mongodb, mysql, server services unchanged ...

  ccms_ui:
    # ... existing config, but remove "8080:8080" from ports ...
    ports: []            # not exposed publicly — only accessible via internal Docker network

  nginx:
    build:
      context: ./nginx
    container_name: cspl-nginx
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - letsencrypt_data:/etc/letsencrypt
    depends_on:
      - ccms_ui
    restart: unless-stopped

volumes:
  mongodb_data:
  mysql_data:
  letsencrypt_data:     # persist SSL certificates across restarts
```

The `ccms_ui` container remains reachable internally at `http://ccms_ui:8080` — nginx uses this to forward requests.

#### SSL certificate setup

```bash
# 1. Start all services (nginx starts with HTTP-only initially)
docker compose up -d

# 2. Obtain the SSL certificate (one-time)
docker compose exec nginx certbot --nginx -d ccms.yourdomain.com

# 3. Follow the interactive prompts (email, agree to terms, etc.)
#    certbot will modify nginx.conf to enable SSL automatically

# 4. Verify auto-renewal
docker compose exec nginx certbot renew --dry-run
```

Certbot sets up a system timer for auto-renewal. Certificates are valid for 90 days and renew automatically.

### 4. Verification

```bash
# Check the HTTPS endpoint
curl -I https://ccms.yourdomain.com

# Check SSL certificate details
curl -vI https://ccms.yourdomain.com 2>&1 | grep -i "ssl\|certificate"

# Open in browser
echo "https://ccms.yourdomain.com"
```

You should see:
- A valid padlock icon in the browser
- `https://ccms.yourdomain.com` loads the CCMS_UI login page
- HTTP (`http://ccms.yourdomain.com`) redirects to HTTPS
- DCUs can still connect on TCP port 9100 (unchanged)

### Updated Port Reference (with nginx)

| Port | Service | Public | Protocol | Purpose |
|---|---|---|---|---|
| 80 | nginx | ✅ | HTTP | Redirects to HTTPS |
| 443 | nginx | ✅ | HTTPS | SSL-secured CCMS_UI web dashboard |
| 8080 | CCMS_UI | ❌ | HTTP | Internal — proxied by nginx |
| 8102 | SERVER | ❌ | HTTP | Internal — CCMS_UI to SERVER REST |
| 9100 | SERVER | ✅ | TCP | DCU device connections |
| 3306 | MySQL | ❌ | TCP | Internal database |
| 27017 | MongoDB | ❌ | TCP | Internal database |

---

## Port Reference

| Port | Service | Protocol | Purpose |
|---|---|---|---|
| 80 | nginx | HTTP | Redirects to HTTPS (public) |
| 443 | nginx | HTTPS | SSL-secured CCMS_UI web dashboard (public) |
| 8080 | CCMS_UI | HTTP | Web dashboard (context: `/CCMS`) — internal only |
| 8102 | SERVER | HTTP | REST API for UI integration (context: `/user`) |
| 9100 | SERVER | TCP | Netty device communication (DCU/gateway protocol) — public |
| 3306 | MySQL | TCP | Relational database — internal only |
| 27017 | MongoDB | TCP | Document database — internal only |

---

## SERVER REST API Endpoints

All endpoints: `http://<host>:8102/user/push/...`

| Endpoint | Method | Description |
|---|---|---|
| `/push/sys_conf` | GET | Push system configuration to a DCU |
| `/push/sync_node_conf` | GET | Push node configuration to a DCU |
| `/push/sync_scheduler_conf` | GET | Push scheduler configuration to a DCU |
| `/push/manuval_on` | GET | Send manual light ON command |
| `/push/manuval_off` | GET | Send manual light OFF command |
| `/push/hafe_open_connections` | GET | Clean up half-opened device connections |

---

## Backup & Restore

A single command backs up all three data sources (MongoDB, MySQL, and historical CSV files) before taking the application down for maintenance.

### Backup

```bash
./scripts/backup.sh
```

This creates a timestamped directory under `backups/`:

```
backups/2026-06-27_1200/
├── mongodb-ccms.archive          # MongoDB ccms database (mongodump)
├── mysql-employee_db.sql          # MySQL employee_db database (mysqldump)
└── historical-data.tar.gz         # CSV files from /home/data/dontdelete/
```

### Restore

```bash
./scripts/restore.sh backups/2026-06-27_1200
```

Restores all three from a previous backup. After restoring CSV data, restart CCMS_UI:

```bash
docker compose restart ccms_ui
```

### What gets backed up

| Source | Container | Method | Output |
|---|---|---|---|
| MongoDB (`ccms` database) | `cspl-mongodb` | `mongodump --db ccms --archive` | `.archive` file |
| MySQL (`employee_db` database) | `cspl-mysql` | `mysqldump -u root -proot employee_db` | `.sql` file |
| Historical CSV (`/home/data/dontdelete/`) | Host filesystem | `tar -czf` | `.tar.gz` file |

### Maintenance workflow

```bash
# 1. Take backup
./scripts/backup.sh

# 2. Bring the application down
docker compose down

# 3. Perform maintenance (upgrade, migrate, etc.)
# ...

# 4. Bring it back up
docker compose up -d

# 5. Restore if needed
./scripts/restore.sh backups/2026-06-27_1200
```

---

## Verification Checklist

- [ ] `http://localhost:8080/CCMS/` loads the login page
- [ ] SERVER REST responds: `curl http://localhost:8102/user/push/hafe_open_connections`
- [ ] MySQL is seeded and connectable
- [ ] MongoDB stores data in the `ccms` database
- [ ] CCMS_UI can push DCU configuration (check logs for `200 Success`)
- [ ] TCP port 9100 is listening for device connections

---

## Running Tests

The project ships with three automated test suites that cover the SERVER, the CCMS_UI Java backend, and the CCMS_UI AngularJS frontend. All are pure unit/integration tests — no live MySQL, MongoDB, or running containers required.

### Quick Summary

| Suite | Command | Where | Results |
|---|---|---|---|
| SERVER (Java) | `mvn test` | `SERVER/ccms/` | 76/76 pass |
| CCMS_UI (Java backend) | `mvn test` | `CCMS_UI/STARTUP/ccms_ui/` | 75/75 pass |
| CCMS_UI (AngularJS) | `npm test` | `CCMS_UI/STARTUP/ccms_ui/` | 66/66 pass |
| **Total** | | | **217/217 pass** |

### 1. SERVER Backend Tests

```bash
cd SERVER/ccms
mvn test
```

Runs JUnit 4 + Mockito tests for the Netty TCP server, command parsing, and REST controllers. Pure unit tests — no MongoDB needed.

### 2. CCMS_UI Java Backend Tests

```bash
cd CCMS_UI/STARTUP/ccms_ui
mvn test
```

Runs JUnit 4 + Mockito + Spring MVC `MockMvc` tests for the Spring controllers (DCU, Node, Event, User, DeviceConfiguration). All DAO/Service layers are pure Mockito mocks — no embedded MongoDB or MySQL needed.

### 3. CCMS_UI AngularJS Frontend Tests

```bash
cd CCMS_UI/STARTUP/ccms_ui

# One-time: install Node.js dependencies
npm install

# Run Karma + Jasmine tests
npm test
```

Karma runs in headless Chromium (provided by the `puppeteer` npm package — no native Chrome install required). Test files live under `src/test/javascript/controllers/` and `src/test/javascript/factories/`. Stub files for Bower-only dependencies (`inform`, `ui.select`, `highcharts-ng`, Google Maps API, etc.) live under `src/test/javascript/mocks/`.

### Run All Suites in One Command

Use the bundled script to run all three suites and report a final summary:

```bash
cd SERVER_CCMS_UI_App
bash scripts/run-all-tests.sh
```

Output looks like:

```
=== [SERVER] mvn test ===
...
>>> SERVER: PASS
=== [CCMS_UI Java] mvn test ===
...
>>> CCMS_UI Java: PASS
=== [CCMS_UI AngularJS] npm test ===
...
>>> CCMS_UI AngularJS: PASS

=== Results: 3 passed, 0 failed ===
```

The script runs every suite even if one fails, and exits with a non-zero status if any suite failed (suitable for CI use). Equivalently, you can chain the commands manually:

```bash
cd SERVER/ccms && mvn test && \
  cd ../../CCMS_UI/STARTUP/ccms_ui && mvn test && npm test
```

### API Smoke Test (Optional)

After deploying, you can also run a live HTTP smoke test against a running deployment:

```bash
cd SERVER_CCMS_UI_App
bash scripts/api-smoke-test.sh
```

This hits 39 endpoints across the CCMS_UI and SERVER REST APIs. **Expected result: 38 PASS, 1 FAIL** — the `/dashboard/count` endpoint may time out under load because of a slow MongoDB aggregation. This is a known performance issue, not a regression.

### Prerequisites

| Dependency | Purpose | Install |
|---|---|---|
| Maven 3 | Java tests | `apt install maven` |
| JDK 7+ | CCMS_UI Java tests | `apt install openjdk-7-jdk` (or 8) |
| JDK 8 | SERVER Java tests | `apt install openjdk-8-jdk` |
| Node.js + npm | AngularJS tests | See https://nodejs.org/ |
| `curl` | API smoke test | `apt install curl` |

### Notes

- All Java controller tests use pure Mockito mocks — no live DB connection
- Hard refresh (`Ctrl+Shift+R`) is required in the browser after each deployment rebuild to clear cached HTML templates
- `mvn package -DskipTests` skips all tests when building a production WAR/JAR
- For continuous integration, run `mvn test` in `SERVER/ccms/` and `CCMS_UI/STARTUP/ccms_ui/`, then `npm test` in `CCMS_UI/STARTUP/ccms_ui/`

---

## Troubleshooting

| Problem | Likely Cause | Fix |
|---|---|---|
| `seed` container exits with code 1 | MongoDB or MySQL not reachable from seed container, or `mongo.archive` is corrupt | Check `docker compose logs seed`; verify `db/seeds/mongo.archive` exists and is a valid gzip; verify `MONGO_HOST` and `MYSQL_HOST` in `.env` match the compose service names |
| App starts but MongoDB is empty | `SEED_DATA=false` or seed container was skipped | Set `SEED_DATA=true` and `docker compose up -d --build` (or `docker compose up seed` after the rest are up) |
| App starts but old data is gone after re-seeding | `mongorestore --drop` wiped the existing database | Expected. Re-seed wipes the target db first. Set `SEED_DATA=false` to preserve existing data |
| `docker compose up` fails with "variable not set" | `.env` missing or incomplete | `cp .env.example .env` and fill in real values |
| CCMS_UI cannot connect to SERVER | Wrong `ccms.server.host` | Set `CCMS_SERVER_HOST` in `.env` (`localhost` for local, `server` for Docker, or your FQDN) |
| MySQL connection refused in CCMS_UI | Wrong DB credentials in env | Check `MYSQL_ROOT_PASSWORD` and `MYSQL_DATABASE` in `.env` |
| "Connection refused" to MySQL/MongoDB | DB containers not running | `docker compose up -d mysql mongodb` |
| SERVER starts but REST returns errors | MongoDB unreachable | Check `MONGODB_HOST` in `.env` (default: `mongodb`) |
| CCMS_UI WAR deploys but 404 on `/CCMS/` | Tomcat context path mismatch | Ensure WAR is named `CCMS.war` |
| "NoClassDefFoundError" on startup | Java version mismatch | Use JDK 7 for CCMS_UI, JDK 8 for SERVER |
| Device connections fail on TCP port 9100 | Port not exposed | Ensure `NETTY_PORT` (default `9100`) is mapped in docker-compose |
| nginx serves the default page instead of the dashboard | `PUBLIC_DOMAIN` mismatch | Set `PUBLIC_DOMAIN` in `.env` to match your real domain |
| White page / JS not loading | Browser cache | Clear cache or use incognito mode |
| `npm test` fails with "Chrome not found" | `CHROME_BIN` not set | `package.json` `test` script sets it automatically via `scripts/get-chrome-path.js`. To override: `export CHROME_BIN=/path/to/chrome` |
| `mvn test` fails with Mockito errors on JDK 21 | JDK too new for Mockito 1.x | Run tests with JDK 7/8 (matches production runtime) |

---

## File Reference

| File | Purpose |
|---|---|
| `.env` (gitignored) | All runtime secrets and env-specific config |
| `.env.example` (committed) | Template showing required `.env` keys |
| `docker-compose.yml` | Orchestrates all services; reads `.env` via `env_file:` |
| `SERVER/ccms/Dockerfile` | Builds SERVER JAR; injects `server.log.dir` as JVM `-D` |
| `SERVER/ccms/conf/applicationContext-docker.xml` | Docker Spring config for SERVER (MongoDB host from env) |
| `SERVER/ccms/conf/application.properties` | SERVER app settings (all keys templated) |
| `SERVER/ccms/conf/log4j2.properties` | SERVER log4j2 config (log path from `server.log.dir`) |
| `CCMS_UI/STARTUP/ccms_ui/Dockerfile` | Builds CCMS_UI WAR + deploys to Tomcat |
| `CCMS_UI/STARTUP/ccms_ui/docker-entrypoint.sh` | Converts `.env` env vars → JVM `-D` for Spring |
| `CCMS_UI/STARTUP/ccms_ui/conf/spring-config-docker.xml` | Docker Spring config for UI (DB hosts from env) |
| `CCMS_UI/STARTUP/ccms_ui/src/main/webapp/WEB-INF/spring-config.xml` | Local Spring config for UI (DB hosts: `localhost` defaults) |
| `CCMS_UI/STARTUP/ccms_ui/src/main/resources/application.properties` | UI app properties (contains `ccms.server.host`) |
| `nginx/Dockerfile` | Builds the nginx container (alpine + certbot) |
| `nginx/docker-entrypoint.sh` | Renders `nginx.conf` from the template via `envsubst` |
| `nginx/nginx.conf.template` | nginx config with `${PUBLIC_DOMAIN}` and `${LETSENCRYPT_LIVE_DIR}` |
| `scripts/run-all-tests.sh` | Runs all three test suites (SERVER, CCMS_UI Java, CCMS_UI AngularJS) and reports a summary |
| `scripts/api-smoke-test.sh` | Live HTTP smoke test against 39 endpoints — requires running deployment |
| `scripts/backup.sh` | Backs up MongoDB, MySQL, and historical CSV data; reads `.env` |
| `scripts/restore.sh` | Restores from a backup directory; reads `.env` |
| `db/seeds/mongo.archive` | Committed MongoDB `ccms` snapshot used by the `seed` service |
| `db/seeds/mysql/01-schema.sql` | MySQL schema applied by the MySQL image on first start + by the `seed` service |
| `db/seeds/seed.sh` | Orchestrator: waits for DBs, then restores from the archive + applies the schema |
