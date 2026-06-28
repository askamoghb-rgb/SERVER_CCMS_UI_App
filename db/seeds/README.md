# CCMS Database Seeds

This directory contains committed seed data so that a fresh clone
(`cp .env.example .env && docker compose up -d --build`) starts with
a populated database.

## Files

| File | Purpose |
|---|---|
| `mongo.archive` | `mongodump --archive` snapshot of the `ccms` database (21 collections: users, DCUs, events, meter data, scheduler configurations, etc.) |
| `mysql/01-schema.sql` | MySQL `employee_db` schema. Currently only creates a `ccms_meta` marker table — see header comment in the file for why the app doesn't actually need any MySQL tables |
| `seed.sh` | Orchestrator script. Runs inside the `seed` service container, waits for MongoDB + MySQL to be reachable, then restores from `mongo.archive` and applies the MySQL schema |

## Behavior

The `seed` service in `docker-compose.yml` runs once on first
`docker compose up` and exits 0. The `server` and `ccms_ui`
services have `depends_on: seed: { condition: service_completed_successfully }`,
so the app only starts once seeding is complete.

To skip seeding (e.g. when restoring from your own backup), set
`SEED_DATA=false` in `.env`.

To re-seed from scratch:
```bash
docker compose down -v                 # wipe volumes
docker compose up -d --build           # seed runs on first start
```

## How the archive was generated

```bash
docker exec cspl-mongodb \
    mongodump --db ccms --archive=/tmp/ccms.archive
    docker cp <mongo-container>:/tmp/ccms.archive db/seeds/mongo.archive
```

The live `data/mongodb` directory on a fresh clone will be empty
before the `seed` service runs; the `seed` service populates Mongo
from the archive.

## Notes

- `mongo.archive` is a binary mongodump stream. Don't edit it by hand.
- The archive is committed to the repo so seeding is self-contained.
  Total size: ~98 MB.
- **Important:** capture the archive inside the container and `docker cp` it out — piping `mongodump --archive` through the host shell (`> file`) produces a corrupted file that `mongorestore` rejects.
- The `ccms_user_details` collection contains the seed admin user
  (default password is set in the source data — change it after
  first login via the UI).
