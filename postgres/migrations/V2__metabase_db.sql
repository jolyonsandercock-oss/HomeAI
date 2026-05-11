-- V2__metabase_db.sql
-- Creates dedicated Metabase metadata database + role.
-- Metabase stores its dashboards/users/schedules here; the homeai
-- application database is added separately as a Metabase Data Source
-- (queried via the homeai_readonly role).
--
-- Idempotent: safe to re-run.
-- Apply:
--   docker exec -i homeai-postgres psql -U postgres \
--     -v metabase_app_password="$METABASE_APP_PASSWORD" \
--     -f - < postgres/migrations/V2__metabase_db.sql

\set ON_ERROR_STOP on

SELECT format('CREATE ROLE metabase_app LOGIN PASSWORD %L', :'metabase_app_password')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'metabase_app')
\gexec

SELECT 'CREATE DATABASE metabase_app OWNER metabase_app'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'metabase_app')
\gexec

\connect metabase_app

GRANT ALL ON SCHEMA public TO metabase_app;
ALTER SCHEMA public OWNER TO metabase_app;

REVOKE ALL ON DATABASE metabase_app FROM PUBLIC;
REVOKE ALL ON SCHEMA public FROM PUBLIC;
