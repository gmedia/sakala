#!/usr/bin/env bash

# Installs Sakala on one fresh Ubuntu 24.04 or 26.04 server: Docker Engine
# (rootful), gVisor, the control plane, the runtime router, the public edge with
# automatic HTTPS, the Sakala Agent, and a daily encrypted backup. Safe to run
# again: it keeps generated secrets, the agent's credentials, and your own
# settings, and only changes what differs.
#
# Usage:
#   sudo ./install.sh                         asks for what it needs
#   sudo ./install.sh --domain sakala.example.com --email admin@example.com \
#        --age-recipient age1... [--tls on-demand|dns|internal] [--dns-provider cloudflare] \
#        [--dns-module github.com/caddy-dns/cloudflare@v0.2.4] [--yes]
#
# In DNS mode the provider token is read from SAKALA_DNS_API_TOKEN, or asked for
# without echo. --tls internal uses Caddy's local CA instead of Let's Encrypt,
# for tests and private networks only. See README.md for requirements and an
# existing Docker Engine, and docs/tls.md for the TLS modes.

set -euo pipefail

# shellcheck source=lib/common.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

domain=${SAKALA_DOMAIN:-}
email=${SAKALA_ADMIN_EMAIL:-}
age_recipient=${SAKALA_AGE_RECIPIENT:-}
tls_mode=${SAKALA_TLS_MODE:-}
dns_provider=${SAKALA_DNS_PROVIDER:-}
dns_module=${SAKALA_DNS_MODULE:-}
gvisor_overlay_size=${SAKALA_GVISOR_OVERLAY_SIZE:-}
assume_yes=0
upgrade=0
skip_resource_check=0
edge_restart=0

# What one project may write to its container's root filesystem under gVisor, the
# same cap hosted Sakala sets. Without one, a single project can fill the disk the
# control plane's database shares. SAKALA_GVISOR_OVERLAY_SIZE in sakala.env wins.
default_gvisor_overlay_size=1g

# Known single-token DNS modules, pinned. Any other provider works with
# --dns-provider and --dns-module; see docs/tls.md.
default_dns_module() {
    case $1 in
        cloudflare) printf '%s' 'github.com/caddy-dns/cloudflare@v0.2.4' ;;
        *) printf '' ;;
    esac
}

usage() {
    sed -n '3,19p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while [ "$#" -gt 0 ]; do
    case $1 in
        --domain) domain=${2:?--domain needs a value}; shift 2 ;;
        --email) email=${2:?--email needs a value}; shift 2 ;;
        --age-recipient) age_recipient=${2:?--age-recipient needs a value}; shift 2 ;;
        --tls) tls_mode=${2:?--tls needs on-demand, dns, or internal}; shift 2 ;;
        --dns-provider) dns_provider=${2:?--dns-provider needs a value}; shift 2 ;;
        --dns-module) dns_module=${2:?--dns-module needs a value}; shift 2 ;;
        --yes | -y) assume_yes=1; shift ;;
        --upgrade) upgrade=1; assume_yes=1; shift ;;
        --skip-resource-check) skip_resource_check=1; shift ;;
        --dry-run) SAKALA_DRY_RUN=1; shift ;;
        -h | --help) usage 0 ;;
        *) printf 'Unknown option: %s\n\n' "$1" >&2; usage 2 ;;
    esac
done

ask() {
    local prompt=$1 var=$2 secret=${3:-0} answer
    if [ "$assume_yes" -eq 1 ] || [ ! -t 0 ]; then
        die "$prompt is required. Pass it as an option; see ./install.sh --help."
    fi
    if [ "$secret" -eq 1 ]; then
        read -r -s -p "$prompt: " answer
        printf '\n'
    else
        read -r -p "$prompt: " answer
    fi
    printf -v "$var" '%s' "$answer"
}

check_resources() {
    local cpus mem_mb
    cpus=$(nproc)
    mem_mb=$(awk '/^MemTotal:/ { print int($2 / 1024) }' /proc/meminfo)
    info "This server has $cpus vCPU and $mem_mb MB of memory."
    # 4 GB servers report a little less than 4096 MB.
    if [ "$cpus" -lt 2 ] || [ "$mem_mb" -lt 3500 ]; then
        if [ "$skip_resource_check" -eq 1 ]; then
            warn "Below the minimum of 2 vCPU and 4 GB; continuing because of --skip-resource-check."
        else
            die "Sakala needs at least 2 vCPU and 4 GB of memory. Pass --skip-resource-check to try anyway."
        fi
    fi
    # Room for projects after the control plane (about 2 GB), at the 256 MB default each.
    max_active_containers=$(((mem_mb - 2048) / 256))
    [ "$max_active_containers" -ge 2 ] || max_active_containers=2
    [ "$max_active_containers" -le 20 ] || max_active_containers=20
}

# The docs and legal links the Console shows, and its abuse address. Unset, the
# Console links hosted Sakala's pages; an operator sets their own in
# console.local.env (docs/configuration.md, "Tautan Console").
console_link_keys=(PUBLIC_DOCS_URL PUBLIC_TERMS_URL PUBLIC_ACCEPTABLE_USE_URL PUBLIC_PRIVACY_URL PUBLIC_ABUSE_EMAIL)
console_legal_keys=(PUBLIC_TERMS_URL PUBLIC_ACCEPTABLE_USE_URL PUBLIC_PRIVACY_URL)

