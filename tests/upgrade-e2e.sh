#!/usr/bin/env bash

# End-to-end test of upgrading an existing installation from the previous pins in
# versions.env to the current ones, on a fresh, disposable Ubuntu machine with
# systemd (.github/workflows/upgrade-e2e.yml). Like tests/install-e2e.sh, whose
# checks it reuses, it changes the machine for real. Never run it on a server you
# want to keep.
#
# Usage:
#   tests/upgrade-e2e.sh from-ref [<ref>]   print E2E_FROM_SHA=, E2E_TO_SHA=, and E2E_DOMAIN= for
#                                           the previous pins, ready for $GITHUB_ENV
#   sudo -E tests/upgrade-e2e.sh <phase>
#     prepare      git clone this repository to /opt/sakala at E2E_FROM_SHA, as an operator
#                  would, then /etc/hosts entries and an age key
#     install      the old install.sh --tls internal, non-interactive
#     verify       services healthy, API and Console over HTTPS, the old agent ready with runsc
#     deploy       log in as the admin, deploy a project, fetch it, remember the state
#     upgrade      git checkout E2E_TO_SHA in /opt/sakala, upgrade.sh, then check the backup it
#                  took, the migrations and the workspace backfill, every service and pin, the
#                  agent version, the old project without a redeploy, a new deployment, and the
#                  admin overview
#     diagnostics <dir>   collect logs into <dir> with secrets redacted
#
# "The previous pins" are versions.env as it was just before its last change that
# moved a pin: the parent of the newest commit touching versions.env whose pins differ
# from HEAD's. from-ref <ref> uses <ref> instead.
#
# The domain follows the old agent. Sakala Agent before v0.6.0 deploys only under the
# hosted suffixes (run.sakala.localhost, run.staging.sakala.dev, run.sakala.dev), so
# an installation of those pins can deploy only as sakala.localhost, which is what the
# install test of that time used. From v0.6.0 the test uses the self-hosted sakala.test.
#
# Environment (prepare and later phases):
#   SAKALA_E2E_DISPOSABLE_HOST=yes   required; confirms this machine may be changed
#   E2E_FROM_SHA, E2E_TO_SHA         commits of this repository, from from-ref
#   E2E_DOMAIN                       the domain from from-ref
#   E2E_GITHUB_TOKEN, E2E_REPOSITORY, E2E_BRANCH, E2E_ROOT_DIRECTORY   as in tests/install-e2e.sh

set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)

# The pin lines of versions.env at <commit>, sorted, or nothing if it has no versions.env.
pins() { { git -C "$repo" show "$1:versions.env" 2> /dev/null || true; } | { grep -E '^SAKALA_[A-Z0-9_]+=' || true; } | sort; }
# pin <commit> <name>
pin() { { git -C "$repo" show "$1:versions.env" 2> /dev/null || true; } | sed -n "s/^$2=//p"; }
version_at_least() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n 1)" = "$2" ]; }

phase_from_ref() {
    local given=${1:-} from='' commit parent agent domain
    if [ -n "$given" ]; then
        from=$(git -C "$repo" rev-parse --verify --quiet "$given^{commit}") ||
            { printf '::error::%s is not a commit of this repository.\n' "$given" >&2; exit 1; }
    else
        while read -r commit; do
            parent=$(git -C "$repo" rev-parse --verify --quiet "$commit^") || continue
            [ -n "$(pins "$parent")" ] || continue
            if [ "$(pins "$parent")" != "$(pins HEAD)" ]; then
                from=$parent
                break
            fi
        done < <(git -C "$repo" log --format=%H HEAD -- versions.env)
        [ -n "$from" ] || { printf '::error::No earlier commit has different pins in versions.env.\n' >&2; exit 1; }
    fi
    [ -n "$(pins "$from")" ] || { printf '::error::%s has no versions.env.\n' "$from" >&2; exit 1; }
    [ "$(pins "$from")" != "$(pins HEAD)" ] ||
        { printf '::error::%s pins the same versions as HEAD, so there is nothing to upgrade.\n' "$from" >&2; exit 1; }

    agent=$(pin "$from" SAKALA_AGENT_VERSION)
    if version_at_least "${agent#v}" 0.6.0; then domain=sakala.test; else domain=sakala.localhost; fi
    {
        printf 'From %s: API %s, Console %s, agent %s\n' "$(git -C "$repo" log -1 --format='%h %s' "$from")" \
            "$(pin "$from" SAKALA_API_VERSION)" "$(pin "$from" SAKALA_CONSOLE_VERSION)" "$agent"
        printf 'To   %s: API %s, Console %s, agent %s\n' "$(git -C "$repo" log -1 --format='%h %s' HEAD)" \
            "$(pin HEAD SAKALA_API_VERSION)" "$(pin HEAD SAKALA_CONSOLE_VERSION)" "$(pin HEAD SAKALA_AGENT_VERSION)"
        printf 'Domain %s\n' "$domain"
    } >&2
    printf 'E2E_FROM_SHA=%s\nE2E_TO_SHA=%s\nE2E_DOMAIN=%s\n' "$from" "$(git -C "$repo" rev-parse HEAD)" "$domain"
}

