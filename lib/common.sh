# shellcheck shell=bash
# Shared by install.sh, upgrade.sh, and uninstall.sh. Sourced, never executed.

SAKALA_HOME=${SAKALA_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
SAKALA_CONFIG_DIR=${SAKALA_CONFIG_DIR:-/etc/sakala}
SAKALA_SECRETS_DIR=${SAKALA_SECRETS_DIR:-$SAKALA_CONFIG_DIR/secrets}
SAKALA_STATE_DIR=${SAKALA_STATE_DIR:-/var/lib/sakala}
SAKALA_ENV_FILE="$SAKALA_CONFIG_DIR/sakala.env"
SAKALA_VERSIONS_FILE="$SAKALA_HOME/versions.env"

# SAKALA_DRY_RUN=1 runs everything that needs neither a Docker daemon nor systemd
# for real (input checks, downloads and their checksums, secrets, rendered files,
# `docker compose config`) and prints the rest. tests/dry-run.sh uses it.
SAKALA_DRY_RUN=${SAKALA_DRY_RUN:-0}

if [ -t 1 ]; then
    _bold=$'\033[1m' _red=$'\033[31m' _yellow=$'\033[33m' _reset=$'\033[0m'
else
    _bold='' _red='' _yellow='' _reset=''
fi

step() { printf '\n%s==> %s%s\n' "$_bold" "$*" "$_reset"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '%s    ! %s%s\n' "$_yellow" "$*" "$_reset" >&2; }
die() {
    printf '%sError: %s%s\n' "$_red" "$*" "$_reset" >&2
    exit 1
}

is_dry_run() { [ "$SAKALA_DRY_RUN" = 1 ]; }

# For commands that need a running Docker daemon or systemd.
live() {
    if is_dry_run; then
        printf '    [dry-run] %s\n' "$*"
        return 0
    fi
    "$@"
}

require_root() {
    [ "$(id -u)" -eq 0 ] || die "Run this as root, for example: sudo $0"
}

# Ubuntu 24.04 and 26.04 on x86_64 are what the agent releases and gVisor were
# tested on. Anything else is refused rather than half-installed.
check_os() {
    [ -r /etc/os-release ] || die "Cannot read /etc/os-release; only Ubuntu 24.04 and 26.04 are supported."
    local id version pretty
    id=$(. /etc/os-release && printf '%s' "${ID:-}")
    version=$(. /etc/os-release && printf '%s' "${VERSION_ID:-}")
    pretty=$(. /etc/os-release && printf '%s' "${PRETTY_NAME:-unknown}")
    if [ "$id" != ubuntu ] || { [ "$version" != 24.04 ] && [ "$version" != 26.04 ]; }; then
        die "Unsupported system: $pretty. Sakala installs on Ubuntu 24.04 or 26.04."
    fi
    [ "$(uname -m)" = x86_64 ] || die "Unsupported architecture $(uname -m). Agent and gVisor releases are x86_64 only."
    if ! is_dry_run && [ ! -d /run/systemd/system ]; then
        die "systemd is not running. Sakala needs a full server or VM, not a container."
    fi
}

valid_domain() {
    [[ $1 =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]] && [ "${#1}" -le 200 ]
}

valid_email() {
    [[ $1 =~ ^[A-Za-z0-9._%+-]+@([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

valid_age_recipient() {
    [[ $1 =~ ^age1[02-9ac-hj-np-z]{58}$ ]]
}

# Reads KEY=value lines without evaluating them, so a value is never run as code.
env_get() {
    local file=$1 key=$2
    [ -r "$file" ] || return 0
    sed -n "s/^$key=//p" "$file" | tail -n 1
}

load_versions() {
    [ -r "$SAKALA_VERSIONS_FILE" ] || die "Missing $SAKALA_VERSIONS_FILE."
    local name value
    while IFS='=' read -r name value; do
        case $name in '' | \#*) continue ;; esac
        [[ $name =~ ^SAKALA_[A-Z0-9_]+$ ]] || die "Unexpected line in versions.env: $name"
        printf -v "$name" '%s' "$value"
        export "${name?}"
    done < "$SAKALA_VERSIONS_FILE"
}

# A tag can be moved to other content; a digest cannot.
assert_pinned() {
    local name value
    for name in SAKALA_API_IMAGE SAKALA_API_WEB_IMAGE SAKALA_CONSOLE_IMAGE SAKALA_POSTGRES_IMAGE \
        SAKALA_VALKEY_IMAGE SAKALA_STORAGE_IMAGE SAKALA_CADDY_IMAGE; do
        value=${!name:-}
        [[ $value =~ @sha256:[0-9a-f]{64}$ ]] || die "$name must be pinned by digest (image@sha256:...), got: ${value:-empty}"
    done
    [[ ${SAKALA_AGENT_SHA256:-} =~ ^[0-9a-f]{64}$ ]] || die "SAKALA_AGENT_SHA256 must be a sha256 hex digest."
    [[ ${SAKALA_AGENT_COMMIT:-} =~ ^[0-9a-f]{40}$ ]] || die "SAKALA_AGENT_COMMIT must be a full commit hash."
    [[ ${SAKALA_GVISOR_SHA512:-} =~ ^[0-9a-f]{128}$ ]] || die "SAKALA_GVISOR_SHA512 must be a sha512 hex digest."
}

compose() {
    docker compose --project-directory "$SAKALA_HOME" -f "$SAKALA_HOME/compose.yaml" \
        --env-file "$SAKALA_ENV_FILE" --env-file "$SAKALA_VERSIONS_FILE" "$@"
}

# Replaces ${NAME} for each NAME given, in pure bash, so no value is ever
# interpreted by sed or a shell. Unknown placeholders are an error.
render() {
    local template=$1 output=$2 mode=$3
    shift 3
    local content name
    content=$(< "$template")
    for name in "$@"; do
        content=${content//\$\{$name\}/${!name}}
    done
    if [[ $content =~ \$\{(SAKALA_[A-Z0-9_]+)\} ]]; then
        die "$template still has \${${BASH_REMATCH[1]}} after rendering."
    fi
    write_file "$output" "$mode" <<< "$content"
}

# Atomic write with the final mode set before any content lands.
write_file() {
    local output=$1 mode=$2 tmp
    tmp=$(mktemp "$(dirname "$output")/.$(basename "$output").XXXXXX")
    chmod "$mode" "$tmp"
    cat > "$tmp"
    mv -f "$tmp" "$output"
}

wait_http() {
    local label=$1 url=$2 attempts=${3:-60}
    if is_dry_run; then
        printf '    [dry-run] wait for %s at %s\n' "$label" "$url"
        return 0
    fi
    local i
    for ((i = 0; i < attempts; i++)); do
        if curl -fsS -o /dev/null --max-time 5 "$url"; then
            info "$label is up."
            return 0
        fi
        sleep 2
    done
    return 1
}
