#!/usr/bin/env sh

# Backs up one Sakala control-plane host into an encrypted, dated set:
#
#   <BACKUP_DIR>/<UTC stamp>/
#     db.dump.age       pg_dump -Fc of the application database
#     secrets.tar.age   /etc/sakala/secrets, which holds APP_KEY
#     rustfs.tar.age    the RustFS /data directory (avatars)
#     SHA256SUMS        checksums of the encrypted files; `sha256sum -c` needs no key
#     manifest.env      non-secret metadata; it is written last, so a set without
#                       it is incomplete
#
# Every artifact is encrypted to an age public key. The private key stays off
# this host, so this host can write backups but can never read one back.
#
# Usage:
#   backup.sh            take a backup, apply retention, copy off-host if configured
#   backup.sh --check    exit non-zero if the last success is too old or a problem
#                        is recorded; this is what an operator or an alert runs
#   backup.sh --prune    apply retention only, for a node that only receives copies
#
# Exit codes:
#   0  a complete set was published
#   1  nothing was published; existing sets were not touched
#   2  usage error, or --check found the backups stale or unhealthy
#   3  the database set was published, but RustFS, secrets, or the off-host copy
#      failed; the local set stays and systemd still reports the run as failed

set -eu
umask 077

env_file=${SAKALA_BACKUP_ENV_FILE:-/etc/sakala/backup.env}
if [ -r "$env_file" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$env_file"
    set +a
fi

backup_dir=${BACKUP_DIR:-/var/lib/sakala/backups}
recipients_file=${BACKUP_AGE_RECIPIENTS_FILE:-/etc/sakala/secrets/backup.age-recipients}
keep=${BACKUP_KEEP:-14}
min_free_mb=${BACKUP_MIN_FREE_MB:-2048}
max_age_hours=${BACKUP_MAX_AGE_HOURS:-26}
postgres_container=${BACKUP_POSTGRES_CONTAINER:-sakala-postgres-1}
api_container=${BACKUP_API_CONTAINER:-sakala-api-1}
lock_wait_timeout=${BACKUP_PG_LOCK_TIMEOUT:-300s}
# An empty value (not an unset one) switches these two artifacts off.
rustfs_container=${BACKUP_RUSTFS_CONTAINER-sakala-rustfs-1}
secrets_dir=${BACKUP_SECRETS_DIR-/etc/sakala/secrets}
remote=${BACKUP_REMOTE:-}
remote_key=${BACKUP_REMOTE_KEY:-/etc/sakala/secrets/backup-remote.ed25519}
remote_known_hosts=${BACKUP_REMOTE_KNOWN_HOSTS:-/etc/sakala/secrets/backup-remote.known_hosts}
remote_port=${BACKUP_REMOTE_PORT:-22}

last_success_file="$backup_dir/last-success"
last_problem_file="$backup_dir/last-problem"

mode=run
step=startup
work_dir=
published=0

log() {
    printf '%s sakala-backup: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

err() {
    log "$*" >&2
}

die() {
    err "$*"
    exit 1
}

is_uint() {
    case "$1" in
        '' | *[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

# Connection values come from the container's own environment, inside the
# container, and travel to the client as environment: nothing sensitive reaches
# a process argument on the host or a log line.
pg_exec() {
    container=$1
    shift
    docker exec -i "$container" sh -c '
        PGUSER=${POSTGRES_USER:-postgres}
        PGDATABASE=${POSTGRES_DB:-$PGUSER}
        export PGUSER PGDATABASE
        exec "$@"' sh "$@"
}

pg_query() {
    printf '%s\n' "$2" | pg_exec "$1" psql -X -At -v ON_ERROR_STOP=1
}

check_keep() {
    if ! is_uint "$keep" || [ "$keep" -lt 1 ]; then
        die "BACKUP_KEEP must be a whole number of at least 1, got: $keep"
    fi
}

# Newest first. Only directories named like a stamp are ever considered, so
# retention cannot reach anything an operator put next to them.
list_sets() {
    find "$1" -mindepth 1 -maxdepth 1 -type d -name '[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z' | sort -r
}

is_complete_set() {
    grep -qx 'status=complete' "$1/manifest.env" 2>/dev/null
}

# Keeps the newest $keep complete sets and everything newer than the oldest of
# them, and only deletes what is older. Counting sets rather than days means a
# long outage can never age out the last good backup.
apply_retention() {
    complete=0
    pruned=0
    for set_path in $(list_sets "$backup_dir"); do
        if [ "$complete" -ge "$keep" ]; then
            rm -rf -- "$set_path"
            pruned=$((pruned + 1))
            log "retention removed $(basename "$set_path")"
        elif is_complete_set "$set_path"; then
            complete=$((complete + 1))
        fi
    done
    log "retention kept $complete complete set(s), removed $pruned (BACKUP_KEEP=$keep)"
}

record_problem() {
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" > "$last_problem_file" 2>/dev/null || true
}

on_exit() {
    status=$?
    trap - EXIT
    if [ -n "$work_dir" ]; then
        rm -rf -- "$work_dir"
    fi
    if [ "$mode" = run ] && [ "$status" -ne 0 ] && [ "$published" -eq 0 ]; then
        err "BACKUP_FAILED step=$step exit=$status: nothing was published and existing sets were not touched"
        record_problem "failed at $step"
    fi
    exit "$status"
}

check_freshness() {
    if [ ! -r "$last_success_file" ]; then
        printf '%s\n' "BACKUP_STALE: no successful backup recorded in $backup_dir" >&2
        exit 2
    fi

    read -r success_epoch success_set < "$last_success_file"
    age_hours=$((($(date +%s) - success_epoch) / 3600))
    unhealthy=0

    if [ "$age_hours" -ge "$max_age_hours" ]; then
        printf '%s\n' "BACKUP_STALE: last success $success_set is $age_hours h old (limit $max_age_hours h)" >&2
        unhealthy=1
    else
        printf '%s\n' "Last success $success_set is $age_hours h old (limit $max_age_hours h)."
    fi

    if [ -r "$last_problem_file" ]; then
        printf '%s\n' "BACKUP_PROBLEM: $(cat "$last_problem_file")" >&2
        unhealthy=1
    fi

    if [ "$unhealthy" -eq 1 ]; then
        exit 2
    fi
}

container_is_running() {
    [ "$(docker inspect --format '{{.State.Running}}' "$1" 2>/dev/null || true)" = true ]
}

check_recipients() {
    step=recipients
    if ! command -v age >/dev/null 2>&1; then
        die "age is not installed; on Ubuntu run: sudo apt-get install age"
    fi
    if [ ! -r "$recipients_file" ]; then
        die "age recipients file not readable: $recipients_file"
    fi
    # The whole design rests on this host not being able to decrypt.
    if grep -q 'AGE-SECRET-KEY' "$recipients_file"; then
        die "$recipients_file contains a private key. Remove it from this host and keep only the public key."
    fi
    if ! printf 'probe' | age -R "$recipients_file" > /dev/null; then
        die "$recipients_file does not hold a usable age public key"
    fi
}

check_disk_space() {
    step=disk-precheck
    free_kb=$(df -Pk "$backup_dir" | awk 'NR == 2 { print $4 }')
    database_bytes=$(pg_query "$postgres_container" 'SELECT pg_database_size(current_database());') \
        || die "could not read the database size from $postgres_container"

    # A dump exists twice for a moment (plain, then encrypted), and it grows.
    # The first run has no history, so it falls back on the live database size.
    estimate_kb=$((database_bytes / 1024))
    for set_path in $(list_sets "$backup_dir"); do
        if is_complete_set "$set_path"; then
            previous_kb=$(du -sk "$set_path" | awk '{ print $1 }')
            if [ $((previous_kb * 3)) -gt "$estimate_kb" ]; then
                estimate_kb=$((previous_kb * 3))
            fi
            break
        fi
    done

    required_kb=$((estimate_kb + min_free_mb * 1024))
    if [ "$free_kb" -lt "$required_kb" ]; then
        die "not enough disk in $backup_dir: $((free_kb / 1024)) MB free, need $((required_kb / 1024)) MB ($((estimate_kb / 1024)) MB for this backup plus BACKUP_MIN_FREE_MB=$min_free_mb)"
    fi
}

encrypt_artifact() {
    # age writes a fixed text header. Anything else means a plain or empty file
    # is about to be published as if it were encrypted.
    if age -R "$recipients_file" -o "$1.age" "$1" \
        && [ "$(head -c 21 "$1.age")" = 'age-encryption.org/v1' ]; then
        sync "$1.age"
        rm -f -- "$1"
        return 0
    fi
    rm -f -- "$1" "$1.age"
    return 1
}

backup_database() {
    step=dump
    dump="$work_dir/db.dump"
    if ! pg_exec "$postgres_container" pg_dump -Fc --lock-wait-timeout="$lock_wait_timeout" < /dev/null > "$dump"; then
        die "pg_dump failed in $postgres_container"
    fi
    if [ ! -s "$dump" ]; then
        die "pg_dump produced an empty file"
    fi

    step=verify
    toc="$work_dir/db.toc"
    if ! pg_exec "$postgres_container" pg_restore --list < "$dump" > "$toc"; then
        die "pg_restore --list rejected the dump"
    fi
    table_count=$(grep -c ' TABLE DATA ' "$toc" || true)
    rm -f -- "$toc"
    if [ "$table_count" -eq 0 ]; then
        die "the dump contains no table data; refusing to publish it as a backup"
    fi
    # --list reads only the table of contents, which sits at the head of the
    # file, so it accepts a truncated dump. Reading it through catches that.
    if ! pg_exec "$postgres_container" pg_restore --file=/dev/null < "$dump"; then
        die "the dump could not be read through to the end"
    fi

    step=encrypt-database
    encrypt_artifact "$dump" || die "encrypting the database dump failed"
}

# Optional artifacts must not cost the day's database backup. A failure here
# publishes the set as degraded, exits 3, and holds back retention.
backup_secrets() {
    secrets_state=skipped
    [ -n "$secrets_dir" ] || return 0

    step=secrets
    secrets_state=failed
    if [ ! -d "$secrets_dir" ]; then
        err "secrets directory not found: $secrets_dir"
        return 0
    fi
    if grep -rlq 'AGE-SECRET-KEY' "$secrets_dir" 2>/dev/null; then
        err "a private age key was found under $secrets_dir; it must not live on this host, so the secrets were NOT backed up"
        return 0
    fi
    if ! tar -C "$(dirname "$secrets_dir")" -cf "$work_dir/secrets.tar" "$(basename "$secrets_dir")"; then
        err "archiving $secrets_dir failed"
        rm -f -- "$work_dir/secrets.tar"
        return 0
    fi
    if encrypt_artifact "$work_dir/secrets.tar"; then
        secrets_state=ok
    else
        err "encrypting the secrets archive failed"
    fi
}

# docker cp needs no tool inside the image and no extra container. RustFS keeps
# serving while it runs, so an avatar being uploaded at this moment may be torn.
backup_rustfs() {
    rustfs_state=skipped
    [ -n "$rustfs_container" ] || return 0

    step=rustfs
    rustfs_state=failed
    if ! container_is_running "$rustfs_container"; then
        err "RustFS container $rustfs_container is not running; avatars were NOT backed up"
        return 0
    fi
    if ! docker cp "$rustfs_container:/data" - > "$work_dir/rustfs.tar"; then
        err "copying /data out of $rustfs_container failed"
        rm -f -- "$work_dir/rustfs.tar"
        return 0
    fi
    if ! tar -tf "$work_dir/rustfs.tar" > /dev/null; then
        err "the RustFS archive is unreadable"
        rm -f -- "$work_dir/rustfs.tar"
        return 0
    fi
    if encrypt_artifact "$work_dir/rustfs.tar"; then
        rustfs_state=ok
    else
        err "encrypting the RustFS archive failed"
    fi
}

write_manifest() {
    step=manifest
    # Only encrypted files may leave this function. This set gets published and
    # copied off-host, so a plain file left by any failure above must not travel.
    find "$work_dir" -type f ! -name '*.age' -delete
    # Recorded for the restore's migration compatibility check. None of it is secret.
    server_version=$(pg_query "$postgres_container" 'SHOW server_version;' 2>/dev/null || echo unknown)
    last_migration=$(pg_query "$postgres_container" 'SELECT migration FROM migrations ORDER BY id DESC LIMIT 1;' 2>/dev/null || echo unknown)
    api_image=$(docker inspect --format '{{.Config.Image}}' "$api_container" 2>/dev/null || echo unknown)
    postgres_image=$(docker inspect --format '{{.Config.Image}}' "$postgres_container" 2>/dev/null || echo unknown)

    set_status=complete
    if [ "$secrets_state" = failed ] || [ "$rustfs_state" = failed ]; then
        set_status=degraded
    fi

    (cd "$work_dir" && sha256sum -- *.age) > "$work_dir/SHA256SUMS"
    {
        printf 'format=1\n'
        printf 'set=%s\n' "$stamp"
        printf 'status=%s\n' "$set_status"
        printf 'host=%s\n' "$(hostname)"
        printf 'postgres_version=%s\n' "$server_version"
        printf 'postgres_image=%s\n' "$postgres_image"
        printf 'api_image=%s\n' "$api_image"
        printf 'last_migration=%s\n' "$last_migration"
        printf 'tables_with_data=%s\n' "$table_count"
        printf 'database=ok\n'
        printf 'secrets=%s\n' "$secrets_state"
        printf 'rustfs=%s\n' "$rustfs_state"
    } > "$work_dir/manifest.env"
    sync "$work_dir"/*
}

publish_set() {
    step=publish
    set_dir="$backup_dir/$stamp"
    if [ -e "$set_dir" ]; then
        die "a set named $stamp already exists"
    fi
    mv -- "$work_dir" "$set_dir" || die "publishing $set_dir failed"
    sync "$backup_dir"
    work_dir=
    published=1

    printf '%s %s %s\n' "$(date +%s)" "$stamp" "$set_status" > "$backup_dir/.last-success.tmp"
    mv -f -- "$backup_dir/.last-success.tmp" "$last_success_file"
}

# Off-host copy. The manifest travels last, so a copy interrupted part way has no
# manifest and retention on the receiving side treats it as incomplete. A failure
# here is reported and never touches the local set.
send_to_remote() {
    remote_state=off
    [ -n "$remote" ] || return 0

    step=remote
    remote_state=failed
    ssh_command="ssh -F none -i $remote_key -p $remote_port -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$remote_known_hosts -o ConnectTimeout=15 -o ServerAliveInterval=30"
    if rsync -rt --chmod=D700,F600 --timeout=120 --exclude=manifest.env -e "$ssh_command" "$set_dir" "$remote" \
        && rsync -rt --chmod=D700,F600 --timeout=120 -e "$ssh_command" "$set_dir" "$remote"; then
        remote_state=ok
    else
        err "the off-host copy to $remote failed; the local set $stamp is kept"
    fi
}

run_backup() {
    started=$(date +%s)
    stamp=$(date -u +%Y%m%dT%H%M%SZ)

    for tool in docker sha256sum tar flock; do
        command -v "$tool" >/dev/null 2>&1 || die "$tool is not installed"
    done
    check_keep
    is_uint "$min_free_mb" || die "BACKUP_MIN_FREE_MB must be a whole number, got: $min_free_mb"

    mkdir -p "$backup_dir" || die "cannot create $backup_dir"
    chmod 0700 "$backup_dir" || die "cannot restrict $backup_dir to mode 0700"

    step=lock
    exec 9> "$backup_dir/.lock"
    flock -n 9 || die "another backup is already running"

    check_recipients

    step=container
    if ! container_is_running "$postgres_container"; then
        die "PostgreSQL container $postgres_container is not running"
    fi

    # Holding the lock means any temporary directory left here belongs to a run
    # that died without cleaning up. It may hold a plain dump, so it goes first.
    find "$backup_dir" -mindepth 1 -maxdepth 1 -type d -name '.tmp-*' -exec rm -rf -- {} +

    check_disk_space

    work_dir=$(mktemp -d "$backup_dir/.tmp-$stamp.XXXXXX")
    log "started set $stamp"

    backup_database
    backup_secrets
    backup_rustfs
    write_manifest
    publish_set
    send_to_remote

    total_bytes=$(du -sb "$set_dir" | awk '{ print $1 }')
    database_sha=$(awk '$2 == "db.dump.age" { print $1 }' "$set_dir/SHA256SUMS")
    summary="set=$stamp status=$set_status bytes=$total_bytes seconds=$(($(date +%s) - started)) secrets=$secrets_state rustfs=$rustfs_state remote=$remote_state db_sha256=$database_sha"

    if [ "$set_status" = complete ] && [ "$remote_state" != failed ]; then
        log "BACKUP_OK $summary"
    else
        err "BACKUP_DEGRADED $summary"
    fi

    if [ "$set_status" = complete ]; then
        step=retention
        apply_retention
    else
        log "retention skipped: set $stamp is degraded"
    fi

    if [ "$set_status" != complete ] || [ "$remote_state" = failed ]; then
        record_problem "set $stamp status=$set_status secrets=$secrets_state rustfs=$rustfs_state remote=$remote_state"
        exit 3
    fi

    rm -f -- "$last_problem_file"
}

case "${1:-}" in
    '')
        trap on_exit EXIT
        trap 'exit 143' TERM
        trap 'exit 130' INT
        run_backup
        ;;
    --check)
        mode=check
        check_freshness
        ;;
    --prune)
        mode=prune
        check_keep
        apply_retention
        ;;
    *)
        printf '%s\n' "Usage: backup.sh [--check|--prune]" >&2
        exit 2
        ;;
esac
