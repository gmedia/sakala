#!/usr/bin/env bash

# End-to-end test of install.sh, upgrade.sh, and uninstall.sh on a fresh,
# disposable Ubuntu machine with systemd, such as a GitHub-hosted runner
# (.github/workflows/install-e2e.yml). It changes the machine for real: Docker
# configuration, gVisor, /etc/hosts, /opt/sakala, /etc/sakala. Never run it on a
# server you want to keep.
#
# Usage: sudo -E tests/install-e2e.sh <phase>
#   prepare      copy this checkout to /opt/sakala, add /etc/hosts entries, make an age key
#   install      install.sh --tls internal, non-interactive
#   verify       services healthy, API and Console over HTTPS, the Console in a browser calls
#                this API, agent ready with run.<domain> as its project domain, runsc registered
#   deploy       log in as the generated admin, create a project from a public repository,
#                wait for inspection and deployment, fetch https://<slug>.run.<domain>/
#   upgrade      upgrade.sh with the same pins: backup taken, secrets kept, everything still up
#   uninstall    uninstall.sh --yes: everything removed except backups, Docker, and gVisor
#   diagnostics <dir>   collect logs into <dir> with secrets redacted
#
# Environment:
#   SAKALA_E2E_DISPOSABLE_HOST=yes   required; confirms this machine may be changed
#   E2E_DOMAIN                       default sakala.test, through /etc/hosts; never a hosted
#                                    Sakala domain, so the test proves a self-hosted one works
#   E2E_GITHUB_TOKEN                 optional; becomes GITHUB_PUBLIC_API_TOKEN in api.local.env
#   E2E_REPOSITORY, E2E_BRANCH, E2E_ROOT_DIRECTORY   the project to deploy
#   E2E_CONTAINER_RUNTIME            the runtime the deployed container must use, default runsc

set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
domain=${E2E_DOMAIN:-sakala.test}
email=${E2E_ADMIN_EMAIL:-admin@$domain}
repository=${E2E_REPOSITORY:-https://github.com/gmedia/sakala-infra}
branch=${E2E_BRANCH:-main}
root_directory=${E2E_ROOT_DIRECTORY:-examples/static-app}
expected_runtime=${E2E_CONTAINER_RUNTIME:-runsc}
home=/opt/sakala
state=/var/tmp/sakala-e2e
ca="$state/root.crt"
jar="$state/cookies.txt"
services=(postgres valkey rustfs api api-web reverb queue scheduler console runtime-caddy edge)

step() { printf '\n==> %s\n' "$*"; }
pass() { printf 'ok   %s\n' "$*"; }
note() { printf '     %s\n' "$*"; }
# To stderr, because it is also called inside command substitutions.
fail() {
    printf '::error::%s\n' "$*" >&2
    exit 1
}

[ "$(id -u)" -eq 0 ] || fail "Run as root: sudo -E $0 $*"
[ "${SAKALA_E2E_DISPOSABLE_HOST:-}" = yes ] ||
    fail "This test changes the whole machine. Set SAKALA_E2E_DISPOSABLE_HOST=yes on a disposable VM only."
install -d -m 0700 "$state"

sc() { /usr/local/bin/sakala-compose "$@"; }

# retry <attempts> <seconds> <command...>
retry() {
    local attempts=$1 delay=$2 i
    shift 2
    for ((i = 1; i <= attempts; i++)); do
        "$@" && return 0
        [ "$i" -eq "$attempts" ] || sleep "$delay"
    done
    return 1
}

# HTTPS with the edge's local CA, never -k.
https_status() { curl -sS -o /dev/null -w '%{http_code}' --max-time 20 --cacert "$ca" "$1" 2> /dev/null || true; }
https_ok() { [ "$(https_status "$1")" = 200 ]; }

# Runs a script, keeps its output in $state/<name>.log, and requires exit 0.
run_script() {
    local name=$1 log="$state/$1.log" status=0
    shift
    "$@" 2>&1 | tee "$log" || status=${PIPESTATUS[0]}
    [ "$status" -eq 0 ] || fail "$name exited $status."
    pass "$name exited 0"
}

remember_secrets() {
    # Values diagnostics must never contain, kept here because uninstall deletes their files.
    local secrets=/etc/sakala/secrets
    {
        sed -n 's/^[A-Z0-9_]*=//p' "$secrets/generated.env" || true
        sed -n 's/^SAKALA_AGENT_TOKEN=//p' "$secrets/agent-credentials.env" || true
        # Only uncommented lines, which in this test means the GitHub token.
        sed -n 's/^[A-Z0-9_]*=//p' "$secrets/api.local.env" "$secrets/dns.env" || true
        cat "$secrets/initial-admin-password" || true
        printf '%s\n' "${E2E_GITHUB_TOKEN:-}"
    } 2> /dev/null | awk 'length($0) >= 8' | sort -u >> "$state/redact.list"
    chmod 600 "$state/redact.list"
}

phase_prepare() {
    case $domain in
        sakala.localhost | *.sakala.localhost | sakala.dev | *.sakala.dev)
            fail "E2E_DOMAIN=$domain is a hosted Sakala domain, which the agent accepts without SAKALA_PROJECT_DOMAIN_SUFFIXES. Use a self-hosted one such as sakala.test."
            ;;
    esac

    step "Copying the checkout to $home"
    if [ "$repo" != "$home" ]; then
        # The backup unit has ProtectHome=true, so the installation cannot live under /home.
        install -d -m 0755 "$home"
        rsync -a --delete "$repo/" "$home/"
        chown -R root:root "$home"
    fi
    pass "$home is a copy of $(git -C "$repo" rev-parse --short HEAD 2> /dev/null || echo 'this checkout')"
    prepare_machine
}