if [ "${1:-}" = from-ref ]; then
    shift
    phase_from_ref "$@"
    exit 0
fi

# shellcheck source=tests/install-e2e.sh
. "$repo/tests/install-e2e.sh"
# Its deploy phase, kept under another name before this file defines its own phases.
eval "install_$(declare -f phase_deploy)"

from_sha=${E2E_FROM_SHA:-}
to_sha=${E2E_TO_SHA:-}
case ${1:-} in
    prepare | install | verify | deploy | upgrade)
        if [ -z "$from_sha" ] || [ -z "$to_sha" ] || [ -z "${E2E_DOMAIN:-}" ]; then
            fail "Set E2E_FROM_SHA, E2E_TO_SHA, and E2E_DOMAIN from: tests/upgrade-e2e.sh from-ref"
        fi
        ;;
esac

warning() { printf '::warning::%s\n' "$*"; }

# sql <query>: one query against the control plane database, unaligned output.
sql() {
    # shellcheck disable=SC2016 # expanded by the shell inside the container
    sc exec -T postgres sh -c 'psql -X -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tA -F " " -v ON_ERROR_STOP=1 -c "$1"' sh "$1"
}

project_containers() { docker ps -q --filter label=dev.sakala.managed=true | xargs -r docker inspect --format '{{.Id}} {{.State.StartedAt}}'; }

phase_prepare() {
    step "Cloning this repository to $home at the previous pins"
    [ ! -e "$home" ] || fail "$home already exists; this test needs a fresh machine."
    # The checkout belongs to the runner user, and this runs as root.
    git -c safe.directory='*' clone --quiet --no-checkout "$repo" "$home"
    git -C "$home" checkout --quiet --detach "$from_sha"
    pass "$home is a git checkout of $(git -C "$home" log -1 --format='%h %s')"
    note "pins: API $(pin "$from_sha" SAKALA_API_VERSION), Console $(pin "$from_sha" SAKALA_CONSOLE_VERSION), agent $(pin "$from_sha" SAKALA_AGENT_VERSION)"
    prepare_machine
}

phase_install() {
    step "install.sh --tls internal with the previous pins"
    local log="$state/install.log" status=0
    "$home/install.sh" --domain "$domain" --email "$email" \
        --age-recipient "$(cat "$state/backup.recipient")" --tls internal --yes 2>&1 | tee "$log" || status=${PIPESTATUS[0]}
    case $status in
        0) pass "install.sh exited 0" ;;
        3)
            # Installers before the 2026-11-12 release finish everything, then exit 3
            # when the pinned Console cannot be pointed at api.<domain>. Their own
            # install test accepted exactly that, and the upgrade is what fixes it.
            grep -q 'cannot be pointed at api' "$log" || fail "install.sh exited 3 for another reason than the Console."
            warning "The old install.sh exited 3 because its Console ($(pin "$from_sha" SAKALA_CONSOLE_VERSION)) cannot be pointed at api.$domain, as expected for those pins."
            ;;
        *) fail "install.sh exited $status." ;;
    esac
    remember_secrets
    [ -s /etc/sakala/secrets/initial-admin-password ] || fail "install.sh did not store the admin password"
    pass "admin password stored in /etc/sakala/secrets/initial-admin-password"
}