# One value from console.local.env, without the quotes Compose would strip.
console_local_get() {
    local value
    value=$(env_get "$SAKALA_SECRETS_DIR/console.local.env" "$1")
    value=${value#[\"\']}
    printf '%s' "${value%[\"\']}"
}

# Checked before anything changes: a value the Console's entrypoint refuses would
# stop the Console after the database was already migrated.
check_console_links() {
    local key value
    for key in "${console_link_keys[@]}"; do
        value=$(console_local_get "$key")
        [ -n "$value" ] || continue
        case $key in
            PUBLIC_ABUSE_EMAIL) valid_email "$value" ;;
            # Page paths are appended to the docs base, so it takes no query or fragment.
            PUBLIC_DOCS_URL) valid_console_link "$value" && [[ $value != *[?#]* ]] ;;
            *) valid_console_link "$value" ;;
        esac || die "$key in $SAKALA_SECRETS_DIR/console.local.env is not valid: $value. Read \"Tautan Console\" in docs/configuration.md."
    done
}

collect_inputs() {
    local saved
    if [ -r "$SAKALA_ENV_FILE" ]; then
        saved=$(env_get "$SAKALA_ENV_FILE" SAKALA_DOMAIN)
        if [ -n "$domain" ] && [ -n "$saved" ] && [ "$domain" != "$saved" ]; then
            die "This server is installed for $saved. Changing the domain is not supported by install.sh."
        fi
        domain=${domain:-$saved}
        email=${email:-$(env_get "$SAKALA_ENV_FILE" SAKALA_ADMIN_EMAIL)}
        tls_mode=${tls_mode:-$(env_get "$SAKALA_ENV_FILE" SAKALA_TLS_MODE)}
        dns_provider=${dns_provider:-$(env_get "$SAKALA_ENV_FILE" SAKALA_DNS_PROVIDER)}
        dns_module=${dns_module:-$(env_get "$SAKALA_ENV_FILE" SAKALA_DNS_MODULE)}
        gvisor_overlay_size=${gvisor_overlay_size:-$(env_get "$SAKALA_ENV_FILE" SAKALA_GVISOR_OVERLAY_SIZE)}
    elif [ "$upgrade" -eq 1 ]; then
        die "$SAKALA_ENV_FILE not found. Run install.sh first."
    fi
    if [ -z "$age_recipient" ] && [ -r "$SAKALA_SECRETS_DIR/backup.age-recipients" ]; then
        age_recipient=$(grep -m 1 '^age1' "$SAKALA_SECRETS_DIR/backup.age-recipients" || true)
    fi

    [ -n "$domain" ] || ask "Domain for this installation (app., api., and *.run. go under it)" domain
    domain=$(printf '%s' "$domain" | tr '[:upper:]' '[:lower:]')
    valid_domain "$domain" || die "Not a domain name: $domain"

    [ -n "$email" ] || ask "Admin email (first admin account, and Let's Encrypt notices)" email
    valid_email "$email" || die "Not an email address: $email"

    if [ -z "$age_recipient" ]; then
        info "Backups are encrypted to an age public key. Make one on your own computer:"
        info "  age-keygen -o sakala-backup.key && age-keygen -y sakala-backup.key"
        info "Keep sakala-backup.key there, never on this server."
        ask "age public key (age1...)" age_recipient
    fi
    case $age_recipient in
        AGE-SECRET-KEY-*) die "That is a private key. Give the public key (age1...) and keep the private key off this server." ;;
    esac
    valid_age_recipient "$age_recipient" || die "Not an age public key: $age_recipient"

    tls_mode=${tls_mode:-on-demand}
    case $tls_mode in
        on-demand) ;;
        dns)
            [ -n "$dns_provider" ] || ask "DNS provider for the wildcard certificate (for example cloudflare)" dns_provider
            [[ $dns_provider =~ ^[a-z0-9_]+$ ]] || die "Not a Caddy DNS provider name: $dns_provider"
            dns_module=${dns_module:-$(default_dns_module "$dns_provider")}
            [ -n "$dns_module" ] || die "No pinned module for $dns_provider. Pass --dns-module <module path>@<version>; see docs/tls.md."
            [[ $dns_module =~ ^[A-Za-z0-9._/-]+@v[0-9][A-Za-z0-9.+-]*$ ]] || die "--dns-module must be <module path>@v<version>, got: $dns_module"
            ;;
        internal)
            warn "TLS mode internal: certificates come from Caddy's local CA, which browsers do not trust."
            warn "Use it only for tests and private networks, never for a public installation."
            ;;
        *) die "--tls must be on-demand, dns, or internal, got: $tls_mode" ;;
    esac

    # Checked here, before anything on the server changes.
    gvisor_overlay_size=${gvisor_overlay_size:-$default_gvisor_overlay_size}
    valid_gvisor_overlay_size "$gvisor_overlay_size" ||
        die "SAKALA_GVISOR_OVERLAY_SIZE must be a size such as 512m or 2g, or none for no cap, got: $gvisor_overlay_size"
    check_console_links

    node_name=$(env_get "$SAKALA_ENV_FILE" SAKALA_NODE_NAME)
    node_name=${node_name:-$(hostname -s | tr -c 'a-zA-Z0-9-\n' '-')}

    info "Domain:   $domain  (app.$domain, api.$domain, *.run.$domain)"
    info "Admin:    $email"
    info "TLS:      $tls_mode${dns_provider:+ ($dns_provider)}"
    info "Backups:  encrypted to $age_recipient"
    if [ "$gvisor_overlay_size" = none ]; then
        info "Projects: no cap on what one writes to its root filesystem (SAKALA_GVISOR_OVERLAY_SIZE=none)"
    else
        info "Projects: each writes at most $gvisor_overlay_size to its root filesystem"
    fi
}

install_packages() {
    step "Installing base packages"
    export DEBIAN_FRONTEND=noninteractive
    local packages=(ca-certificates curl gnupg age rsync zstd git openssl jq iproute2)
    local missing=() package
    for package in "${packages[@]}"; do
        dpkg-query -W -f='${Status}' "$package" 2> /dev/null | grep -q 'install ok installed' || missing+=("$package")
    done
    if [ "${#missing[@]}" -eq 0 ]; then
        info "Already installed."
        return
    fi
    apt-get update -q
    apt-get install -y -q --no-install-recommends "${missing[@]}"
}

# The oldest versions install.sh relies on: `dockerd --validate` (Engine 23) and
# env_file entries with `required:` in compose.yaml (Compose 2.24).
docker_min_engine=24.0
docker_min_compose=2.24.0

version_at_least() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n 1)" = "$2" ]; }