# Everything prepare does besides putting the installation in place.
prepare_machine() {
    step "Pointing app.$domain and api.$domain at 127.0.0.1"
    grep -q " api.$domain\$" /etc/hosts || printf '127.0.0.1 app.%s api.%s\n' "$domain" "$domain" >> /etc/hosts
    getent ahostsv4 "api.$domain" | grep '^127.0.0.1 ' > /dev/null || fail "api.$domain does not resolve to 127.0.0.1"
    pass "/etc/hosts has app.$domain and api.$domain"

    step "Making a backup key (the private key stays in $state)"
    command -v age-keygen > /dev/null || { apt-get update -q && DEBIAN_FRONTEND=noninteractive apt-get install -y -q age; }
    [ -s "$state/backup.key" ] || age-keygen -o "$state/backup.key" 2> /dev/null
    age-keygen -y "$state/backup.key" > "$state/backup.recipient"
    pass "age recipient $(cat "$state/backup.recipient")"

    if [ -n "${E2E_GITHUB_TOKEN:-}" ]; then
        step "Giving the API a GitHub token through api.local.env"
        # install.sh writes api.local.env only when it is missing, so this is what an
        # operator does to set GITHUB_PUBLIC_API_TOKEN before the first install.
        install -d -m 0700 /etc/sakala /etc/sakala/secrets
        chmod 0755 /etc/sakala
        {
            cat "$home/templates/api.local.env.template"
            printf 'GITHUB_PUBLIC_API_TOKEN=%s\n' "$E2E_GITHUB_TOKEN"
        } > /etc/sakala/secrets/api.local.env
        chmod 0600 /etc/sakala/secrets/api.local.env
        pass "GITHUB_PUBLIC_API_TOKEN set (value not shown)"
    fi

    step "Docker already on this machine"
    if command -v dockerd > /dev/null; then
        note "$(dockerd --version), package $(dpkg-query -S "$(readlink -f "$(command -v dockerd)")" 2> /dev/null | cut -d: -f1 || echo unknown)"
        note "Compose $(docker compose version --short 2> /dev/null || echo missing), buildx $(docker buildx version 2> /dev/null | awk '{print $2}' || echo missing)"
        note "daemon.json: $([ -e /etc/docker/daemon.json ] && tr -d '\n ' < /etc/docker/daemon.json || echo none)"
    else
        note "none"
    fi
    note "kernel $(uname -r), $(nproc) vCPU, $(awk '/^MemTotal:/ { print int($2 / 1024) }' /proc/meminfo) MB"
}

phase_install() {
    step "install.sh --tls internal"
    run_script install "$home/install.sh" --domain "$domain" --email "$email" \
        --age-recipient "$(cat "$state/backup.recipient")" --tls internal --yes
    remember_secrets
    if grep -q 'Reusing the installed Docker Engine' "$state/install.log"; then
        pass "install.sh reused the Docker Engine already on this machine: $(grep -o 'Reusing the installed Docker Engine.*' "$state/install.log")"
    else
        note "install.sh installed Docker itself."
    fi
    grep -q 'A test container started under gVisor' "$state/install.log" && pass "install.sh started a test container under runsc"
    [ -s /etc/sakala/secrets/initial-admin-password ] || fail "install.sh did not store the admin password"
    pass "admin password stored in /etc/sakala/secrets/initial-admin-password (mode $(stat -c %a /etc/sakala/secrets/initial-admin-password))"
}