phase_verify() {
    # The services of the old compose.yaml, which may differ from the current list.
    mapfile -t services < <(sc config --services)
    check_services
    check_https
    check_agent_ready
}

phase_deploy() {
    [ -s "$ca" ] || fetch_ca || fail "No local CA root certificate; run the verify phase first."
    # The install test's deploy phase: project, inspection, deployment, 200, runsc.
    local project_id
    install_phase_deploy
    project_id=$(sed -n 1p "$state/project")

    step "Remembering the state before the upgrade"
    {
        printf 'admin_id=%s\n' "$(sql "select id from users where email = '$email'")"
        printf 'deployments=%s\n' "$(sql "select count(*) from deployments where project_id = '$project_id'")"
        printf 'migrations=%s\n' "$(sql 'select count(*) from migrations')"
        printf 'last_migration=%s\n' "$(sql 'select migration from migrations order by id desc limit 1')"
    } > "$state/before.env"
    project_containers > "$state/before-containers"
    [ "$(sql "select count(*) from users")" = 1 ] || note "more than one user exists"
    sed 's/^/     /' "$state/before.env"
}

backup_check() {
    local before=$1 set name
    grep -q 'Backup complete' "$state/upgrade.log" || fail "upgrade.sh did not report a complete backup."
    [ "$(backup_sets)" -gt "$before" ] || fail "upgrade.sh did not write a new backup set."
    set=$(find /var/lib/sakala/backups -mindepth 2 -maxdepth 2 -name manifest.env -printf '%h\n' | sort | tail -n 1)
    name=$(basename "$set")
    pass "upgrade.sh backed up first: set $name"

    step "The backup is complete, from before the upgrade, and restores"
    grep -qx 'status=complete' "$set/manifest.env" || fail "The set is not complete: $(tr '\n' ' ' < "$set/manifest.env")"
    grep -qxF "api_image=$(pin "$from_sha" SAKALA_API_IMAGE)" "$set/manifest.env" ||
        fail "The set was not taken from the old API image: $(grep '^api_image=' "$set/manifest.env")"
    grep -qxF "last_migration=$last_migration" "$set/manifest.env" ||
        fail "The set's last migration is not the one before the upgrade ($last_migration): $(grep '^last_migration=' "$set/manifest.env")"
    pass "manifest: status=complete, old API image, last migration $last_migration"
    "$home/scripts/backup.sh" --check || fail "backup.sh --check fails after the upgrade."
    [ "$(awk '{ print $2 }' /var/lib/sakala/backups/last-success)" = "$name" ] ||
        fail "last-success names $(cat /var/lib/sakala/backups/last-success), not $name."
    pass "backup.sh --check passes and records $name as the last success"
    (cd "$set" && sha256sum -c --quiet SHA256SUMS) || fail "The set fails its SHA256SUMS."

    local scratch=sakala-e2e-restore
    "$home/scripts/restore.sh" --set "$set" --identity "$state/backup.key" --image "$SAKALA_POSTGRES_IMAGE" \
        --scratch-name "$scratch" --keep > "$state/restore-report.txt" 2> "$state/restore.log" ||
        { cat "$state/restore.log" >&2; fail "restore.sh could not restore the set into a scratch database."; }
    scratch_sql() { docker exec "$scratch" psql -X -U sakala_restore -d sakala_restore -tA -c "$1"; }
    [ "$(scratch_sql "select count(*) from projects where id = '$project_id'")" = 1 ] || fail "The restored set lacks project $project_id."
    [ "$(scratch_sql "select count(*) from users where id = $admin_id")" = 1 ] || fail "The restored set lacks the admin."
    [ "$(scratch_sql 'select migration from migrations order by id desc limit 1')" = "$last_migration" ] ||
        fail "The restored set has another last migration than before the upgrade."
    docker rm -f -v "$scratch" > /dev/null
    pass "restore.sh restored it into a scratch database with $(wc -l < "$state/restore-report.txt") report lines: the admin, the project, and the old schema"
}

