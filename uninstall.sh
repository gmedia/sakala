#!/usr/bin/env bash

# Removes Sakala from this server: deployed projects, the control plane and its
# data, the agent, the units, and the configuration. Encrypted backups in
# /var/lib/sakala/backups are kept unless --delete-backups is given. Docker
# Engine and gVisor stay installed.
#
# Usage: sudo ./uninstall.sh [--no-final-backup] [--delete-backups] [--yes]
#
# By default it first takes one last backup, so the data survives in a set that
# your age private key can restore.

set -euo pipefail

# shellcheck source=lib/common.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

final_backup=1
delete_backups=0
assume_yes=0
while [ "$#" -gt 0 ]; do
    case $1 in
        --no-final-backup) final_backup=0; shift ;;
        --delete-backups) delete_backups=1; shift ;;
        --yes | -y) assume_yes=1; shift ;;
        --dry-run) export SAKALA_DRY_RUN=1; shift ;;
        -h | --help) sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
done

require_root
domain=$(env_get "$SAKALA_ENV_FILE" SAKALA_DOMAIN)

printf 'This removes Sakala%s from this server, including every deployed project\n' "${domain:+ for $domain}"
printf 'and the database. '
if [ "$delete_backups" -eq 1 ]; then
    printf 'Backups in %s are deleted too.\n' "$SAKALA_STATE_DIR/backups"
else
    printf 'Backups in %s are kept.\n' "$SAKALA_STATE_DIR/backups"
fi
if [ "$assume_yes" -eq 0 ]; then
    [ -t 0 ] || die "Pass --yes to run without a terminal."
    read -r -p "Type ${domain:-yes} to continue: " answer
    [ "$answer" = "${domain:-yes}" ] || die "Stopped; nothing was changed."
fi

if [ "$final_backup" -eq 1 ] && [ "$delete_backups" -eq 0 ] && [ -f /etc/systemd/system/sakala-backup.service ]; then
    step "Taking a final backup"
    if live systemctl start sakala-backup.service; then
        info "Done; it is in $SAKALA_STATE_DIR/backups."
    else
        die "The final backup failed, so nothing was removed. Fix it, or pass --no-final-backup."
    fi
fi

step "Stopping the agent and the backup timer"
for unit in sakala-agent.service sakala-backup.timer sakala-backup.service; do
    live systemctl disable --now "$unit" 2> /dev/null || true
    rm -f "/etc/systemd/system/$unit"
done
live systemctl daemon-reload

step "Removing deployed projects"
if ! is_dry_run && command -v docker > /dev/null; then
    docker ps -aq --filter label=dev.sakala.managed=true | xargs -r docker rm -f > /dev/null
    docker network ls -q --filter label=dev.sakala.managed=true | xargs -r docker network rm > /dev/null || true
    docker images -q --filter 'reference=sakala/project-*' | sort -u | xargs -r docker rmi -f > /dev/null || true
    docker images -q --filter 'reference=sakala-railpack-sandbox' --filter 'reference=sakala-edge-dns' |
        sort -u | xargs -r docker rmi -f > /dev/null || true
else
    live docker rm -f '<containers labelled dev.sakala.managed=true>'
fi

step "Removing the control plane and its data"
if [ -r "$SAKALA_ENV_FILE" ]; then
    live compose --profile operations down --volumes --remove-orphans
fi
if ! is_dry_run && command -v docker > /dev/null; then
    docker network rm sakala-runtime sakala-railpack > /dev/null 2>&1 || true
fi

step "Removing files"
rm -f /usr/local/bin/sakala-agent /usr/local/bin/sakala-compose
rm -rf "$SAKALA_CONFIG_DIR"
if [ -d "$SAKALA_STATE_DIR" ]; then
    find "$SAKALA_STATE_DIR" -mindepth 1 -maxdepth 1 ! -name backups -exec rm -rf -- {} +
    if [ "$delete_backups" -eq 1 ]; then
        rm -rf "$SAKALA_STATE_DIR"
    fi
fi
if id sakala-agent > /dev/null 2>&1; then
    userdel sakala-agent 2> /dev/null || true
fi

step "Done"
if [ "$delete_backups" -eq 0 ] && [ -d "$SAKALA_STATE_DIR/backups" ]; then
    info "Backups are still in $SAKALA_STATE_DIR/backups. Only your age private key can read them."
fi
info "Docker Engine and gVisor are still installed. To remove gVisor:"
info "  sudo rm -rf /usr/local/bin/runsc /usr/local/bin/containerd-shim-runsc-v1 /usr/local/bin/gvisor-bin"
info "and delete the runsc entry from /etc/docker/daemon.json."