# An engine that is already installed (Docker's docker-ce, Ubuntu's docker.io,
# Microsoft's moby-engine, ...) is reused when it meets what Sakala needs.
# Otherwise install.sh stops and names what is missing. It never replaces or
# removes an engine it did not install, because other containers may need it.
use_existing_docker() {
    local dockerd_path engine compose package problem problems=()
    dockerd_path=$(readlink -f "$(command -v dockerd)")
    case $dockerd_path in
        /snap/*) die "Docker is installed as a snap ($dockerd_path), which cannot run gVisor. Remove it (sudo snap remove docker), then run install.sh again." ;;
    esac
    engine=$(dockerd --version 2> /dev/null | sed -n 's/^Docker version \([0-9][0-9.]*\).*/\1/p')
    compose=$(docker compose version --short 2> /dev/null | sed 's/^v//' || true)
    if [ -z "$engine" ] || ! version_at_least "$engine" "$docker_min_engine"; then
        problems+=("Docker Engine ${engine:-of unknown version} is older than $docker_min_engine")
    fi
    if [ -z "$compose" ]; then
        problems+=("the Docker Compose plugin is missing")
    elif ! version_at_least "$compose" "$docker_min_compose"; then
        problems+=("Docker Compose $compose is older than $docker_min_compose")
    fi
    docker buildx version > /dev/null 2>&1 || problems+=("the Docker buildx plugin is missing")
    if ! is_dry_run; then
        if ! systemctl is-active --quiet docker && ! systemctl start docker; then
            problems+=("docker.service does not start")
        elif ! docker info > /dev/null 2>&1; then
            problems+=("the rootful daemon at /var/run/docker.sock does not answer")
        elif docker info --format '{{json .SecurityOptions}}' | grep rootless > /dev/null; then
            problems+=("the daemon runs rootless; Sakala needs the rootful daemon")
        fi
    fi
    package=$(dpkg-query -S "$dockerd_path" 2> /dev/null | cut -d: -f1 | head -n 1 || true)
    if [ "${#problems[@]}" -gt 0 ]; then
        warn "Docker is already installed (${package:-$dockerd_path}), but it cannot run Sakala:"
        for problem in "${problems[@]}"; do warn "  - $problem"; done
        die "Upgrade that Docker installation, or remove it and run install.sh again to get Docker's packages. install.sh does not replace an existing Docker Engine."
    fi
    info "Reusing the installed Docker Engine $engine${package:+ ($package)} with Compose $compose."
}

# Docker's apt repository when it serves this release, Ubuntu's own packages otherwise.
install_docker() {
    step "Installing Docker Engine (rootful)"
    if command -v dockerd > /dev/null; then
        use_existing_docker
    else
        local codename
        codename=$(. /etc/os-release && printf '%s' "$VERSION_CODENAME")
        if curl -fsSI --max-time 20 "https://download.docker.com/linux/ubuntu/dists/$codename/Release" > /dev/null 2>&1; then
            install -m 0755 -d /etc/apt/keyrings
            curl -fsSL --proto '=https' https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc.new
            # Docker's published release key: 9DC8 5822 9FC7 DD38 854A E2D8 8D81 803C 0EBF CD88.
            gpg --show-keys --with-colons /etc/apt/keyrings/docker.asc.new 2> /dev/null |
                grep -q '^fpr:::::::::9DC858229FC7DD38854AE2D88D81803C0EBFCD88:$' ||
                die "The Docker apt key does not have the expected fingerprint."
            mv -f /etc/apt/keyrings/docker.asc.new /etc/apt/keyrings/docker.asc
            chmod a+r /etc/apt/keyrings/docker.asc
            printf 'deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu %s stable\n' \
                "$codename" > /etc/apt/sources.list.d/docker.list
            apt-get update -q
            apt-get install -y -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        else
            warn "download.docker.com has no packages for Ubuntu $codename yet; using Ubuntu's docker.io."
            apt-get install -y -q docker.io docker-compose-v2 docker-buildx
        fi
    fi

    # Projects each get their own bridge network; Docker's default pool runs out
    # after about 20. This keeps the default range and allows 4,096 networks.
    if [ ! -e /etc/docker/daemon.json ]; then
        install -d -m 0755 /etc/docker
        write_file /etc/docker/daemon.json 0644 <<'JSON'
{
  "default-address-pools": [{ "base": "172.16.0.0/12", "size": 24 }],
  "log-driver": "local"
}
JSON
        info "Wrote /etc/docker/daemon.json (address pools, local log driver)."
        live systemctl restart docker
    elif ! jq -e 'has("default-address-pools")' /etc/docker/daemon.json > /dev/null 2>&1; then
        # An existing file keeps every setting it has; only what is missing is added.
        local merged
        merged=$(mktemp)
        jq '{"default-address-pools": [{"base": "172.16.0.0/12", "size": 24}], "log-driver": "local"} + .' \
            /etc/docker/daemon.json > "$merged" || die "/etc/docker/daemon.json is not valid JSON."
        dockerd --validate --config-file="$merged" > /dev/null ||
            die "Adding default-address-pools to /etc/docker/daemon.json would make it invalid; see the error above."
        cp -p /etc/docker/daemon.json "/etc/docker/daemon.json.bak-$(date -u +%Y%m%dT%H%M%SZ)"
        write_file /etc/docker/daemon.json 0644 < "$merged"
        rm -f "$merged"
        info "Added default-address-pools (and log-driver local if unset) to /etc/docker/daemon.json; restarting Docker."
        live systemctl restart docker
    fi
    live systemctl enable --now docker
}

# What the daemon reports, as clients such as buildx read it.
#
# Under pipefail, `producer | grep -q` fails when grep exits on the first match
# and the producer is killed by SIGPIPE, so checks below let grep read all input.
address_pools() { docker info --format '{{json .DefaultAddressPools}}' 2> /dev/null; }
address_pools_ok() { ! address_pools | grep -i 'invalid' > /dev/null; }

