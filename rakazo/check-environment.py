import os
import sys
from typing import NoReturn, cast
from urllib.parse import parse_qs, unquote, urlsplit

import psycopg


def fail(message: str) -> NoReturn:
    sys.exit(f"Rakazo configuration: {message}")


try:
    runtime = urlsplit(os.environ["DATABASE_URL"])
    if runtime.scheme not in ("postgres", "postgresql"):
        fail("DATABASE_URL must be a PostgreSQL URL")
    if not runtime.username or not runtime.password:
        fail("DATABASE_URL requires a restricted login and a password")
    if sys.argv[1] == "local":
        if (
            runtime.hostname not in ("localhost", "127.0.0.1", "::1")
            or runtime.port not in (None, 5432)
            or runtime.path != "/rakazo"
            or runtime.query
            or unquote(runtime.username) in ("rakazo", "postgres", "rakazo_app")
        ):
            fail("local DATABASE_URL must use a distinct runtime login at localhost:5432/rakazo without query parameters")
    if len(sys.argv) > 2 and sys.argv[2] == "migration":
        owner = urlsplit(os.environ["DATABASE_MIGRATION_URL"])
        if owner.scheme not in ("postgres", "postgresql") or not owner.hostname or not owner.path.strip("/"):
            fail("DATABASE_MIGRATION_URL must be a PostgreSQL URL with a database")
        if not owner.username or unquote(owner.username) == unquote(runtime.username):
            fail("migration and runtime logins must differ")
        if sys.argv[1] == "external":
            routing_keys = {"host", "hostaddr", "port", "dbname", "user", "password", "service"}
            if routing_keys.intersection(parse_qs(runtime.query)) or routing_keys.intersection(parse_qs(owner.query)):
                fail("external database routing must be in the URL authority and path, not query parameters")
            if (owner.hostname, owner.port or 5432, unquote(owner.path)) != (runtime.hostname, runtime.port or 5432, unquote(runtime.path)):
                fail("migration and runtime URLs must target the same database endpoint")
except (KeyError, ValueError):
    fail("missing or malformed database connection settings")

if len(sys.argv) > 2 and sys.argv[2] == "runtime":
    try:
        with psycopg.connect(
            os.environ["DATABASE_URL"],
            connect_timeout=10,
            options="-c statement_timeout=10000",
        ) as connection:
            with connection.cursor() as cursor:
                cursor.execute("""
                SELECT
                  (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.messages'::regclass)
                  AND NOT EXISTS (
                    SELECT 1 FROM pg_roles role
                    WHERE pg_has_role(current_user, role.oid, 'MEMBER')
                      AND (role.rolsuper OR role.rolbypassrls OR role.rolcreaterole OR role.rolcreatedb
                        OR EXISTS (
                          SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                          WHERE c.relowner = role.oid AND n.nspname IN ('public', 'rakazo_private')
                        ))
                  );
                """)
                row = cast(tuple[bool] | None, cursor.fetchone())
    except psycopg.Error:
        fail("could not verify runtime database privileges")
    if row != (True,):
        fail("runtime login must not own application tables or inherit privileged roles; verify migrations, database connectivity and restricted grants")
