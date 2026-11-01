# PostgreSQL Bootcamp Assignment

## Objective
To perform a logical database backup, configure Write-Ahead Log (WAL) archiving, perform Point-in-Time Recovery (PITR), and establish and monitor a streaming standby replica.

## Step 1: Take and Verify a Logical Backup

First, create a directory for backups and back up the `bootcamp` database.

```bash
mkdir -p ~/backups
pg_dump -Fc -f ~/backups/bootcamp.dump bootcamp
```

Verify that the backup file contains database objects.

```bash
pg_restore --list ~/backups/bootcamp.dump | head
```

Create a test database and restore the backup.

```bash
createdb bootcamp_check
pg_restore -d bootcamp_check ~/backups/bootcamp.dump
```

**Expected result:** The backup is created, its contents can be listed, and the database is restored successfully into `bootcamp_check`.

## Step 2: Enable WAL Archiving and Take a Base Backup

Configure PostgreSQL to enable WAL archiving by updating `postgresql.conf`.

```conf
wal_level = replica
archive_mode = on
archive_command = 'cp %p /home/YOUR_USERNAME/backups/wal/%f'
```

Replace `YOUR_USERNAME` with the actual Linux username.

Create the WAL archive directory.

```bash
mkdir -p ~/backups/wal
```

Restart PostgreSQL.

```bash
sudo systemctl restart postgresql
```

Take a physical base backup.

```bash
pg_basebackup -D ~/backups/base -Fp -Xs -P
```

**Expected result:** PostgreSQL is configured for WAL archiving, and the base backup completes successfully.

## Step 3: Simulate a Disaster and Perform Point-in-Time Recovery

Record the current database time before simulating the disaster.

```sql
SELECT clock_timestamp();
```

Delete the records from the `students` table to simulate accidental data loss.

```sql
DELETE FROM students;
```

Verify that the records have been deleted.

```sql
SELECT COUNT(*) FROM students;
```

### Recovery Procedure

1. Stop the PostgreSQL instance that will be recovered.
2. Restore the base backup into a separate recovery data directory.
3. Configure PostgreSQL to retrieve archived WAL files.
4. Set the recovery target to the recorded time before the deletion.
5. Create the `recovery.signal` file in the recovery data directory.
6. Start PostgreSQL using the recovered data directory.
7. Verify that the database has recovered to the intended point in time.

For PostgreSQL 12 and later, configure the recovery settings as follows:

```conf
restore_command = 'cp /home/YOUR_USERNAME/backups/wal/%f %p'
recovery_target_time = 'YOUR_RECOVERY_TIMESTAMP'
recovery_target_action = 'pause'
```

Replace `YOUR_USERNAME` and `YOUR_RECOVERY_TIMESTAMP` with the correct values.

Verify the recovered database.

```sql
SELECT COUNT(*) FROM students;
```

**Expected result:** The database is recovered to the selected point in time, and the student records reflect the state of the database at that recovery point.

## Step 4: Set Up Streaming Replication

Create a replication role on the primary PostgreSQL server.

```sql
CREATE ROLE replicator
WITH REPLICATION LOGIN PASSWORD 'YOUR_STRONG_PASSWORD';
```

Configure `pg_hba.conf` to allow the replication connection.

```conf
host replication replicator 127.0.0.1/32 scram-sha-256
```

Reload PostgreSQL after updating the configuration.

```bash
sudo systemctl reload postgresql
```

Create a separate, empty data directory for the standby server.

```bash
mkdir -p ~/standby
```

Build the standby using `pg_basebackup`.

```bash
pg_basebackup -h 127.0.0.1 -U replicator -D ~/standby -Fp -Xs -P -R
```

The `-R` option creates the standby configuration and connection information needed to connect to the primary.

Configure and start the standby as a separate PostgreSQL instance with its own data directory and port.

Verify the standby status.

```sql
SELECT pg_is_in_recovery();
```

**Expected result:** The standby connects to the primary and operates in recovery mode while receiving WAL records.

## Step 5: Monitor Replication Health

Connect to the primary PostgreSQL server and execute the following query.

```sql
SELECT
    application_name,
    client_addr,
    state,
    sync_state,
    sent_lsn,
    write_lsn,
    flush_lsn,
    replay_lsn
FROM pg_stat_replication;
```

Check the approximate replication lag in bytes.

```sql
SELECT
    application_name,
    state,
    pg_wal_lsn_diff(
        pg_current_wal_lsn(),
        replay_lsn
    ) AS lag_bytes
FROM pg_stat_replication;
```

**Expected result:** The standby appears in the replication status, and its state is normally `streaming` when replication is operating successfully.

## Conclusion

This assignment demonstrates essential PostgreSQL database protection and disaster recovery techniques. A logical backup provides a portable database backup, WAL archiving preserves the transaction logs needed for point-in-time recovery, and a physical base backup provides the starting point for restoring a database. Point-in-Time Recovery allows the database to be restored to a selected moment, while streaming replication maintains a standby server by continuously transferring WAL records from the primary.

These techniques improve database availability, protect against accidental data loss, and support business continuity.