# Checked against the release's .sha512 and against the pin in versions.env.
install_gvisor() {
    step "Installing gVisor $SAKALA_GVISOR_RELEASE"
    local base_url="https://storage.googleapis.com/gvisor/releases/release/${SAKALA_GVISOR_RELEASE}/x86_64"
    if [ -x /usr/local/bin/runsc ] && /usr/local/bin/runsc --version 2> /dev/null | grep "release-${SAKALA_GVISOR_RELEASE}\$" > /dev/null; then
        info "runsc release-$SAKALA_GVISOR_RELEASE is already installed."
    else
        local work
        work=$(mktemp -d)
        (
            cd "$work"
            curl -fsSL --proto '=https' --retry 3 -O "$base_url/gvisor.tar.zstd"
            curl -fsSL --proto '=https' --retry 3 -O "$base_url/gvisor.tar.zstd.sha512"
            sha512sum -c gvisor.tar.zstd.sha512
            printf '%s  gvisor.tar.zstd\n' "$SAKALA_GVISOR_SHA512" | sha512sum -c - > /dev/null ||
                die "gvisor.tar.zstd does not match SAKALA_GVISOR_SHA512 in versions.env."
        )
        # runsc looks for gvisor-bin/ next to itself, so the archive is extracted whole.
        tar --zstd -xf "$work/gvisor.tar.zstd" -C /usr/local/bin --no-same-owner
        rm -rf "$work"
        info "Installed $(/usr/local/bin/runsc --version | head -n 1)."
    fi

    # `runsc install` merges into a copy, and dockerd checks the result before it replaces the live file.
    # It writes exactly the arguments it is given, so changing or removing the
    # overlay cap in sakala.env changes the registration on the next run.
    local candidate runtime_args=(--platform=systrap)
    # root:self keeps a sandbox's root filesystem writes in a file next to its
    # rootfs on the host (gVisor's default medium); size= caps that file.
    [ "$gvisor_overlay_size" = none ] || runtime_args+=("--overlay2=root:self,size=$gvisor_overlay_size")
    candidate=$(mktemp)
    [ ! -f /etc/docker/daemon.json ] || cp /etc/docker/daemon.json "$candidate"
    /usr/local/bin/runsc install --config_file="$candidate" --runtime runsc -- "${runtime_args[@]}" > /dev/null
    dockerd --validate --config-file="$candidate" > /dev/null
    local registered=0
    if [ -f /etc/docker/daemon.json ] && cmp -s "$candidate" /etc/docker/daemon.json; then
        info "runsc is already registered with Docker."
    else
        registered=1
        local reregistered=0
        jq -e '.runtimes.runsc' /etc/docker/daemon.json > /dev/null 2>&1 && reregistered=1
        [ ! -f /etc/docker/daemon.json ] || cp -p /etc/docker/daemon.json "/etc/docker/daemon.json.bak-$(date -u +%Y%m%dT%H%M%SZ)"
        write_file /etc/docker/daemon.json 0644 < "$candidate"
        info "Registered runsc in /etc/docker/daemon.json with ${runtime_args[*]}."
        # Docker passes the arguments when a sandbox starts, so running ones keep theirs.
        [ "$reregistered" -eq 0 ] || info "Projects already running take the new runsc settings at their next deploy, restart, or wake."
    fi
    rm -f "$candidate"

    # SIGHUP reloads runtimes without restarting containers. Only when the file
    # changed, so a rerun or an upgrade with the same runtime leaves Docker alone.
    [ "$registered" -eq 0 ] || live systemctl reload docker
    if ! is_dry_run; then
        local i
        for ((i = 0; i < 15; i++)); do
            docker info --format '{{json .Runtimes}}' | grep '"runsc"' > /dev/null && break
            sleep 1
        done
        docker info --format '{{json .Runtimes}}' | grep '"runsc"' > /dev/null ||
            die "Docker did not load runsc. Check: journalctl -u docker -n 50"
        # After a reload, Docker Engine 28.0.4 reports its pool base as "invalid Prefix"
        # until restarted, and buildx then refuses every build. Seen on GitHub's
        # ubuntu-24.04 runner; a restart restores the configured pools.
        if ! address_pools_ok; then
            warn "After the reload Docker reports its address pools as $(address_pools); restarting Docker."
            systemctl restart docker
            address_pools_ok || die "Docker reports its address pools as $(address_pools) even after a restart, so builds fail. Check /etc/docker/daemon.json."
        fi
        info "Docker address pools: $(address_pools)."
        docker run --rm --runtime runsc --network none "$SAKALA_CADDY_IMAGE" dmesg 2> /dev/null | grep 'Starting gVisor' > /dev/null ||
            die "A container under runsc did not start. Check: journalctl -u docker -n 50"
        info "A test container started under gVisor."
    fi
}

prepare_host() {
    step "Preparing directories and the agent account"
    install -d -m 0755 "$SAKALA_CONFIG_DIR" "$SAKALA_CONFIG_DIR/edge" "$SAKALA_CONFIG_DIR/edge/global.d"
    install -d -m 0700 "$SAKALA_SECRETS_DIR"
    install -d -m 0755 "$SAKALA_STATE_DIR"
    install -d -m 0700 "$SAKALA_STATE_DIR/backups"
    if ! id sakala-agent > /dev/null 2>&1; then
        useradd --system --user-group --home-dir "$SAKALA_STATE_DIR/agent" --no-create-home \
            --shell /usr/sbin/nologin sakala-agent
        info "Created the system account sakala-agent."
    fi
    install -d -m 0750 -o sakala-agent -g sakala-agent \
        "$SAKALA_STATE_DIR/builds" "$SAKALA_STATE_DIR/docker" "$SAKALA_STATE_DIR/cache" "$SAKALA_STATE_DIR/agent"
    install -d -m 0755 -o sakala-agent -g sakala-agent "$SAKALA_STATE_DIR/caddy" "$SAKALA_STATE_DIR/caddy/sites"
    # Keeps the router's import glob valid before the first project is deployed.
    local placeholder="$SAKALA_STATE_DIR/caddy/sites/00-placeholder.Caddyfile"
    [ -e "$placeholder" ] || install -m 0644 -o sakala-agent -g sakala-agent /dev/stdin "$placeholder" <<< \
        '# Keeps the route import glob valid before the agent writes the first route.'

    # The edge reaches the runtime router over this network, and nothing else
    # joins it. Created here rather than by Compose because the agent expects it
    # before it starts, and write_config reads its subnet.
    if ! docker network inspect sakala-runtime > /dev/null 2>&1; then
        if is_dry_run; then
            live docker network create sakala-runtime
        else
            docker network create sakala-runtime > /dev/null
            info "Created the Docker network sakala-runtime."
        fi
    fi

    if command -v ufw > /dev/null && ufw status 2> /dev/null | grep '^Status: active' > /dev/null; then
        ufw allow 80/tcp > /dev/null
        ufw allow 443/tcp > /dev/null
        ufw allow 443/udp > /dev/null
        info "Opened ports 80 and 443 in ufw."
    fi
}

