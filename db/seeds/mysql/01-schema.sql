-- ============================================================
-- MySQL schema for CCMS
-- ------------------------------------------------------------
-- NOTE: The CCMS application uses MongoDB for all data storage
-- (users, DCUs, events, meter data, scheduler configurations,
-- etc. - see the @Document-annotated classes in
-- com.vnetsoft.ccms.pojo and com.vetsoft.ccms.netty.pojo).
--
-- The MySQL container is started for compatibility with the
-- legacy spring-config.xml DataSource bean, but **no table is
-- actually required** for the app to function. The Spring
-- `SessionFactory` is configured with `annotatedClasses` that
-- point at MongoDB @Document classes, and the resulting
-- SessionFactory is never used by any DAO (all DAOs use
-- `MongoTemplate`).
--
-- This file is included to demonstrate the MySQL init mechanism
-- and to provide a single marker table for sanity checks. Add
-- real tables here if you ever wire the app up to use MySQL.
-- ============================================================

CREATE TABLE IF NOT EXISTS ccms_meta (
    id          INT PRIMARY KEY,
    schema_ver  VARCHAR(32) NOT NULL,
    seeded_at   TIMESTAMP DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

INSERT IGNORE INTO ccms_meta (id, schema_ver)
VALUES (1, '1.0.0');