check_migrations() {
    step "The migrations ran"
    local status pending ran
    status=$(sc exec -T api php artisan migrate:status --no-ansi 2>&1) || { printf '%s\n' "$status" >&2; fail "migrate:status failed."; }
    pending=$(grep -c 'Pending' <<< "$status" || true)
    [ "$pending" -eq 0 ] || { grep 'Pending' <<< "$status" >&2; fail "$pending migration(s) are pending after the upgrade."; }
    ran=$(sql 'select count(*) from migrations')
    [ "$ran" -gt "$migrations" ] || fail "No migration ran during the upgrade ($ran before and after)."
    pass "$((ran - migrations)) migration(s) ran, none pending:"
    sql "select migration from migrations order by id offset $migrations" | sed 's/^/       /'
}

check_workspace_backfill() {
    step "The existing user got a personal workspace that owns the existing project"
    local workspace workspaces listed
    [ "$(sql "select to_regclass('public.workspaces') is not null")" = t ] || fail "The new schema has no workspaces table."
    workspace=$(sql "select id from workspaces where personal_user_id = $admin_id and type = 'personal'")
    [ -n "$workspace" ] || fail "User $admin_id has no personal workspace."
    [ "$(sql "select role from workspace_members where workspace_id = '$workspace' and user_id = $admin_id")" = owner ] ||
        fail "User $admin_id is not the owner of its personal workspace."
    [ "$(sql "select workspace_id from projects where id = '$project_id'")" = "$workspace" ] ||
        fail "Project $project_id is not in workspace $workspace: $(sql "select coalesce(workspace_id::text, 'null') from projects where id = '$project_id'")"
    [ "$(sql "select count(*) from projects where deleted_at is null and workspace_id is null")" = 0 ] ||
        fail "Some live projects have no workspace."
    pass "database: personal workspace $workspace, owner $admin_id, holds project $project_id"

    workspaces=$(api_json 200 GET /api/v1/app/workspaces)
    jq -e --arg id "$workspace" '.data | any(.id == $id and .type == "personal" and .role == "owner" and .projects_count >= 1)' \
        <<< "$workspaces" > /dev/null || fail "GET /api/v1/app/workspaces does not show it: $(jq -c '.data' <<< "$workspaces")"
    listed=$(api_json 200 GET /api/v1/app/projects)
    jq -e --arg id "$project_id" --arg ws "$workspace" '.data | any(.id == $id and .workspace.id == $ws)' <<< "$listed" > /dev/null ||
        fail "GET /api/v1/app/projects does not list the project in its workspace: $(jq -c '[.data[] | {id, workspace}]' <<< "$listed")"
    pass "API: the admin sees the personal workspace as owner, and the project listed in it"
}

check_pins() {
    step "Every service runs its image from the current versions.env"
    local service variable want got edge
    edge=$(env_get_file /etc/sakala/sakala.env SAKALA_EDGE_IMAGE)
    while read -r service variable; do
        want=$(pin "$to_sha" "$variable")
        [ "$service" != edge ] || [ -z "$edge" ] || want=$edge
        got=$(docker inspect --format '{{.Config.Image}}' "$(sc ps -q "$service")")
        [ "$got" = "$want" ] || fail "$service runs $got, expected $want ($variable)."
    done << 'EOF'
postgres SAKALA_POSTGRES_IMAGE
valkey SAKALA_VALKEY_IMAGE
rustfs SAKALA_STORAGE_IMAGE
api SAKALA_API_IMAGE
api-web SAKALA_API_WEB_IMAGE
reverb SAKALA_API_IMAGE
queue SAKALA_API_IMAGE
scheduler SAKALA_API_IMAGE
console SAKALA_CONSOLE_IMAGE
runtime-caddy SAKALA_CADDY_IMAGE
edge SAKALA_CADDY_IMAGE
EOF
    pass "API $(pin "$to_sha" SAKALA_API_VERSION) and Console $(pin "$to_sha" SAKALA_CONSOLE_VERSION) by digest, and the third-party pins"
}

env_get_file() { sed -n "s/^$2=//p" "$1" | tail -n 1; }