services_healthy() {
    local json bad
    json=$(sc ps -a --format json 2> /dev/null | jq -s 'if length > 0 and (.[0] | type) == "array" then .[0] else . end') || return 1
    bad=$(jq -r --argjson want "$(printf '%s\n' "${services[@]}" | jq -R . | jq -s .)" '
        ($want - map(.Service)) as $missing
        | ($missing | map("\(.): missing"))
          + map(select(.State != "running" or ((.Health // "") != "" and .Health != "healthy"))
                | "\(.Service): \(.State) \(.Health // "")")
        | .[]' <<< "$json")
    [ -z "$bad" ] && return 0
    printf '     waiting: %s\n' "$(tr '\n' ' ' <<< "$bad")"
    return 1
}

fetch_ca() {
    sc exec -T edge cat /data/caddy/pki/authorities/local/root.crt > "$ca.new" 2> /dev/null &&
        openssl x509 -in "$ca.new" -noout > /dev/null 2>&1 && mv -f "$ca.new" "$ca"
}

check_services() {
    step "Every service is running, and healthy where it has a health check"
    retry 30 10 services_healthy || {
        sc ps -a
        fail "Not every service is running and healthy."
    }
    pass "all ${#services[@]} services: ${services[*]}"
}

check_https() {
    step "HTTPS through the edge, trusting only its local CA"
    retry 30 2 fetch_ca || fail "No local CA root certificate in the edge container."
    pass "local CA: $(openssl x509 -in "$ca" -noout -subject | sed 's/^subject=//')"
    retry 30 2 https_ok "https://api.$domain/up" || fail "https://api.$domain/up answered $(https_status "https://api.$domain/up"), expected 200"
    pass "https://api.$domain/up 200"
    retry 15 2 https_ok "https://app.$domain/" || fail "https://app.$domain/ answered $(https_status "https://app.$domain/"), expected 200"
    pass "https://app.$domain/ 200 (the Console loads)"
}

check_console_config() {
    step "The Console is configured for https://api.$domain"
    local config reverb_key name value headers csp
    config=$(curl -sS --max-time 20 --cacert "$ca" "https://app.$domain/runtime-config.js" 2> /dev/null || true)
    reverb_key=$(sed -n 's/^SAKALA_REVERB_APP_KEY=//p' /etc/sakala/secrets/generated.env)
    while read -r name value; do
        grep -qF "\"$name\":\"$value\"" <<< "$config" ||
            fail "runtime-config.js lacks $name=$value: $(head -c 300 <<< "${config:-<empty>}" | sed "s/$reverb_key/[reverb key]/g")"
    done << EOF
PUBLIC_API_URL https://api.$domain
PUBLIC_APP_URL https://app.$domain
PUBLIC_REVERB_HOST api.$domain
PUBLIC_REVERB_PORT 443
PUBLIC_REVERB_SCHEME https
PUBLIC_REVERB_KEY $reverb_key
EOF
    pass "runtime-config.js names https://api.$domain, https://app.$domain, and Reverb at wss://api.$domain:443"
    grep -qi 'sakala\.dev' <<< "$config" && fail "runtime-config.js still names a hosted Sakala domain: $config"

    headers=$(curl -sS -D - -o /dev/null --max-time 20 --cacert "$ca" "https://app.$domain/" 2> /dev/null || true)
    csp=$(grep -i '^content-security-policy:' <<< "$headers" | tr -d '\r')
    [[ $csp == *"connect-src"*"https://api.$domain"* ]] || fail "The Console's Content-Security-Policy does not allow https://api.$domain: ${csp:-<none>}"
    [[ $csp == *"wss://api.$domain"* ]] || fail "The Console's Content-Security-Policy does not allow wss://api.$domain: $csp"
    [[ $csp != *"sakala.dev"* ]] || fail "The Console's Content-Security-Policy still names a hosted Sakala domain: $csp"
    pass "Content-Security-Policy allows https://api.$domain and wss://api.$domain only"

    check_console_browser
}

# Chrome trusts the edge's local CA through an NSS database in a home of its own,
# so a certificate error fails the check instead of being ignored.
prepare_browser() {
    local dir="$state/console-browser" nssdb="$state/browser-home/.pki/nssdb"
    command -v node > /dev/null || fail "Node.js is needed for the browser check."
    if ! command -v certutil > /dev/null; then
        apt-get update -q && DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends libnss3-tools > /dev/null
    fi
    if [ ! -d "$dir/node_modules/playwright-core" ]; then
        install -d -m 0700 "$dir"
        cp "$repo/tests/console-browser/package.json" "$repo/tests/console-browser/package-lock.json" \
            "$repo/tests/console-browser/check.mjs" "$dir/"
        (cd "$dir" && npm ci --ignore-scripts --no-audit --no-fund --loglevel=error) || fail "npm ci for the browser check failed."
    fi
    if command -v google-chrome > /dev/null; then
        browser_channel=chrome
    else
        browser_channel=
        HOME="$state/browser-home" node "$dir/node_modules/playwright-core/cli.js" install --with-deps chromium > /dev/null ||
            fail "Neither Google Chrome nor Playwright's Chromium is available."
    fi
    rm -rf "$nssdb"
    install -d -m 0700 "$nssdb"
    certutil -d "sql:$nssdb" -N --empty-password
    certutil -d "sql:$nssdb" -A -t 'C,,' -n sakala-e2e-local-ca -i "$ca"
}

check_console_browser() {
    step "The Console in a browser calls https://api.$domain"
    prepare_browser
    HOME="$state/browser-home" APP_ORIGIN="https://app.$domain" API_ORIGIN="https://api.$domain" \
        CHROME_CHANNEL="$browser_channel" node "$state/console-browser/check.mjs" ||
        fail "The Console in a browser does not call https://api.$domain; see the lines above."
}

agent_status() {
    local agent_id
    agent_id=$(sed -n 's/^SAKALA_AGENT_ID=//p' /etc/sakala/secrets/agent-credentials.env)
    # shellcheck disable=SC2016 # expanded by the shell inside the container
    sc exec -T postgres sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tA -F " " -c "$1"' sh \
        "select status, auth_status, coalesce(capabilities::text, '') from agent_nodes where agent_id = '$agent_id'" 2> /dev/null
}

agent_ready() { agent_status | grep '^ready active' > /dev/null; }

# The agent is up and ready in the API, with runsc. Every pinned agent release passes this.
check_agent_ready() {
    step "The agent is registered and ready, with runsc as the runtime"
    systemctl is-active --quiet sakala-agent.service || {
        journalctl -u sakala-agent.service -n 50 --no-pager
        fail "sakala-agent.service is not active."
    }
    pass "sakala-agent.service is active"
    retry 24 5 agent_ready || {
        note "agent_nodes: $(agent_status)"
        journalctl -u sakala-agent.service -n 80 --no-pager
        fail "The agent is not ready in the API."
    }
    pass "agent_nodes row: $(agent_status | cut -c1-200)"
    if journalctl -u sakala-agent.service --no-pager | grep 'runtime preflight check failed' > /dev/null; then
        journalctl -u sakala-agent.service --no-pager | grep 'runtime preflight' >&2
        fail "The agent reported a failed preflight check."
    fi
    note "$(journalctl -u sakala-agent.service --no-pager | grep -c 'runtime preflight check passed') preflight checks passed"
    docker info --format '{{json .Runtimes}}' | grep '"runsc"' > /dev/null || fail "runsc is not registered with Docker."
    grep -qx 'SAKALA_CONTAINER_RUNTIME=runsc' /etc/sakala/agent.env || fail "agent.env does not select runsc."
    pass "runsc registered with Docker and selected in agent.env ($(/usr/local/bin/runsc --version | head -n 1))"
}

check_agent() {
    check_agent_ready
    grep -qx "SAKALA_PROJECT_DOMAIN_SUFFIXES=run.$domain" /etc/sakala/agent.env ||
        fail "agent.env does not set SAKALA_PROJECT_DOMAIN_SUFFIXES=run.$domain."
    grep -qx "SAKALA_PROJECT_DEFAULT_DOMAIN=run.$domain" /etc/sakala/secrets/api.env ||
        fail "api.env does not set SAKALA_PROJECT_DEFAULT_DOMAIN=run.$domain."
    journalctl -u sakala-agent.service --no-pager | grep -F "one label under run.$domain (" > /dev/null ||
        fail "The agent's preflight does not report run.$domain as its project domain: $(journalctl -u sakala-agent.service --no-pager | grep -F project-domains | tail -n 1)"
    pass "the agent accepts project domains under run.$domain, the API's default project domain"
}

phase_verify() {
    check_services
    check_https
    check_console_config
    check_agent
}

# --- API session, as the Console does it: CSRF cookie, then JSON with the token.

xsrf_token() {
    local raw
    raw=$(awk '$6 == "XSRF-TOKEN" { print $7 }' "$jar" | tail -n 1)
    printf '%b' "${raw//%/\\x}"
}

api() {
    local method=$1 path=$2
    shift 2
    curl -sS --max-time 60 --cacert "$ca" -b "$jar" -c "$jar" -X "$method" \
        -H "Origin: https://app.$domain" -H "Referer: https://app.$domain/" \
        -H 'Accept: application/json' -H 'Content-Type: application/json' \
        -H "X-XSRF-TOKEN: $(xsrf_token)" -w '\n%{http_code}' "$@" "https://api.$domain$path"
}

# api_json <expected status> <method> <path> [curl args]: prints the body, fails otherwise.
api_json() {
    local want=$1 out code body
    shift
    out=$(api "$@") || fail "$1 $2: request failed"
    code=${out##*$'\n'}
    body=${out%$'\n'*}
    case " $want " in
        *" $code "*) ;;
        *)
            printf '%s\n' "${body:0:2000}" >&2
            fail "$1 $2 answered $code, expected $want"
            ;;
    esac
    printf '%s' "$body"
}

login() {
    step "Logging in as $email through the API session"
    rm -f "$jar"
    touch "$jar" && chmod 600 "$jar"
    local status
    status=$(curl -sS -o /dev/null -w '%{http_code}' --cacert "$ca" -b "$jar" -c "$jar" \
        -H "Origin: https://app.$domain" -H "Referer: https://app.$domain/" "https://api.$domain/sanctum/csrf-cookie")
    [ "$status" = 204 ] || fail "GET /sanctum/csrf-cookie answered $status, expected 204"
    [ -n "$(xsrf_token)" ] || fail "No XSRF-TOKEN cookie after /sanctum/csrf-cookie"
    jq -n --arg email "$email" --rawfile password /etc/sakala/secrets/initial-admin-password \
        '{email: $email, password: ($password | rtrimstr("\n"))}' > "$state/login.json"
    chmod 600 "$state/login.json"
    api_json 200 POST /api/v1/auth/login --data-binary "@$state/login.json" > /dev/null
    rm -f "$state/login.json"
    local user
    user=$(api_json 200 GET /api/v1/auth/user)
    pass "session for $(jq -r '.data.email' <<< "$user"), admin: $(jq -r '.data.is_admin // .data.role // "?"' <<< "$user")"

    if [ "$(jq -r '.data.legal_acceptance_required' <<< "$user")" = true ]; then
        local options
        options=$(api_json 200 GET /api/v1/auth/options)
        api_json 200 POST /api/v1/auth/legal-acceptance --data "$(jq -c '{accept_terms: true,
            terms_version: .data.legal.terms_version, acceptable_use_version: .data.legal.acceptable_use_version}' <<< "$options")" > /dev/null
        pass "accepted the terms ($(jq -r '.data.legal.terms_version' <<< "$options"))"
    fi
}

wait_inspection() {
    local project status i
    for ((i = 0; i < 120; i++)); do
        project=$(api_json 200 GET "/api/v1/app/projects/$1")
        status=$(jq -r '.data.preview_status' <<< "$project")
        case $status in
            succeeded)
                printf '%s' "$project"
                return 0
                ;;
            failed) fail "Inspection failed: $(jq -c '{inspection_error_code, preview_status}' <<< "$project")" ;;
        esac
        sleep 5
    done
    fail "Inspection did not finish in 10 minutes (last status: $status)."
}