random_hex() { openssl rand -hex "$1"; }

# The runtime router keeps X-Forwarded-* only from these addresses
# (caddy/runtime.Caddyfile). The edge reaches it over sakala-runtime, container
# to container, and Docker picks that network's subnet, so it is read again on
# every run instead of being kept from an earlier one.
runtime_network_subnets() {
    local output subnets
    output=$(docker network inspect sakala-runtime --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}' 2> /dev/null || true)
    read -r -a subnets <<< "$output"
    output="${subnets[*]}"
    if [ -z "$output" ] && is_dry_run; then
        # A dry run without a Docker daemon has no network to read. 192.0.2.0/24
        # is reserved for documentation (RFC 5737) and never routed.
        output=192.0.2.0/24
    fi
    [ -n "$output" ] || die "Cannot read the subnet of the Docker network sakala-runtime. Check: docker network inspect sakala-runtime"
    valid_trusted_proxies "$output" || die "The Docker network sakala-runtime has an unexpected subnet: $output"
    printf '%s' "$output"
}

write_config() {
    step "Writing configuration and secrets"
    local generated="$SAKALA_SECRETS_DIR/generated.env"
    if [ ! -s "$generated" ]; then
        write_file "$generated" 0600 <<EOF
# Generated once by install.sh. Never rotate these by hand: APP_KEY encrypts data
# in the database, and every backup set carries a copy of this file.
SAKALA_APP_KEY=base64:$(openssl rand -base64 32)
SAKALA_DB_PASSWORD=$(random_hex 24)
SAKALA_STORAGE_ACCESS_KEY=$(random_hex 10)
SAKALA_STORAGE_SECRET_KEY=$(random_hex 24)
SAKALA_REVERB_APP_ID=sakala
SAKALA_REVERB_APP_KEY=$(random_hex 16)
SAKALA_REVERB_APP_SECRET=$(random_hex 32)
EOF
        info "Generated secrets in $generated (mode 0600)."
    else
        info "Keeping the secrets in $generated."
    fi
    local name
    for name in SAKALA_APP_KEY SAKALA_DB_PASSWORD SAKALA_STORAGE_ACCESS_KEY SAKALA_STORAGE_SECRET_KEY \
        SAKALA_REVERB_APP_ID SAKALA_REVERB_APP_KEY SAKALA_REVERB_APP_SECRET; do
        printf -v "$name" '%s' "$(env_get "$generated" "$name")"
        [ -n "${!name}" ] || die "$generated has no $name."
    done

    local edge_image=
    if [ "$tls_mode" = dns ]; then
        edge_image="sakala-edge-dns:$(printf '%s %s' "$dns_module" "$(sha256sum "$SAKALA_HOME/caddy/Dockerfile.dns")" | sha256sum | cut -c1-16)"
    fi
    local acme_ca saved_max
    acme_ca=$(env_get "$SAKALA_ENV_FILE" SAKALA_ACME_CA)
    # A value the operator set in sakala.env wins over the one computed from memory.
    saved_max=$(env_get "$SAKALA_ENV_FILE" SAKALA_MAX_ACTIVE_CONTAINERS)
    [[ ! $saved_max =~ ^[0-9]+$ ]] || max_active_containers=$saved_max
    local trusted_override trusted_proxies
    trusted_override=$(env_get "$SAKALA_ENV_FILE" SAKALA_RUNTIME_TRUSTED_PROXIES_OVERRIDE)
    if [ -n "$trusted_override" ]; then
        valid_trusted_proxies "$trusted_override" ||
            die "SAKALA_RUNTIME_TRUSTED_PROXIES_OVERRIDE in $SAKALA_ENV_FILE must be IP addresses or CIDR ranges separated by spaces, without private_ranges or a /0 range. Got: $trusted_override"
        trusted_proxies=$trusted_override
        info "The runtime router trusts X-Forwarded-* from $trusted_proxies (SAKALA_RUNTIME_TRUSTED_PROXIES_OVERRIDE)."
    else
        trusted_proxies=$(runtime_network_subnets)
        info "The runtime router trusts X-Forwarded-* from the edge on sakala-runtime ($trusted_proxies)."
    fi
    write_file "$SAKALA_ENV_FILE" 0640 <<EOF
# Written by install.sh; options passed to it on a later run update this file.
# compose.yaml reads it next to versions.env.
SAKALA_DOMAIN=$domain
SAKALA_ADMIN_EMAIL=$email
SAKALA_NODE_NAME=$node_name
SAKALA_TLS_MODE=$tls_mode
SAKALA_DNS_PROVIDER=$dns_provider
SAKALA_DNS_MODULE=$dns_module
SAKALA_EDGE_IMAGE=$edge_image
# Let's Encrypt by default. Its staging directory is useful for a trial install:
# https://acme-staging-v02.api.letsencrypt.org/directory
SAKALA_ACME_CA=${acme_ca:-https://acme-v02.api.letsencrypt.org/directory}
SAKALA_CONFIG_DIR=$SAKALA_CONFIG_DIR
SAKALA_SECRETS_DIR=$SAKALA_SECRETS_DIR
SAKALA_STATE_DIR=$SAKALA_STATE_DIR
SAKALA_API_LOOPBACK_PORT=8100
SAKALA_CONSOLE_LOOPBACK_PORT=8101
SAKALA_MAX_ACTIVE_CONTAINERS=$max_active_containers
# Most that one project may write to its container's root filesystem under gVisor
# (runsc --overlay2=root:self,size=...), such as 512m or 2g. none removes the cap,
# so one project can fill the server's disk. Read docs/configuration.md first.
SAKALA_GVISOR_OVERLAY_SIZE=$gvisor_overlay_size
# Addresses the runtime router accepts X-Forwarded-* headers from: the subnet of
# the sakala-runtime network, read again on every run. To use other addresses,
# set the override (IP addresses or CIDR ranges separated by spaces); read
# docs/configuration.md first.
SAKALA_RUNTIME_TRUSTED_PROXIES_OVERRIDE=$trusted_override
SAKALA_RUNTIME_TRUSTED_PROXIES=$trusted_proxies
EOF

    SAKALA_DOMAIN=$domain
    SAKALA_ADMIN_EMAIL=$email
    # Read by render through indirect expansion. SAKALA_PROJECT_DOMAIN is one value
    # for the API's default project domain and the agent's allowed suffix.
    export SAKALA_PROJECT_DOMAIN=run.$domain
    export SAKALA_API_LOOPBACK_PORT=8100
    export SAKALA_MAX_ACTIVE_CONTAINERS=$max_active_containers
    local secret_vars=(SAKALA_DOMAIN SAKALA_PROJECT_DOMAIN SAKALA_ADMIN_EMAIL SAKALA_APP_KEY SAKALA_DB_PASSWORD SAKALA_STORAGE_ACCESS_KEY
        SAKALA_STORAGE_SECRET_KEY SAKALA_REVERB_APP_ID SAKALA_REVERB_APP_KEY SAKALA_REVERB_APP_SECRET)
    render "$SAKALA_HOME/templates/api.env.template" "$SAKALA_SECRETS_DIR/api.env" 0600 "${secret_vars[@]}"
    render "$SAKALA_HOME/templates/database.env.template" "$SAKALA_SECRETS_DIR/database.env" 0600 SAKALA_DB_PASSWORD
    render "$SAKALA_HOME/templates/storage.env.template" "$SAKALA_SECRETS_DIR/storage.env" 0600 \
        SAKALA_STORAGE_ACCESS_KEY SAKALA_STORAGE_SECRET_KEY
    render "$SAKALA_HOME/templates/console.env.template" "$SAKALA_CONFIG_DIR/console.env" 0644 \
        SAKALA_DOMAIN SAKALA_ADMIN_EMAIL SAKALA_REVERB_APP_KEY
    [ -e "$SAKALA_SECRETS_DIR/api.local.env" ] ||
        write_file "$SAKALA_SECRETS_DIR/api.local.env" 0600 < "$SAKALA_HOME/templates/api.local.env.template"
    # The Console's counterpart, for its docs and legal links, read after console.env.
    [ -e "$SAKALA_SECRETS_DIR/console.local.env" ] ||
        write_file "$SAKALA_SECRETS_DIR/console.local.env" 0600 < "$SAKALA_HOME/templates/console.local.env.template"
    # The agent's counterpart, read by sakala-agent.service after agent.env.
    [ -e "$SAKALA_SECRETS_DIR/agent.local.env" ] ||
        write_file "$SAKALA_SECRETS_DIR/agent.local.env" 0600 < "$SAKALA_HOME/templates/agent.local.env.template"
    # Read by uid 82 (www-data) in the API image once a GitHub App key is pasted in.
    [ -e "$SAKALA_SECRETS_DIR/github-app.pem" ] || install -m 0640 -o root -g 82 /dev/null "$SAKALA_SECRETS_DIR/github-app.pem"

    printf '%s\n' "$age_recipient" | write_file "$SAKALA_SECRETS_DIR/backup.age-recipients" 0600
    printf 'probe' | age -R "$SAKALA_SECRETS_DIR/backup.age-recipients" > /dev/null ||
        die "age cannot encrypt to $age_recipient."
    [ -e "$SAKALA_CONFIG_DIR/backup.env" ] ||
        render "$SAKALA_HOME/templates/backup.env.template" "$SAKALA_CONFIG_DIR/backup.env" 0644 \
            SAKALA_SECRETS_DIR SAKALA_STATE_DIR

    # The project TLS snippet is rewritten only when the mode changes, so an edited DNS snippet survives.
    local tls_file="$SAKALA_CONFIG_DIR/edge/run-tls.caddy" marker="$SAKALA_CONFIG_DIR/edge/.mode"
    if [ ! -e "$tls_file" ] || [ "$(cat "$marker" 2> /dev/null)" != "$tls_mode:$dns_provider" ]; then
        # A running edge does not notice changed snippet files; start_stack restarts it.
        [ ! -e "$marker" ] || edge_restart=1
        case $tls_mode in
            dns) sed "s/@@SAKALA_DNS_PROVIDER@@/$dns_provider/" "$SAKALA_HOME/caddy/run-tls.dns.caddy" | write_file "$tls_file" 0644 ;;
            internal) write_file "$tls_file" 0644 < "$SAKALA_HOME/caddy/run-tls.internal.caddy" ;;
            *) write_file "$tls_file" 0644 < "$SAKALA_HOME/caddy/run-tls.on-demand.caddy" ;;
        esac
        printf '%s:%s\n' "$tls_mode" "$dns_provider" | write_file "$marker" 0644
        info "Project hostnames use $tls_mode certificates ($tls_file)."
    fi
    # Internal mode also moves app. and api. to the local CA. This file belongs to
    # install.sh; the operator's own global options go in other files in global.d.
    local internal_global="$SAKALA_CONFIG_DIR/edge/global.d/00-sakala-tls-internal.caddy"
    if [ "$tls_mode" = internal ]; then
        write_file "$internal_global" 0644 < "$SAKALA_HOME/caddy/global-tls-internal.caddy"
    else
        rm -f "$internal_global"
    fi
    if [ "$tls_mode" = dns ]; then
        local token=${SAKALA_DNS_API_TOKEN:-}
        if [ -z "$token" ] && [ ! -s "$SAKALA_SECRETS_DIR/dns.env" ]; then
            ask "API token for $dns_provider DNS (input hidden)" token 1
        fi
        if [ -n "$token" ]; then
            [[ $token =~ ^[A-Za-z0-9._:/+=-]+$ ]] || die "The DNS token has characters an env file cannot hold unquoted."
            printf 'SAKALA_DNS_API_TOKEN=%s\n' "$token" | write_file "$SAKALA_SECRETS_DIR/dns.env" 0600
        fi
    else
        rm -f "$SAKALA_SECRETS_DIR/dns.env"
    fi

    info "Checking the Compose configuration."
    compose config --quiet
}

