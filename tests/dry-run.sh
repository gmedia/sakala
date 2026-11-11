#!/usr/bin/env bash

# Runs install.sh, upgrade.sh, and uninstall.sh inside throwaway Ubuntu containers
# with SAKALA_DRY_RUN=1. Everything that needs neither a Docker daemon nor systemd
# runs for real: input checks, apt packages including Docker Engine, the gVisor and
# agent downloads with their checksums, the runsc registration in daemon.json,
# generated secrets and their modes, rendered files, and `docker compose config`.
# Starting containers, systemd units, and the steps that need a running API are
# printed instead. It is not a substitute for a full install on a clean VM.
#
# Usage: tests/dry-run.sh [ubuntu:24.04 ubuntu:26.04 ...]   Needs Docker and internet.

set -euo pipefail

cd "$(dirname "$0")/.."
images=("$@")
[ "${#images[@]}" -gt 0 ] || images=(ubuntu:24.04 ubuntu:26.04)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cat > "$work/inside.sh" <<'INSIDE'
#!/usr/bin/env bash
set -uo pipefail
failures=0
pass() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; failures=$((failures + 1)); }
expect_fail() {
    local label=$1 pattern=$2 out
    shift 2
    if out=$("$@" 2>&1); then fail "$label: succeeded"; elif grep -qE -- "$pattern" <<< "$out"; then pass "$label"; else fail "$label: $out"; fi
}
mode_is() { [ "$(stat -c %a "$2")" = "$1" ] && pass "mode $1: $2" || fail "mode of $2 is $(stat -c %a "$2" 2>&1), expected $1"; }
contains() { grep -qF -- "$2" "$1" && pass "$1 has $2" || fail "$1 lacks $2"; }
lacks() { grep -qF -- "$2" "$1" && fail "$1 still has $2" || pass "$1 has no $2"; }

export SAKALA_DRY_RUN=1
install=(/opt/sakala/install.sh --yes --skip-resource-check --email admin@example.com)
fake_recipient=age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq

expect_fail "refuses a bad domain" "Not a domain name" "${install[@]}" --domain 'not a domain' --age-recipient "$fake_recipient"
expect_fail "refuses a private age key" "That is a private key" "${install[@]}" --domain sakala.example.com --age-recipient AGE-SECRET-KEY-1QQQ
expect_fail "refuses a malformed age key" "Not an age public key" "${install[@]}" --domain sakala.example.com --age-recipient age1short
expect_fail "refuses an unknown TLS mode" "must be on-demand, dns, or internal" "${install[@]}" --domain sakala.example.com --age-recipient "$fake_recipient" --tls magic
expect_fail "refuses missing input without a terminal" "is required" /opt/sakala/install.sh --yes --skip-resource-check < /dev/null

apt-get update -qq > /dev/null && apt-get install -y -qq age > /dev/null
age-keygen -o /root/test-backup.key 2> /dev/null
recipient=$(age-keygen -y /root/test-backup.key)

if "${install[@]}" --domain sakala.example.com --age-recipient "$recipient" > /root/install.log 2>&1; then
    pass "install.sh dry run on $(. /etc/os-release && echo "$PRETTY_NAME")"
else
    fail "install.sh dry run"; tail -40 /root/install.log
fi

mode_is 700 /etc/sakala/secrets
for file in generated.env api.env database.env storage.env api.local.env backup.age-recipients; do
    mode_is 600 "/etc/sakala/secrets/$file"
done
mode_is 640 /etc/sakala/secrets/github-app.pem
contains /etc/sakala/secrets/api.env 'APP_URL=https://api.sakala.example.com'
contains /etc/sakala/secrets/api.env 'SAKALA_PROJECT_DEFAULT_DOMAIN=run.sakala.example.com'
contains /etc/sakala/secrets/api.env 'SAKALA_XSRF_COOKIE_DOMAIN=.sakala.example.com'
lacks /etc/sakala/secrets/api.env '${'
contains /etc/sakala/console.env 'PUBLIC_API_URL=https://api.sakala.example.com'
reverb_key=$(sed -n 's/^SAKALA_REVERB_APP_KEY=//p' /etc/sakala/secrets/generated.env)
contains /etc/sakala/console.env "PUBLIC_REVERB_KEY=$reverb_key"
lacks /etc/sakala/console.env 'REVERB_APP_SECRET'
contains /etc/sakala/agent.env 'SAKALA_CONTAINER_RUNTIME=runsc'
contains /etc/sakala/agent.env 'SAKALA_API_URL=http://127.0.0.1:8100'
contains /etc/sakala/edge/run-tls.caddy 'on_demand'
contains /etc/docker/daemon.json '"runsc"'
contains /etc/docker/daemon.json 'default-address-pools'
contains /etc/systemd/system/sakala-backup.service 'ExecStart=/opt/sakala/scripts/backup.sh'
grep -q 'gvisor.tar.zstd: OK' /root/install.log && pass "gVisor archive matched its .sha512" || fail "gVisor checksum line missing"
/usr/local/bin/runsc --version | grep -q 'release-' && pass "runsc installed: $(/usr/local/bin/runsc --version | head -n 1)" || fail "runsc not installed"
pin=$(sed -n 's/^SAKALA_AGENT_SHA256=//p' /opt/sakala/versions.env)
[ "$(sha256sum /usr/local/bin/sakala-agent | cut -d' ' -f1)" = "$pin" ] && pass "agent binary matches the pin" || fail "agent binary does not match the pin"
grep -q 'compose up -d --wait postgres' /root/install.log && pass "starting the stack is printed, not run" || fail "no dry-run compose line"
[ -x /usr/local/bin/sakala-compose ] && pass "sakala-compose helper installed" || fail "no sakala-compose"