wait_deployment() {
    local deployment status last='' i
    for ((i = 0; i < 180; i++)); do
        deployment=$(api_json 200 GET "/api/v1/app/projects/$1/deployments/$2")
        status=$(jq -r '.data.status' <<< "$deployment")
        [ "$status" = "$last" ] || note "deployment: $status"
        last=$status
        case $status in
            succeeded) return 0 ;;
            failed | cancelled)
                # Newest first, so the end of a long build log is what comes back; kept for diagnostics.
                api_json 200 GET "/api/v1/app/projects/$1/deployments/$2/logs?per_page=200&order=desc" |
                    jq -r '.data | reverse | .[] | "\(.recorded_at) \(.stream) \(.message)"' > "$state/deployment-logs.log" || true
                tail -n 60 "$state/deployment-logs.log" >&2
                fail "Deployment $status: $(jq -c '.data.failure // {failure_code: .data.failure_code, failure_summary: .data.failure_summary}' <<< "$deployment")"
                ;;
        esac
        sleep 5
    done
    fail "Deployment did not finish in 15 minutes (last status: $status)."
}

phase_deploy() {
    [ -s "$ca" ] || fetch_ca || fail "No local CA root certificate; run the verify phase first."
    login

    step "Creating a project from $repository ($root_directory)"
    local name created project_id project slug host
    name="e2e-$(date -u +%H%M%S)"
    created=$(api_json 201 POST /api/v1/app/projects --data "$(jq -cn --arg name "$name" --arg url "$repository" \
        --arg branch "$branch" --arg root "$root_directory" \
        '{name: $name, repository: {type: "public_url", url: $url}, branch: $branch, root_directory: $root}')")
    project_id=$(jq -r '.data.id' <<< "$created")
    pass "project $project_id created, inspection $(jq -r '.data.preview_status' <<< "$created")"

    step "Waiting for the inspection"
    project=$(wait_inspection "$project_id")
    pass "inspection succeeded: builder $(jq -r '.data.stack.builder // "?"' <<< "$project"), detected port $(jq -r '.data.detected_port // "none"' <<< "$project")"
    host=$(jq -r '.data.default_domain' <<< "$project")
    slug=$(jq -r '.data.slug' <<< "$project")
    [[ $host == *".run.$domain" ]] || fail "The project's domain is $host, not under run.$domain"
    printf '%s\n%s\n' "$project_id" "$host" > "$state/project"
    grep -q " $host\$" /etc/hosts || printf '127.0.0.1 %s\n' "$host" >> /etc/hosts
    pass "project $slug at $host (added to /etc/hosts)"

    deploy_project "$project_id" "e2e-$project_id"
    fetch_project "$host"
    check_project_runtime
}