ports_free_or_ours() {
    local port
    for port in 80 443; do
        if ss -ltnH "sport = :$port" 2> /dev/null | grep . > /dev/null; then
            if is_dry_run || compose ps --status running --services 2> /dev/null | grep -x edge > /dev/null; then
                continue
            fi
            die "Port $port is already in use: $(ss -ltnpH "sport = :$port" | head -n 1). Stop that service first."
        fi
    done
}

start_stack() {
    step "Starting the control plane"
    ports_free_or_ours
    # In DNS mode the edge image is built here, not pulled.
    local pulled=(postgres valkey rustfs api api-web console runtime-caddy)
    [ "$tls_mode" = dns ] || pulled+=(edge)
    live compose pull --quiet "${pulled[@]}"
    if [ "$tls_mode" = dns ]; then
        local edge_image
        edge_image=$(env_get "$SAKALA_ENV_FILE" SAKALA_EDGE_IMAGE)
        if is_dry_run || ! docker image inspect "$edge_image" > /dev/null 2>&1; then
            info "Building the edge with $dns_module (a few minutes)."
            live docker build --pull -f "$SAKALA_HOME/caddy/Dockerfile.dns" \
                --build-arg "DNS_MODULE=$dns_module" -t "$edge_image" "$SAKALA_HOME/caddy"
        fi
    fi
    live compose up -d --wait postgres valkey rustfs
    info "Migrating the database."
    live compose --profile operations run --rm migrate
    live compose --profile operations run --rm storage-init
    live compose up -d --remove-orphans api api-web reverb queue scheduler console runtime-caddy edge
    [ "$edge_restart" -eq 0 ] || live compose restart edge

    wait_http "API" "http://127.0.0.1:8100/up" || die "The API did not answer. Check: sudo sakala-compose logs api api-web"
    wait_http "Console" "http://127.0.0.1:8101/healthz" || die "The Console did not answer. Check: sudo sakala-compose logs console"

    # The Console reads console.env when its container starts. A Console that
    # does not name api.<domain> would send browsers to another API.
    if ! is_dry_run && ! curl -fsS --max-time 5 http://127.0.0.1:8101/runtime-config.js | grep -F "\"https://api.$domain\"" > /dev/null; then
        die "The Console ($SAKALA_CONSOLE_VERSION) does not point at https://api.$domain. Check: sudo sakala-compose logs console, and $SAKALA_CONFIG_DIR/console.env"
    fi
    is_dry_run || info "The Console points at https://api.$domain."
}

