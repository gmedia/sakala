#!/usr/bin/env sh

# Restores a Sakala database backup. By default it restores into a throwaway
# container that has no network, and never touches a running service.
#
#   Into a scratch container (the default), wherever age and Docker exist:
#     restore.sh --set <dir> --identity <age-key> [--image <image>] [--scratch-name <name>] [--keep]
#     restore.sh --dump <file|->                  [--image <image>] [--scratch-name <name>] [--keep]
#
#   Print row counts and checksums of a running database, to compare with a restore:
#     restore.sh --report-container <container>
#
#   Replace a live database. Without --confirm-database this only prints the plan:
#     restore.sh --overwrite-database <container> --dump <file|-> [--confirm-database <name>]
#     restore.sh --overwrite-database <container> --set <dir> --identity <age-key> [--confirm-database <name>]
#
# The overwrite restores into a new database first and swaps names only once that
# succeeded. The old database is renamed, not dropped, so it stays available for
# rollback until an operator removes it.
#
# The private key belongs off the server: decrypt on the workstation and send the
# plain dump over SSH with `--dump -`. See "Restoring" in README.md.
#
# The report goes to stdout and everything else to stderr, so a report can be
# redirected into a file and compared with `diff`.

set -eu
umask 077

set_path=
identity=
dump_source=
scratch_name=
image=${RESTORE_POSTGRES_IMAGE:-postgres:17-alpine}
keep_scratch=0
report_container=
overwrite_container=
confirm_database=

work_dir=
created_scratch=
created_database=
target_container=

usage() {
    sed -n '3,25p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 2
}

log() {
    printf '%s sakala-restore: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
}

die() {
    log "$*"
    exit 1
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --set) set_path=${2:?--set needs a directory}; shift 2 ;;
        --identity) identity=${2:?--identity needs a key file}; shift 2 ;;
        --dump) dump_source=${2:?--dump needs a file or -}; shift 2 ;;
        --image) image=${2:?--image needs an image}; shift 2 ;;
        --scratch-name) scratch_name=${2:?--scratch-name needs a name}; shift 2 ;;
        --keep) keep_scratch=1; shift ;;
        --report-container) report_container=${2:?--report-container needs a name}; shift 2 ;;
        --overwrite-database) overwrite_container=${2:?--overwrite-database needs a container}; shift 2 ;;
        --confirm-database) confirm_database=${2:?--confirm-database needs a name}; shift 2 ;;
        *) usage ;;
    esac
done

# See pg_exec in backup.sh: connection values stay inside the container.
pg_exec() {
    container=$1
    shift
    docker exec -i "$container" sh -c '
        PGUSER=${POSTGRES_USER:-postgres}
        PGDATABASE=${POSTGRES_DB:-$PGUSER}
        export PGUSER PGDATABASE
        exec "$@"' sh "$@"
}

# Same, connected to a named database rather than the one the container serves.
# POSIX sh has no local variables, so nothing here may reuse a caller's name.
pg_exec_in() {
    exec_container=$1
    exec_database=$2
    shift 2
    docker exec -i -e PGDATABASE="$exec_database" "$exec_container" sh -c '
        PGUSER=${POSTGRES_USER:-postgres}
        export PGUSER
        exec "$@"' sh "$@"
}

maintenance_sql() {
    printf '%s\n' "$2" | pg_exec_in "$1" postgres psql -X -At -v ON_ERROR_STOP=1
}