agent_version_reported() {
    local agents
    agents=$(api_json 200 GET /api/v1/admin/agents) || return 1
    reported=$(jq -r --arg id "$agent_id" '.data[] | select(.agent_id == $id) | .agent_version // ""' <<< "$agents")
    [ "$reported" = "${want_agent#v}" ] || [ "$reported" = "$want_agent" ]
}

check_agent_version() {
    step "The agent runs and reports $(pin "$to_sha" SAKALA_AGENT_VERSION)"
    local want_agent reported='' agent_id
    want_agent=$(pin "$to_sha" SAKALA_AGENT_VERSION)
    agent_id=$(sed -n 's/^SAKALA_AGENT_ID=//p' /etc/sakala/secrets/agent-credentials.env)
    [ "$(sha /usr/local/bin/sakala-agent)" = "$(pin "$to_sha" SAKALA_AGENT_SHA256)" ] ||
        fail "/usr/local/bin/sakala-agent does not match SAKALA_AGENT_SHA256 of $want_agent."
    pass "/usr/local/bin/sakala-agent matches SAKALA_AGENT_SHA256 of $want_agent"
    retry 24 5 agent_version_reported || fail "GET /api/v1/admin/agents reports agent version '${reported:-none}' for $agent_id, expected $want_agent."
    pass "GET /api/v1/admin/agents reports $agent_id at version $reported, same agent id as before"
}

check_old_project() {
    step "The project deployed before the upgrade still answers, without a redeploy"
    retry 30 2 https_ok "https://$host/" || fail "https://$host/ answered $(https_status "https://$host/") after the upgrade, expected 200"
    [ "$(sql "select count(*) from deployments where project_id = '$project_id'")" = "$deployments" ] ||
        fail "The upgrade created a deployment for the project."
    pass "https://$host/ 200, still $deployments deployment(s)"
    if [ "$(project_containers)" = "$(cat "$state/before-containers")" ]; then
        pass "the project container kept running through the upgrade (same container, same start time)"
    else
        note "the project container was restarted or replaced: before $(cat "$state/before-containers"), after $(project_containers)"
    fi
}

check_admin_overview() {
    step "The admin overview answers for the admin"
    local overview
    overview=$(api_json 200 GET /api/v1/admin/overview)
    jq -e '.data | type == "object" and length > 0' <<< "$overview" > /dev/null || fail "GET /api/v1/admin/overview has no data: ${overview:0:300}"
    pass "GET /api/v1/admin/overview 200 with $(jq -r '.data | keys | join(", ")' <<< "$overview" | cut -c1-200)"
}

phase_upgrade() {
    local admin_id deployments migrations last_migration project_id host sets_before
    # shellcheck disable=SC1091
    . "$state/before.env"
    project_id=$(sed -n 1p "$state/project")
    host=$(sed -n 2p "$state/project")
    sets_before=$(backup_sets)

    step "git checkout of the current commit in $home, as README.md's Upgrade section does"
    git -C "$home" checkout --quiet --detach "$to_sha" || fail "git checkout $to_sha in $home failed: $(git -C "$home" status --short)"
    pass "$home is at $(git -C "$home" log -1 --format='%h %s')"
    # shellcheck disable=SC1091
    . "$home/versions.env"

    step "upgrade.sh from the previous pins"
    run_script upgrade "$home/upgrade.sh"
    backup_check "$sets_before"
    grep -q 'Creating the first admin account' "$state/upgrade.log" && fail "upgrade.sh tried to create the admin again."
    check_migrations

    check_services
    check_https
    check_console_config
    check_agent
    check_pins
    check_old_project

    login
    check_workspace_backfill
    check_agent_version

    step "A new deployment of the existing project"
    deploy_project "$project_id" "e2e-upgrade-$project_id"
    fetch_project "$host"
    check_project_runtime

    check_admin_overview
}

case ${1:-} in
    prepare | install | verify | deploy | upgrade | diagnostics)
        phase=$1
        shift
        "phase_$phase" "$@"
        ;;
    *)
        sed -n '3,37p' "$0" | sed 's/^# \{0,1\}//'
        exit 2
        ;;
esac