create_admin() {
    [ "$upgrade" -eq 0 ] || return 0
    step "Creating the first admin account"
    if is_dry_run; then
        live compose exec -T api php artisan user:admin "$email" --create --generate-password --no-interaction
        return
    fi
    local output password
    output=$(compose exec -T api php artisan user:admin "$email" --create --generate-password --no-interaction 2>&1) ||
        die "Creating the admin failed: $output"
    password=$(printf '%s\n' "$output" | sed -n 's/.*Password, shown only this once: //p' | head -n 1)
    if [ -n "$password" ]; then
        printf '%s\n' "$password" | write_file "$SAKALA_SECRETS_DIR/initial-admin-password" 0600
        info "Created $email. The password is printed at the end."
    else
        info "$email already exists and is an admin; its password is unchanged."
    fi
}

install_agent() {
    step "Installing Sakala Agent $SAKALA_AGENT_VERSION"
    local binary=/usr/local/bin/sakala-agent asset=sakala-agent-linux-x86_64 changed=0
    if [ -x "$binary" ] && [ "$(sha256sum "$binary" | cut -d' ' -f1)" = "$SAKALA_AGENT_SHA256" ]; then
        info "Already installed."
    else
        local work base="https://github.com/gmedia/sakala-agent/releases/download/$SAKALA_AGENT_VERSION"
        work=$(mktemp -d)
        curl -fsSL --proto '=https' --retry 3 -o "$work/$asset" "$base/$asset"
        curl -fsSL --proto '=https' --retry 3 -o "$work/SHA256SUMS" "$base/SHA256SUMS"
        # The published sums name the file dist/<asset>.
        local expected actual
        expected=$(grep -E "(^| |/)$asset\$" "$work/SHA256SUMS" | awk '{ print $1 }' | head -n 1)
        actual=$(sha256sum "$work/$asset" | cut -d' ' -f1)
        if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
            die "$asset does not match the release's SHA256SUMS."
        fi
        [ "$actual" = "$SAKALA_AGENT_SHA256" ] || die "$asset matches SHA256SUMS but not SAKALA_AGENT_SHA256 in versions.env."
        install -o root -g root -m 0755 "$work/$asset" "$binary"
        rm -rf "$work"
        changed=1
        info "Installed and verified $binary."
    fi

    # Railpack analyses untrusted repositories only inside this sandbox image,
    # built here from the agent source at the pinned commit.
    local sandbox_tag="sakala-railpack-sandbox:${SAKALA_AGENT_COMMIT:0:12}"
    if is_dry_run; then
        live docker build --provenance=false -t "$sandbox_tag" \
            "https://github.com/gmedia/sakala-agent.git#$SAKALA_AGENT_COMMIT:docker/railpack-sandbox"
        export SAKALA_RAILPACK_IMAGE=sha256:dry-run
    else
        if ! docker image inspect "$sandbox_tag" > /dev/null 2>&1; then
            info "Building the Railpack sandbox image."
            docker build --quiet --provenance=false -t "$sandbox_tag" \
                "https://github.com/gmedia/sakala-agent.git#$SAKALA_AGENT_COMMIT:docker/railpack-sandbox" > /dev/null
        fi
        SAKALA_RAILPACK_IMAGE=$(docker image inspect --format '{{.Id}}' "$sandbox_tag")
        export SAKALA_RAILPACK_IMAGE
    fi

    local agent_env="$SAKALA_CONFIG_DIR/agent.env" before=
    [ ! -f "$agent_env" ] || before=$(sha256sum "$agent_env")
    render "$SAKALA_HOME/templates/agent.env.template" "$agent_env" 0644 \
        SAKALA_API_LOOPBACK_PORT SAKALA_STATE_DIR SAKALA_RAILPACK_FRONTEND SAKALA_RAILPACK_IMAGE SAKALA_MAX_ACTIVE_CONTAINERS \
        SAKALA_PROJECT_DOMAIN SAKALA_DOMAIN
    [ "$before" = "$(sha256sum "$agent_env")" ] || changed=1

    # The API issues the agent id and returns its token exactly once.
    local credentials="$SAKALA_SECRETS_DIR/agent-credentials.env"
    if ! grep -q '^SAKALA_AGENT_ID=agent-' "$credentials" 2> /dev/null; then
        if is_dry_run; then
            live compose exec -T api php artisan agent:provision "$node_name" --no-interaction
        else
            local output agent_id token
            output=$(compose exec -T api php artisan agent:provision "$node_name" \
                --description="Single-node install on $(hostname)" --no-interaction)
            agent_id=$(printf '%s\n' "$output" | sed -n 's/^SAKALA_AGENT_ID=//p' | head -n 1)
            token=$(printf '%s\n' "$output" | sed -n 's/^SAKALA_AGENT_TOKEN=//p' | head -n 1)
            if [ -z "$agent_id" ] || [ -z "$token" ]; then
                die "Provisioning did not return an agent id and token."
            fi
            printf 'SAKALA_AGENT_ID=%s\nSAKALA_AGENT_TOKEN=%s\n' "$agent_id" "$token" | write_file "$credentials" 0600
            changed=1
            info "Registered this server as $agent_id (token stored, not shown)."
        fi
    fi

    install_unit sakala-agent.service
    live systemctl daemon-reload
    live systemctl enable sakala-agent.service
    if [ "$changed" -eq 1 ] || ! systemctl is-active --quiet sakala-agent.service 2> /dev/null; then
        live systemctl restart sakala-agent.service
    fi
}

