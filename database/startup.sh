#!/bin/bash

# Minimal PostgreSQL startup and idempotent schema/seed script
# All SQL is executed as single statements via psql -c using the connection read from db_connection.txt
DB_NAME="myapp"
DB_USER="appuser"
DB_PASSWORD="dbuser123"
DB_PORT="5001"

echo "Starting PostgreSQL setup..."

# Find PostgreSQL version and set paths
PG_VERSION=$(ls /usr/lib/postgresql/ 2>/dev/null | head -1)
PG_BIN="/usr/lib/postgresql/${PG_VERSION}/bin"

if [ -z "${PG_VERSION}" ] || [ ! -x "${PG_BIN}/psql" ]; then
  echo "⚠ PostgreSQL binaries not found at ${PG_BIN}. Ensure PostgreSQL is installed in the container."
fi

echo "Found PostgreSQL version: ${PG_VERSION}"

# Ensure db_connection.txt reflects the canonical connection string (port 5001)
CONN_STR="psql postgresql://${DB_USER}:${DB_PASSWORD}@localhost:${DB_PORT}/${DB_NAME}"
echo "${CONN_STR}" > db_connection.txt
echo "Connection string saved to db_connection.txt"

# Ensure db_visualizer/postgres.env is aligned with port 5001 and current credentials
cat > db_visualizer/postgres.env << EOF
export POSTGRES_URL="postgresql://localhost:${DB_PORT}/${DB_NAME}"
export POSTGRES_USER="${DB_USER}"
export POSTGRES_PASSWORD="${DB_PASSWORD}"
export POSTGRES_DB="${DB_NAME}"
export POSTGRES_PORT="${DB_PORT}"
EOF
echo "Environment variables saved to db_visualizer/postgres.env"

# Helper to run single SQL via psql -c using the connection from db_connection.txt
run_sql() {
  # PUBLIC_INTERFACE
  # Executes a single SQL statement via psql -c using the URL from db_connection.txt
  # Guards errors so startup remains idempotent and non-fatal.
  local sql="$1"
  if [ ! -f "db_connection.txt" ]; then
    echo "db_connection.txt not found; skipping SQL."
    return 0
  fi
  local cmd
  cmd="$(cat db_connection.txt)"
  # Execute as a single statement
  ${cmd} -v ON_ERROR_STOP=1 -c "${sql}" >/dev/null 2>&1 || true
}

# Check if PostgreSQL is already running on the specified port
if [ -x "${PG_BIN}/pg_isready" ] && sudo -u postgres ${PG_BIN}/pg_isready -p ${DB_PORT} > /dev/null 2>&1; then
    echo "PostgreSQL is already running on port ${DB_PORT}."
else
    # Also check if there's a PostgreSQL process running (in case pg_isready fails)
    if pgrep -f "postgres.*-p ${DB_PORT}" > /dev/null 2>&1; then
        echo "Found existing PostgreSQL process on port ${DB_PORT}"
    else
        # Initialize PostgreSQL data directory if it doesn’t exist
        if [ -x "${PG_BIN}/initdb" ] && [ ! -f "/var/lib/postgresql/data/PG_VERSION" ]; then
            echo "Initializing PostgreSQL..."
            sudo -u postgres ${PG_BIN}/initdb -D /var/lib/postgresql/data
        fi

        # Start PostgreSQL server in background if we have postgres binaries
        if [ -x "${PG_BIN}/postgres" ]; then
          echo "Starting PostgreSQL server on port ${DB_PORT}..."
          sudo -u postgres ${PG_BIN}/postgres -D /var/lib/postgresql/data -p ${DB_PORT} >/tmp/postgres.log 2>&1 &
          sleep 3
        else
          echo "⚠ postgres binary not found; continuing. Schema/seed will run when DB becomes reachable."
        fi
    fi
fi

# Wait briefly for PostgreSQL to be ready (non-fatal if unavailable)
if [ -x "${PG_BIN}/pg_isready" ]; then
  for i in {1..10}; do
      if sudo -u postgres ${PG_BIN}/pg_isready -p ${DB_PORT} > /dev/null 2>&1; then
          echo "PostgreSQL is ready!"
          break
      fi
      echo "Waiting for PostgreSQL... ($i/10)"
      sleep 2
  done
fi

# Idempotent database and role setup using single -c statements
# Create role if not exists
run_sql "DO \$\$ BEGIN IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname='${DB_USER}') THEN CREATE ROLE ${DB_USER} WITH LOGIN PASSWORD '${DB_PASSWORD}'; END IF; END \$\$;"

# Ensure password is set on every run
run_sql "ALTER ROLE ${DB_USER} WITH PASSWORD '${DB_PASSWORD}';"

# Create database if not exists (requires connecting to postgres db)
# Temporarily override connection to 'postgres' for database creation
POSTGRES_ADMIN_CONN="psql postgresql://${DB_USER}:${DB_PASSWORD}@localhost:${DB_PORT}/postgres"
echo "${POSTGRES_ADMIN_CONN}" > /tmp/_tmp_conn.txt
tmp_run_sql() {
  local sql="$1"
  local cmd
  cmd="$(cat /tmp/_tmp_conn.txt)"
  ${cmd} -v ON_ERROR_STOP=1 -c "${sql}" >/dev/null 2>&1 || true
}
tmp_run_sql "SELECT 'CREATE DATABASE ${DB_NAME}' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname='${DB_NAME}')\\gexec"