# deploy_project <project id> <idempotency key>: queues a deployment and waits for it.
deploy_project() {
    local deployment deployment_id
    step "Deploying"
    deployment=$(api_json "201 202" POST "/api/v1/app/projects/$1/deployments" \
        -H "Idempotency-Key: $2" --data "$(jq -cn --arg branch "$branch" '{branch: $branch}')")
    deployment_id=$(jq -r '.data.id' <<< "$deployment")
    pass "deployment $deployment_id queued"
    wait_deployment "$1" "$deployment_id"
    pass "deployment succeeded"
}

fetch_project() {
    step "Fetching https://$1/"
    retry 30 2 https_ok "https://$1/" || fail "https://$1/ answered $(https_status "https://$1/"), expected 200"
    pass "https://$1/ 200: $(curl -sS --max-time 20 --cacert "$ca" "https://$1/" | tr -s ' \n' ' ' | head -c 100)"
}

check_project_runtime() {
    step "The project container runs under $expected_runtime"
    local containers runtime container
    containers=$(docker ps -q --filter label=dev.sakala.managed=true)
    [ -n "$containers" ] || fail "No running container labelled dev.sakala.managed=true."
    for container in $containers; do
        runtime=$(docker inspect --format '{{.HostConfig.Runtime}}' "$container")
        note "$(docker inspect --format '{{.Name}} {{.Config.Image}}' "$container") runtime=$runtime"
        [ "$runtime" = "$expected_runtime" ] || fail "Container $container runs under $runtime, expected $expected_runtime."
    done
    if [ "$expected_runtime" = runsc ]; then
        container=$(head -n 1 <<< "$containers")
        docker exec "$container" dmesg 2> /dev/null | grep 'Starting gVisor' > /dev/null ||
            fail "The project container has runtime runsc, but its kernel is not gVisor."
        pass "the project container's kernel is gVisor (dmesg: Starting gVisor)"
    fi
}