install_unit() {
    install -d -m 0755 /etc/systemd/system
    sed "s|@@SAKALA_HOME@@|$SAKALA_HOME|g" "$SAKALA_HOME/systemd/$1" | write_file "/etc/systemd/system/$1" 0644
}

install_backup() {
    step "Scheduling daily encrypted backups"
    install_unit sakala-backup.service
    install_unit sakala-backup.timer
    live systemctl daemon-reload
    live systemctl enable --now sakala-backup.timer
    info "Runs daily at 02:00 WIB (19:00 UTC) into $SAKALA_STATE_DIR/backups."
}

install_helper() {
    write_file /usr/local/bin/sakala-compose 0755 <<EOF
#!/bin/sh
# Runs docker compose for this Sakala installation, for example: sakala-compose ps
exec docker compose --project-directory "$SAKALA_HOME" -f "$SAKALA_HOME/compose.yaml" \\
    --env-file "$SAKALA_ENV_FILE" --env-file "$SAKALA_VERSIONS_FILE" "\$@"
EOF
}

summary() {
    step "Done"
    printf '\n'
    info "Console:   https://app.$domain"
    info "API:       https://api.$domain"
    info "Projects:  https://<name>.run.$domain"
    if [ -s "$SAKALA_SECRETS_DIR/initial-admin-password" ] && [ "$upgrade" -eq 0 ]; then
        info "Admin:     $email"
        info "Password:  $(cat "$SAKALA_SECRETS_DIR/initial-admin-password")"
        info "           Store it in a password manager, then delete $SAKALA_SECRETS_DIR/initial-admin-password."
    fi
    printf '\n'
    info "DNS must point app.$domain, api.$domain, and *.run.$domain at this server."
    if [ "$tls_mode" = internal ]; then
        warn "TLS mode internal: clients must trust the edge's local CA. Its root certificate:"
        warn "  sudo sakala-compose exec -T edge cat /data/caddy/pki/authorities/local/root.crt"
    else
        info "Certificates are requested on the first visit to each hostname."
    fi
    info "Emails only reach the API log until you set a mailer: docs/configuration.md."
    local key unset_legal=()
    for key in "${console_legal_keys[@]}"; do
        [ -n "$(console_local_get "$key")" ] || unset_legal+=("$key")
    done
    if [ "${#unset_legal[@]}" -gt 0 ]; then
        warn "The Console links hosted Sakala's legal documents, which do not cover this server, for: ${unset_legal[*]}."
        warn "Publish your own and set them in $SAKALA_SECRETS_DIR/console.local.env (docs/configuration.md, \"Tautan Console\")."
    fi
    info "Keep the age private key and $SAKALA_SECRETS_DIR/generated.env off this server too."
}

main() {
    require_root
    check_os
    load_versions
    assert_pinned
    check_resources
    collect_inputs
    if [ "$assume_yes" -eq 0 ] && [ -t 0 ]; then
        local answer
        read -r -p "    Continue? [y/N] " answer
        [[ $answer =~ ^[Yy] ]] || die "Stopped; nothing was changed."
    fi
    install_packages
    install_docker
    install_gvisor
    prepare_host
    write_config
    install_helper
    start_stack
    create_admin
    install_agent
    install_backup
    summary
}

main
