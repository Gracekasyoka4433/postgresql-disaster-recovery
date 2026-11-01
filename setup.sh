#!/bin/bash
set -e

echo "Creating PostgreSQL Disaster Recovery Project..."

mkdir -p config/primary init scripts backups/wal backups/base recovery reports screenshots

# 1. Environment settings
cat > .env.example <<'EOF'
POSTGRES_PASSWORD=ChangeThisPassword123!
EOF

if [ ! -f .env ]; then
    cp .env.example .env
fi

cat > .gitignore <<'EOF'
.env
backups/
recovery/data/
*.dump
EOF

# 2. PostgreSQL configuration
cat > config/primary/postgresql.conf <<'EOF'
listen_addresses = '*'
wal_level = replica
archive_mode = on
archive_command = 'test ! -f /wal_archive/%f && cp %p /wal_archive/%f'
max_wal_senders = 10
max_replication_slots = 10
wal_keep_size = 256MB
password_encryption = 'scram-sha-256'
EOF

cat > config/primary/pg_hba.conf <<'EOF'
local all all scram-sha-256
host all all all scram-sha-256
host replication replicator all scram-sha-256
EOF

# 3. Database initialization
cat > init/01-setup.sql <<'EOF'
CREATE ROLE replicator
WITH REPLICATION LOGIN PASSWORD 'reppass';

CREATE TABLE students (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100),
    course VARCHAR(100)
);

INSERT INTO students (name, course) VALUES
('John', 'Database Administration'),
('Mary', 'Computer Science'),
('Peter', 'Information Technology'),
('Grace', 'Cybersecurity'),
('David', 'Software Engineering');
EOF

# 4. Docker Compose configuration
cat > docker-compose.yml <<'EOF'
services:
  primary:
    image: postgres:16
    container_name: pg-primary
    restart: unless-stopped
    environment:
      POSTGRES_DB: bootcamp
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    ports:
      - "5432:5432"
    volumes:
      - primary_data:/var/lib/postgresql/data
      - ./backups/wal:/wal_archive
      - ./config/primary/postgresql.conf:/etc/postgresql/postgresql.conf:ro
      - ./config/primary/pg_hba.conf:/etc/postgresql/pg_hba.conf:ro
      - ./init:/docker-entrypoint-initdb.d:ro
    command:
      - postgres
      - -c
      - config_file=/etc/postgresql/postgresql.conf
      - -c
      - hba_file=/etc/postgresql/pg_hba.conf
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres -d bootcamp"]
      interval: 5s
      timeout: 5s
      retries: 20

  standby:
    image: postgres:16
    container_name: pg-standby
    restart: unless-stopped
    environment:
      PGPASSWORD: reppass
    ports:
      - "5433:5432"
    volumes:
      - standby_data:/var/lib/postgresql/data
    depends_on:
      primary:
        condition: service_healthy
    entrypoint: ["/bin/bash", "-ec"]
    command: |
      if [ ! -s "$$PGDATA/PG_VERSION" ]; then
        mkdir -p "$$PGDATA"
        chown -R postgres:postgres "$$PGDATA"
        echo "primary:5432:replication:replicator:reppass" > /var/lib/postgresql/.pgpass
        chown postgres:postgres /var/lib/postgresql/.pgpass
        chmod 600 /var/lib/postgresql/.pgpass
        gosu postgres pg_basebackup \
          -h primary -U replicator \
          -D "$$PGDATA" -R -P
      fi
      exec gosu postgres postgres \
        -D "$$PGDATA" \
        -c hot_standby=on \
        -c listen_addresses='*'

  recovery:
    image: postgres:16
    container_name: pg-recovery
    profiles: ["recovery"]
    environment:
      RECOVERY_TARGET_TIME: ${RECOVERY_TARGET_TIME:?Set RECOVERY_TARGET_TIME}
    ports:
      - "5434:5432"
    volumes:
      - recovery_data:/var/lib/postgresql/data
      - ./backups:/backups:ro
      - ./backups/wal:/wal_archive:ro
    entrypoint: ["/bin/bash", "-ec"]
    command: |
      if [ ! -s "$$PGDATA/PG_VERSION" ]; then
        mkdir -p "$$PGDATA"
        tar -xzf /backups/base/base.tar.gz -C "$$PGDATA"
        mkdir -p "$$PGDATA/pg_wal"
        tar -xzf /backups/base/pg_wal.tar.gz -C "$$PGDATA/pg_wal"
        chown -R postgres:postgres "$$PGDATA"
        touch "$$PGDATA/recovery.signal"
      fi
      exec gosu postgres postgres \
        -D "$$PGDATA" \
        -c listen_addresses='*' \
        -c restore_command='cp /wal_archive/%f %p' \
        -c recovery_target_time="$$RECOVERY_TARGET_TIME" \
        -c recovery_target_action=promote

volumes:
  primary_data:
  standby_data:
  recovery_data:
EOF

# 5. Logical backup
cat > scripts/01_logical_backup.sh <<'EOF'
#!/bin/bash
set -e

mkdir -p backups

docker compose exec -T primary bash -c \
  'PGPASSWORD="$POSTGRES_PASSWORD" pg_dump -h 127.0.0.1 -U postgres -Fc bootcamp' \
  > backups/bootcamp.dump

echo "Logical backup created:"
ls -lh backups/bootcamp.dump
EOF

# 6. Verify logical restoration
cat > scripts/02_verify_restore.sh <<'EOF'
#!/bin/bash
set -e