sha() { sha256sum "$1" | cut -d' ' -f1; }
backup_sets() { find /var/lib/sakala/backups -mindepth 2 -maxdepth 2 -name manifest.env 2> /dev/null | wc -l; }

phase_upgrade() {
    local generated credentials sets_before host
    generated=$(sha /etc/sakala/secrets/generated.env)
    credentials=$(sha /etc/sakala/secrets/agent-credentials.env)
    sets_before=$(backup_sets)
    host=$(sed -n 2p "$state/project")
    local project_started
    project_started=$(docker ps -q --filter label=dev.sakala.managed=true | xargs -r docker inspect --format '{{.Id}} {{.State.StartedAt}}')

    step "upgrade.sh with the same pins"
    run_script upgrade "$home/upgrade.sh"
    grep -q 'Backup complete' "$state/upgrade.log" || fail "upgrade.sh did not report a complete backup."
    [ "$(backup_sets)" -gt "$sets_before" ] || fail "upgrade.sh did not write a new backup set."
    pass "upgrade.sh backed up first ($(backup_sets) complete set(s) in /var/lib/sakala/backups)"
    local set
    set=$(find /var/lib/sakala/backups -mindepth 1 -maxdepth 1 -type d | sort | tail -n 1)
    (cd "$set" && sha256sum -c --quiet SHA256SUMS) || fail "The new backup set fails its SHA256SUMS."
    age -d -i "$state/backup.key" -o "$state/db.dump" "$set/db.dump.age" ||
        fail "The backup's database dump does not decrypt with the age key."
    [ "$(head -c 5 "$state/db.dump")" = PGDMP ] || fail "The decrypted dump is not a pg_dump archive."
    rm -f "$state/db.dump"
    pass "the new set passes SHA256SUMS and its dump decrypts with the age key"
    [ "$(sha /etc/sakala/secrets/generated.env)" = "$generated" ] || fail "upgrade.sh changed generated.env."
    [ "$(sha /etc/sakala/secrets/agent-credentials.env)" = "$credentials" ] || fail "upgrade.sh changed the agent credentials."
    pass "generated secrets and agent credentials unchanged"
    grep -q 'is already installed' "$state/upgrade.log" && pass "gVisor was not reinstalled"
    grep -q 'Creating the first admin account' "$state/upgrade.log" && fail "upgrade.sh tried to create the admin again."

    check_services
    check_https
    check_console_config
    check_agent
    retry 30 2 https_ok "https://$host/" || fail "https://$host/ answered $(https_status "https://$host/") after the upgrade, expected 200"
    pass "https://$host/ still 200 after the upgrade"
    [ "$(docker ps -q --filter label=dev.sakala.managed=true | xargs -r docker inspect --format '{{.Id}} {{.State.StartedAt}}')" = "$project_started" ] ||
        fail "The upgrade restarted the project container, although no pin changed."
    pass "the project container kept running through the upgrade (same container, same start time)"
}