before=$(sha256sum /etc/sakala/secrets/generated.env)
if "${install[@]}" --domain sakala.example.com --age-recipient "$recipient" > /root/rerun.log 2>&1; then pass "second run succeeds"; else fail "second run"; tail -20 /root/rerun.log; fi
[ "$before" = "$(sha256sum /etc/sakala/secrets/generated.env)" ] && pass "second run keeps the generated secrets" || fail "second run changed generated.env"
grep -q 'release-.* is already installed' /root/rerun.log && pass "second run skips gVisor" || fail "second run reinstalled gVisor"
grep -q 'Reusing the installed Docker Engine' /root/rerun.log && pass "second run reuses the installed Docker Engine" || fail "second run did not detect the installed Docker Engine"
expect_fail "refuses to change the domain" "installed for sakala.example.com" "${install[@]}" --domain other.example.com

if SAKALA_DNS_API_TOKEN=test-token-123 "${install[@]}" --tls dns --dns-provider cloudflare > /root/dns.log 2>&1; then pass "DNS mode dry run"; else fail "DNS mode dry run"; tail -20 /root/dns.log; fi
mode_is 600 /etc/sakala/secrets/dns.env
contains /etc/sakala/edge/run-tls.caddy 'dns cloudflare {env.SAKALA_DNS_API_TOKEN}'
contains /etc/sakala/sakala.env 'SAKALA_DNS_MODULE=github.com/caddy-dns/cloudflare@v0.2.4'
grep -q '^SAKALA_EDGE_IMAGE=sakala-edge-dns:' /etc/sakala/sakala.env && pass "DNS mode selects the locally built edge" || fail "no edge image in DNS mode"
grep -q 'docker build --pull -f /opt/sakala/caddy/Dockerfile.dns' /root/dns.log && pass "DNS mode builds the edge" || fail "DNS mode build line missing"
lacks /root/dns.log 'test-token-123'

if "${install[@]}" --tls internal > /root/internal.log 2>&1; then pass "internal TLS mode dry run"; else fail "internal TLS mode dry run"; tail -20 /root/internal.log; fi
contains /etc/sakala/edge/run-tls.caddy 'tls internal'
contains /etc/sakala/edge/global.d/00-sakala-tls-internal.caddy 'local_certs'
contains /etc/sakala/sakala.env 'SAKALA_TLS_MODE=internal'
grep -q '^SAKALA_EDGE_IMAGE=$' /etc/sakala/sakala.env && pass "internal mode uses the stock edge image" || fail "internal mode kept a DNS edge image"
[ ! -e /etc/sakala/secrets/dns.env ] && pass "internal mode removes the DNS token" || fail "dns.env remains in internal mode"
grep -q 'compose restart edge' /root/internal.log && pass "a TLS mode change restarts the edge" || fail "no edge restart after the TLS mode change"
grep -q 'only for tests and private networks' /root/internal.log && pass "internal mode warns that it is not for public installs" || fail "no internal-mode warning"

if /opt/sakala/upgrade.sh > /root/upgrade.log 2>&1; then pass "upgrade.sh dry run"; else fail "upgrade.sh"; tail -20 /root/upgrade.log; fi
grep -q 'systemctl start sakala-backup.service' /root/upgrade.log && pass "upgrade backs up first" || fail "upgrade did not back up first"

mkdir -p /var/lib/sakala/backups/20260101T000000Z
if /opt/sakala/uninstall.sh --yes > /root/uninstall.log 2>&1; then pass "uninstall.sh dry run"; else fail "uninstall.sh"; tail -20 /root/uninstall.log; fi
[ ! -e /etc/sakala ] && pass "uninstall removes /etc/sakala" || fail "/etc/sakala remains"
[ -d /var/lib/sakala/backups/20260101T000000Z ] && pass "uninstall keeps the backups" || fail "backups were deleted"
[ ! -e /var/lib/sakala/builds ] && pass "uninstall removes the rest of /var/lib/sakala" || fail "/var/lib/sakala/builds remains"

exit "$failures"
INSIDE
chmod +x "$work/inside.sh"

failures=0
for image in "${images[@]}"; do
    printf '\n== %s\n' "$image"
    if ! timeout 1200 docker run --rm --network host -v "$PWD:/opt/sakala:ro" -v "$work/inside.sh:/inside.sh:ro" \
        "$image" /inside.sh; then
        failures=$((failures + 1))
    fi
done

printf '\n== ubuntu:22.04 (unsupported)\n'
out=$(docker run --rm -v "$PWD:/opt/sakala:ro" ubuntu:22.04 \
    env SAKALA_DRY_RUN=1 /opt/sakala/install.sh --yes 2>&1 || true)
if grep -q 'Unsupported system: Ubuntu 22.04' <<< "$out"; then
    printf 'ok   refuses Ubuntu 22.04\n'
else
    printf 'FAIL ubuntu:22.04 was not refused: %s\n' "$out"
    failures=$((failures + 1))
fi

if [ "$failures" -gt 0 ]; then
    printf '\n%s check group(s) had failures.\n' "$failures"
    exit 1
fi
printf '\nAll dry-run checks passed.\n'