docker compose exec -T primary bash -c \
  'PGPASSWORD="$POSTGRES_PASSWORD" dropdb -h 127.0.0.1 -U postgres --if-exists bootcamp_check'

docker compose exec -T primary bash -c \
  'PGPASSWORD="$POSTGRES_PASSWORD" createdb -h 127.0.0.1 -U postgres bootcamp_check'

docker compose exec -T primary bash -c \
  'PGPASSWORD="$POSTGRES_PASSWORD" pg_restore -h 127.0.0.1 -U postgres -d bootcamp_check' \
  < backups/bootcamp.dump

docker compose exec -T primary bash -c \
  'PGPASSWORD="$POSTGRES_PASSWORD" psql -h 127.0.0.1 -U postgres -d bootcamp_check -c "SELECT * FROM students;"'

echo "Logical restoration verified."
EOF

# 7. Physical base backup
cat > scripts/03_base_backup.sh <<'EOF'
#!/bin/bash
set -e

mkdir -p backups/base
rm -f backups/base/*

docker compose exec -T primary bash -c \
  'PGPASSWORD="$POSTGRES_PASSWORD" pg_basebackup -h 127.0.0.1 -U postgres -D /backups/base -Ft -z -Xs -P'

echo "Physical backup created:"
ls -lh backups/base
EOF

# 8. Prepare PITR recovery point
cat > scripts/04_prepare_pitr.sh <<'EOF'
#!/bin/bash
set -e

echo "Recording recovery point..."

docker compose exec -T primary bash -c \
  'PGPASSWORD="$POSTGRES_PASSWORD" psql -h 127.0.0.1 -U postgres -d bootcamp -c "SELECT clock_timestamp() AS recovery_target_time;"'

echo "Save the timestamp displayed above."
EOF

# 9. Simulate accidental deletion
cat > scripts/05_simulate_disaster.sh <<'EOF'
#!/bin/bash
set -e

echo "Simulating accidental deletion..."

docker compose exec -T primary bash -c \
  'PGPASSWORD="$POSTGRES_PASSWORD" psql -h 127.0.0.1 -U postgres -d bootcamp -c "DELETE FROM students;"'

docker compose exec -T primary bash -c \
  'PGPASSWORD="$POSTGRES_PASSWORD" psql -h 127.0.0.1 -U postgres -d bootcamp -c "SELECT COUNT(*) FROM students;"'

echo "Forcing WAL switches..."

docker compose exec -T primary bash -c \
  'PGPASSWORD="$POSTGRES_PASSWORD" psql -h 127.0.0.1 -U postgres -d bootcamp -c "SELECT pg_switch_wal(); SELECT pg_switch_wal();"'

echo "Checking WAL archive..."

for i in $(seq 1 60); do
    COUNT=$(docker compose exec -T primary bash -c \
      'PGPASSWORD="$POSTGRES_PASSWORD" psql -h 127.0.0.1 -U postgres -d bootcamp -Atc "SELECT archived_count FROM pg_stat_archiver;"')

    if [ "${COUNT:-0}" -gt 0 ]; then
        echo "Archived WAL count: $COUNT"
        exit 0
    fi

    sleep 2
done

echo "WAL archive was not confirmed. Check PostgreSQL logs."
exit 1
EOF

# 10. Run PITR in a separate recovery database
cat > scripts/06_run_pitr.sh <<'EOF'
#!/bin/bash
set -e

if [ -z "$1" ]; then
    echo "Usage: bash scripts/06_run_pitr.sh 'YYYY-MM-DD HH:MM:SS+00'"
    exit 1
fi

export RECOVERY_TARGET_TIME="$1"

echo "Starting separate PITR recovery instance..."

docker compose --profile recovery up -d --force-recreate recovery

echo "Waiting for recovery to start..."
sleep 15

docker compose logs recovery

echo "Checking recovered student records..."

docker compose exec -T recovery \
  psql -U postgres -d bootcamp \
  -c "SELECT COUNT(*) FROM students;"
EOF

# 11. Replication monitoring
cat > scripts/07_monitor_replication.sql <<'EOF'
SELECT
    application_name,
    client_addr,
    state,
    sent_lsn,
    write_lsn,
    flush_lsn,
    replay_lsn,
    pg_wal_lsn_diff(sent_lsn, replay_lsn) AS lag_bytes
FROM pg_stat_replication;
EOF

# 12. Final report
cat > reports/FINAL_REPORT.md <<'EOF'
# PostgreSQL Disaster Recovery Project

## Objective
To perform database backup, WAL archiving, point-in-time recovery,
and streaming replication using PostgreSQL.

## Technologies
- PostgreSQL 16
- Docker
- Docker Compose
- SQL
- Bash

## Exercises
1. Logical backup using pg_dump.
2. Database restoration using pg_restore.
3. WAL archiving.
4. Physical backup using pg_basebackup.
5. Point-in-time recovery.
6. Streaming replication.
7. Replication monitoring.

## Verification
Screenshots and actual execution results must be added after
completing the practical exercises.

## Conclusion
This project demonstrates PostgreSQL backup, disaster recovery,
and high availability concepts.
EOF

# 13. Project README
cat > README.md <<'EOF'
# PostgreSQL Disaster Recovery Lab

A PostgreSQL 16 project demonstrating logical backups,
WAL archiving, point-in-time recovery, and streaming replication.

## Requirements
- Docker Desktop
- Docker Compose
- Git

## Start the primary database

```bash
docker compose config
docker compose up -d primary
docker compose ps