# One line per table: name, row count, and a checksum that ignores row order and
# collation. Sequences and index definitions are included because a dump that
# lost them would still match on rows alone.
print_report() {
    pg_exec "$1" psql -X -At -F "$(printf '\t')" -v ON_ERROR_STOP=1 <<'SQL'
SELECT format(
    'SELECT %L, count(*), coalesce(md5(string_agg(h, '''' ORDER BY h)), ''-'') FROM (SELECT md5(x::text) AS h FROM %I.%I AS x) AS s',
    schemaname || '.' || tablename, schemaname, tablename)
FROM pg_tables
WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
ORDER BY schemaname, tablename
\gexec
SELECT 'sequence:' || schemaname || '.' || sequencename, coalesce(last_value::text, '-'), '-'
FROM pg_sequences
ORDER BY 1;
SELECT 'indexes', count(*), md5(coalesce(string_agg(indexdef, ',' ORDER BY indexdef), ''))
FROM pg_indexes
WHERE schemaname NOT IN ('pg_catalog', 'information_schema');
SQL
}

on_exit() {
    status=$?
    trap - EXIT
    if [ -n "$created_database" ] && [ -n "$target_container" ]; then
        log "removing the unfinished database $created_database; the live database was not touched"
        maintenance_sql "$target_container" "DROP DATABASE IF EXISTS \"$created_database\";" > /dev/null || true
    fi
    if [ -n "$created_scratch" ] && [ "$keep_scratch" -eq 0 ]; then
        docker rm -f -v "$created_scratch" > /dev/null 2>&1 || true
    fi
    if [ -n "$work_dir" ]; then
        rm -rf -- "$work_dir"
    fi
    exit "$status"
}

# A plain dump only ever lands in a private temporary directory, and it is fully
# decrypted before any database is created: a wrong key or a damaged file stops
# here, with nothing else changed.
load_dump() {
    # /tmp can be a tmpfs, and a dump in memory would hurt a small host. On a host
    # that takes backups, its 0700 directory has the room, and a backup run sweeps
    # anything a killed restore left behind.
    work_root=${RESTORE_WORK_DIR:-${TMPDIR:-/tmp}}
    if [ -z "${RESTORE_WORK_DIR:-}" ] && [ -w /var/lib/sakala/backups ]; then
        work_root=/var/lib/sakala/backups
    fi
    work_dir=$(mktemp -d "$work_root/.tmp-restore.XXXXXX")
    plain_dump="$work_dir/db.dump"

    if [ -n "$set_path" ]; then
        [ -f "$set_path/db.dump.age" ] || die "no db.dump.age in $set_path"
        [ -n "$identity" ] || die "--set needs --identity"
        [ -r "$identity" ] || die "cannot read the identity file: $identity"

        if [ -f "$set_path/SHA256SUMS" ]; then
            if ! (cd "$set_path" && sha256sum --quiet -c SHA256SUMS) >&2; then
                die "checksum mismatch in $set_path: this copy is damaged, so use another set"
            fi
        else
            log "no SHA256SUMS in $set_path; relying on age's own authentication"
        fi
        if [ -f "$set_path/manifest.env" ]; then
            log "set metadata: $(grep -E '^(set|status|postgres_version|api_image|last_migration)=' "$set_path/manifest.env" | tr '\n' ' ')"
        fi
        if ! age -d -i "$identity" -o "$plain_dump" "$set_path/db.dump.age"; then
            die "decryption failed: wrong private key, or the artifact is damaged"
        fi
    elif [ "$dump_source" = - ]; then
        cat > "$plain_dump"
    else
        cp -- "$dump_source" "$plain_dump"
    fi

    [ -s "$plain_dump" ] || die "the dump is empty"
}

# Reads the dump through inside the target container, whose pg_restore is the one
# that has to understand it. --list alone accepts a truncated file.
check_dump_in() {
    if ! pg_exec "$1" pg_restore --list < "$plain_dump" > /dev/null; then
        die "this pg_restore cannot read the dump: it is not a custom-format dump, or it comes from a newer PostgreSQL major version"
    fi
    if ! pg_exec "$1" pg_restore --file=/dev/null < "$plain_dump"; then
        die "the dump is truncated or damaged"
    fi
}

restore_scratch() {
    load_dump

    if [ -z "$scratch_name" ]; then
        scratch_name=sakala-restore-$(date -u +%Y%m%dt%H%M%Sz)
    fi
    if docker inspect "$scratch_name" > /dev/null 2>&1; then
        die "a container named $scratch_name already exists; choose another --scratch-name"
    fi

    log "starting scratch container $scratch_name from $image, without network"
    # Trust is safe here only because of --network none: exec is the only way in.
    docker run -d --name "$scratch_name" --network none \
        --security-opt no-new-privileges \
        -e POSTGRES_HOST_AUTH_METHOD=trust \
        -e POSTGRES_USER=sakala_restore \
        -e POSTGRES_DB=sakala_restore \
        "$image" > /dev/null
    created_scratch=$scratch_name

    # The image's init phase answers on the socket before the real server starts,
    # so only loopback TCP proves the database is ready.
    attempt=0
    until docker exec "$scratch_name" pg_isready -q -h 127.0.0.1 -U sakala_restore; do
        attempt=$((attempt + 1))
        [ "$attempt" -lt 120 ] || die "scratch PostgreSQL did not become ready"
        sleep 1
    done

    check_dump_in "$scratch_name"

    started=$(date +%s)
    log "restoring into $scratch_name"
    if ! pg_exec "$scratch_name" pg_restore --exit-on-error --single-transaction --no-owner --no-privileges --dbname=sakala_restore < "$plain_dump"; then
        die "pg_restore failed; see the error above"
    fi
    log "restored in $(($(date +%s) - started)) s"

    print_report "$scratch_name"

    if [ "$keep_scratch" -eq 1 ]; then
        log "scratch container kept. Inspect: docker exec -it $scratch_name psql -U sakala_restore sakala_restore"
        log "remove it with: docker rm -f -v $scratch_name"
    else
        log "scratch container will be removed; use --keep to inspect it"
    fi
}

overwrite_database() {
    target=$overwrite_container
    [ "$(docker inspect --format '{{.State.Running}}' "$target" 2>/dev/null || true)" = true ] \
        || die "container $target is not running"

    # shellcheck disable=SC2016
    database=$(docker exec "$target" sh -c 'printf %s "${POSTGRES_DB:-${POSTGRES_USER:-postgres}}"')
    stamp=$(date -u +%Y%m%dt%H%M%Sz)
    restore_database="${database}_restore_$stamp"
    previous_database="${database}_pre_restore_$stamp"

    cat >&2 <<PLAN

  DESTRUCTIVE RESTORE into container $target, database "$database".
  Everything written to "$database" after this backup was taken leaves the live database.

    1. Refuse to continue if any client is connected to "$database".
    2. Create "$restore_database" and restore the dump into it, in one transaction.
    3. Rename "$database" to "$previous_database", and "$restore_database" to "$database", in one transaction.
    4. Leave "$previous_database" in place as the rollback. Nothing is dropped.

  Stop the deploy timer and the application services first (see README.md).

PLAN

    if [ "$confirm_database" != "$database" ]; then
        log "nothing was changed. To proceed, repeat the command with: --confirm-database $database"
        exit 2
    fi

    load_dump
    check_dump_in "$target"

    connected_sql="SELECT count(*) FROM pg_stat_activity WHERE datname = '$database' AND pid <> pg_backend_pid();"
    connected=$(maintenance_sql "$target" "$connected_sql")
    if [ "$connected" != 0 ]; then
        die "$connected client(s) are still connected to $database. Stop the application services first; nothing was changed."
    fi

    target_container=$target
    created_database=$restore_database
    maintenance_sql "$target" "CREATE DATABASE \"$restore_database\";" > /dev/null

    log "restoring into $restore_database"
    if ! pg_exec_in "$target" "$restore_database" pg_restore --exit-on-error --single-transaction --no-owner --no-privileges --dbname="$restore_database" < "$plain_dump"; then
        die "pg_restore failed; see the error above. The live database was not touched."
    fi

    # A client that connected since the check above makes this fail, and the
    # transaction leaves both names as they were.
    if ! printf '%s\n' \
        "BEGIN;" \
        "ALTER DATABASE \"$database\" RENAME TO \"$previous_database\";" \
        "ALTER DATABASE \"$restore_database\" RENAME TO \"$database\";" \
        "COMMIT;" | pg_exec_in "$target" postgres psql -X -q -At -v ON_ERROR_STOP=1; then
        die "swapping the databases failed; the live database was not touched"
    fi
    created_database=

    log "RESTORE_OK \"$database\" now holds the backup, and the old data is in \"$previous_database\""
    log "roll back: ALTER DATABASE \"$database\" RENAME TO \"${database}_failed_$stamp\"; ALTER DATABASE \"$previous_database\" RENAME TO \"$database\";"
    log "once verified, free the disk: DROP DATABASE \"$previous_database\";"
    log "next: run the migration for the current image, start the services, then start the timers again (see README.md)"
}

if [ -n "$report_container" ]; then
    print_report "$report_container"
    exit 0
fi

if [ -n "$set_path" ] && [ -n "$dump_source" ]; then
    die "use either --set or --dump, not both"
fi

trap on_exit EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

if [ -n "$overwrite_container" ]; then
    if [ -z "$set_path" ] && [ -z "$dump_source" ]; then
        usage
    fi
    overwrite_database
else
    if [ -z "$set_path" ] && [ -z "$dump_source" ]; then
        usage
    fi
    if [ -n "$confirm_database" ]; then
        die "--confirm-database only applies to --overwrite-database"
    fi
    restore_scratch
fi