phase_uninstall() {
    local sets_before
    sets_before=$(backup_sets)
    step "uninstall.sh --yes"
    local status=0
    "$home/uninstall.sh" --yes 2>&1 | tee "$state/uninstall.log" || status=${PIPESTATUS[0]}
    [ "$status" -eq 0 ] || fail "uninstall.sh exited $status."
    pass "uninstall.sh exited 0"

    [ "$(backup_sets)" -gt "$sets_before" ] || fail "uninstall.sh did not take a final backup."
    pass "final backup taken; $(backup_sets) set(s) kept in /var/lib/sakala/backups"
    [ ! -e /etc/sakala ] || fail "/etc/sakala remains."
    [ -z "$(find /var/lib/sakala -mindepth 1 -maxdepth 1 ! -name backups)" ] || fail "/var/lib/sakala has more than backups/."
    local file
    for file in /usr/local/bin/sakala-agent /usr/local/bin/sakala-compose /etc/systemd/system/sakala-agent.service \
        /etc/systemd/system/sakala-backup.service /etc/systemd/system/sakala-backup.timer; do
        [ ! -e "$file" ] || fail "$file remains."
    done
    ! id sakala-agent > /dev/null 2>&1 || fail "The sakala-agent account remains."
    pass "configuration, state, binaries, units, and the agent account are gone"
    [ -z "$(docker ps -aq --filter label=com.docker.compose.project=sakala)" ] || fail "Control plane containers remain."
    [ -z "$(docker ps -aq --filter label=dev.sakala.managed=true)" ] || fail "Project containers remain."
    [ -z "$(docker volume ls -q --filter label=com.docker.compose.project=sakala)" ] || fail "Control plane volumes remain."
    ! docker network inspect sakala-runtime > /dev/null 2>&1 || fail "The sakala-runtime network remains."
    pass "containers, volumes, and networks are gone"
    ! ss -ltnH 'sport = :443' | grep . > /dev/null || fail "Something still listens on port 443."
    { [ -x /usr/local/bin/runsc ] && systemctl is-active --quiet docker; } || fail "Docker or gVisor was removed, but uninstall.sh documents keeping them."
    pass "Docker and gVisor stay installed, as documented"
}