# Restore normal connection file to target DB
echo "${CONN_STR}" > db_connection.txt

# Grant database privileges (idempotent)
run_sql "GRANT ALL PRIVILEGES ON DATABASE ${DB_NAME} TO ${DB_USER};"

# Schema-level permissions (idempotent)
run_sql "GRANT USAGE ON SCHEMA public TO ${DB_USER};"
run_sql "GRANT CREATE ON SCHEMA public TO ${DB_USER};"
run_sql "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO ${DB_USER};"
run_sql "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO ${DB_USER};"
run_sql "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO ${DB_USER};"
run_sql "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TYPES TO ${DB_USER};"
run_sql "GRANT ALL ON SCHEMA public TO ${DB_USER};"
run_sql "GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO ${DB_USER};"
run_sql "GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO ${DB_USER};"
run_sql "GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public TO ${DB_USER};"

echo "Applying schema (single statements) and seeding minimal data (single statements)..."

# Create tables (each in its own statement)
run_sql "CREATE TABLE IF NOT EXISTS experiments (id SERIAL PRIMARY KEY, name TEXT NOT NULL, description TEXT, created_at TIMESTAMPTZ DEFAULT NOW());"
run_sql "CREATE TABLE IF NOT EXISTS steps (id SERIAL PRIMARY KEY, experiment_id INTEGER NOT NULL REFERENCES experiments(id) ON DELETE CASCADE, step_order INTEGER NOT NULL, name TEXT NOT NULL, description TEXT, created_at TIMESTAMPTZ DEFAULT NOW());"
run_sql "CREATE TABLE IF NOT EXISTS reagents (id SERIAL PRIMARY KEY, name TEXT NOT NULL, cas_number TEXT, vendor TEXT, created_at TIMESTAMPTZ DEFAULT NOW());"
run_sql "CREATE TABLE IF NOT EXISTS parameters (id SERIAL PRIMARY KEY, step_id INTEGER NOT NULL REFERENCES steps(id) ON DELETE CASCADE, key TEXT NOT NULL, value TEXT, unit TEXT, created_at TIMESTAMPTZ DEFAULT NOW());"
run_sql "CREATE TABLE IF NOT EXISTS run_logs (id SERIAL PRIMARY KEY, experiment_id INTEGER NOT NULL REFERENCES experiments(id) ON DELETE CASCADE, status TEXT NOT NULL, message TEXT, created_at TIMESTAMPTZ DEFAULT NOW());"
run_sql "CREATE TABLE IF NOT EXISTS step_reagents (id SERIAL PRIMARY KEY, step_id INTEGER NOT NULL REFERENCES steps(id) ON DELETE CASCADE, reagent_id INTEGER NOT NULL REFERENCES reagents(id) ON DELETE RESTRICT, amount TEXT, unit TEXT, created_at TIMESTAMPTZ DEFAULT NOW());"

# Seed minimal data (each INSERT is a single statement and guarded to be idempotent)
run_sql "INSERT INTO experiments (name, description) SELECT 'Test Experiment', 'Minimal seeded experiment' WHERE NOT EXISTS (SELECT 1 FROM experiments);"
run_sql "INSERT INTO steps (experiment_id, step_order, name, description) SELECT id, 1, 'Mix', 'Combine reagents' FROM experiments ORDER BY id LIMIT 1 WHERE NOT EXISTS (SELECT 1 FROM steps);"
run_sql "INSERT INTO reagents (name, cas_number, vendor) SELECT 'Water', '7732-18-5', 'Generic' WHERE NOT EXISTS (SELECT 1 FROM reagents);"
run_sql "INSERT INTO step_reagents (step_id, reagent_id, amount, unit) SELECT s.id, r.id, '10', 'mL' FROM steps s CROSS JOIN reagents r ORDER BY s.id, r.id LIMIT 1 WHERE NOT EXISTS (SELECT 1 FROM step_reagents);"
run_sql "INSERT INTO parameters (step_id, key, value, unit) SELECT s.id, 'temperature', '25', 'C' FROM steps s ORDER BY s.id LIMIT 1 WHERE NOT EXISTS (SELECT 1 FROM parameters);"
run_sql "INSERT INTO run_logs (experiment_id, status, message) SELECT e.id, 'created', 'Initial log entry' FROM experiments e ORDER BY e.id LIMIT 1 WHERE NOT EXISTS (SELECT 1 FROM run_logs);"

echo "Schema and seed operations attempted."
echo "If the database was not yet reachable on port ${DB_PORT}, these steps will succeed on the next run once the DB is ready."

echo "To connect to the database, use one of the following commands:"
echo "psql -h localhost -U ${DB_USER} -d ${DB_NAME} -p ${DB_PORT}"
echo "$(cat db_connection.txt)"
