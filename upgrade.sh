#!/usr/bin/env bash

# Moves an installation to the pins in versions.env: backup first, then pull the
# new images, migrate, restart what changed, and update the agent and gVisor.
#
# Usage:
#   cd /opt/sakala && sudo git fetch --tags && sudo git checkout vX.Y.Z
#   sudo ./upgrade.sh [--skip-backup]
#
# A failed backup stops the upgrade before anything changes. Restoring an image
# does not undo a migration, so going back means restoring the backup this run
# took (README.md, "Backup dan restore").

set -euo pipefail

# shellcheck source=lib/common.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

skip_backup=0
while [ "$#" -gt 0 ]; do
    case $1 in
        --skip-backup) skip_backup=1; shift ;;
        --dry-run) export SAKALA_DRY_RUN=1; shift ;;
        -h | --help) sed -n '3,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
done

require_root
check_os
[ -r "$SAKALA_ENV_FILE" ] || die "$SAKALA_ENV_FILE not found. Run install.sh first."
load_versions
assert_pinned

step "Backing up before the upgrade"
if [ "$skip_backup" -eq 1 ]; then
    warn "Skipping the backup because of --skip-backup."
elif is_dry_run; then
    live systemctl start sakala-backup.service
else
    status=0
    systemctl start sakala-backup.service || true
    status=$(systemctl show -p ExecMainStatus --value sakala-backup.service)
    case $status in
        0) info "Backup complete." ;;
        3) warn "The database was backed up, but secrets, avatars, or the off-host copy were not. Continuing." ;;
        *) die "The backup failed (exit $status), so nothing was upgraded. Check: journalctl -u sakala-backup.service -n 50" ;;
    esac
fi

# The install steps are idempotent and only change what differs from the new pins.
exec "$SAKALA_HOME/install.sh" --upgrade