phase_diagnostics() {
    local out=${1:?diagnostics needs an output directory} service
    install -d -m 0700 "$out"
    {
        date -u
        uname -a
        cat /etc/os-release
        df -h /
        free -m
    } > "$out/host.txt" 2>&1
    cp "$state"/*.log "$out/" 2> /dev/null || true
    docker info > "$out/docker-info.txt" 2>&1 || true
    docker ps -a > "$out/docker-ps.txt" 2>&1 || true
    cp /etc/docker/daemon.json "$out/daemon.json" 2> /dev/null || true
    for file in sakala.env agent.env console.env edge/run-tls.caddy; do
        [ -e "/etc/sakala/$file" ] && cp "/etc/sakala/$file" "$out/etc-sakala-${file//\//-}"
    done
    ls -la /etc/sakala/edge/global.d /var/lib/sakala/caddy/sites > "$out/edge-files.txt" 2>&1 || true
    cat /var/lib/sakala/caddy/sites/*.Caddyfile > "$out/runtime-routes.txt" 2>&1 || true
    if [ -x /usr/local/bin/sakala-compose ]; then
        sc ps -a > "$out/compose-ps.txt" 2>&1 || true
        for service in "${services[@]}"; do
            sc logs --no-color --timestamps "$service" > "$out/service-$service.log" 2>&1 || true
        done
    fi
    for container in $(docker ps -aq --filter label=dev.sakala.managed=true 2> /dev/null); do
        docker logs --timestamps "$container" > "$out/project-$container.log" 2>&1 || true
        docker inspect "$container" > "$out/project-$container.inspect.json" 2>&1 || true
    done
    for unit in sakala-agent docker sakala-backup; do
        journalctl -u "$unit.service" --no-pager -o short-iso > "$out/journal-$unit.log" 2>&1 || true
    done
    [ -s "$ca" ] && cp "$ca" "$out/local-ca-root.crt"

    # Redaction: every generated secret, the admin password, the GitHub token, and
    # anything that looks like a token or a cookie, in every collected file.
    [ ! -d /etc/sakala/secrets ] || remember_secrets
    python3 -I - "$state/redact.list" "$out" <<'PY'
import pathlib, re, sys
secrets = sorted({line.strip() for line in open(sys.argv[1]) if len(line.strip()) >= 8}, key=len, reverse=True) \
    if pathlib.Path(sys.argv[1]).exists() else []
tokens = re.compile(r'gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}')
prefixed = [
    re.compile(r'((?:TOKEN|SECRET|PASSWORD|APP_KEY)=)\S+'),
    re.compile(r'(Password, shown only this once: )\S+'),
    re.compile(r'((?:XSRF-TOKEN|__Host-sakala-api-session)=)[^;\s]+'),
]
for path in pathlib.Path(sys.argv[2]).rglob('*'):
    if not path.is_file():
        continue
    text = path.read_text(errors='replace')
    for secret in secrets:
        text = text.replace(secret, '[REDACTED]')
    text = tokens.sub('[REDACTED]', text)
    for pattern in prefixed:
        text = pattern.sub(r'\1[REDACTED]', text)
    path.write_text(text)
PY
    if [ -s "$state/redact.list" ] && grep -rqFf "$state/redact.list" "$out"; then
        fail "Redaction left a secret in $out; not uploading."
    fi
    [ -z "${SUDO_USER:-}" ] || chown -R "$SUDO_USER" "$out"
    pass "diagnostics in $out ($(find "$out" -type f | wc -l) files, secrets redacted)"
}

# tests/upgrade-e2e.sh sources this file for its functions and runs its own phases.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    case ${1:-} in
        prepare | install | verify | deploy | upgrade | uninstall | diagnostics)
            phase=$1
            shift
            "phase_$phase" "$@"
            ;;
        *)
            sed -n '3,26p' "$0" | sed 's/^# \{0,1\}//'
            exit 2
            ;;
    esac
fi
