#!/usr/bin/env bash

# Renders compose.yaml with sample settings in a temporary directory, in both TLS
# modes, and checks the parts that matter: every image is the pinned digest, only
# the edge publishes public ports, the DNS token reaches the edge alone, and the
# runtime router gets the addresses it may trust for X-Forwarded-* (and Compose
# refuses to start without them). Also checks the Caddyfiles keep that trust
# narrow. Needs the docker CLI with the compose plugin; no daemon.

# pass and fail always return 0, so `test && pass || fail` is a plain if-else here.
# shellcheck disable=SC2015

set -euo pipefail

cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0
pass() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; failures=$((failures + 1)); }

mkdir -p "$work/secrets"
for file in api.env database.env storage.env github-app.pem; do : > "$work/secrets/$file"; done
printf 'PUBLIC_API_URL=https://api.sakala.example.com\n' > "$work/console.env"

# What install.sh writes from the sakala-runtime network: here an IPv4 and an IPv6 subnet.
trusted='172.18.0.0/16 fd00:5ac:a1a::/64'

render() {
    local mode=$1 trusted_line=${2-SAKALA_RUNTIME_TRUSTED_PROXIES=$trusted}
    {
        printf 'SAKALA_DOMAIN=sakala.example.com\nSAKALA_ADMIN_EMAIL=admin@example.com\n'
        printf 'SAKALA_TLS_MODE=%s\nSAKALA_CONFIG_DIR=%s\nSAKALA_SECRETS_DIR=%s\nSAKALA_STATE_DIR=%s\n' \
            "$mode" "$work" "$work/secrets" "$work/state"
        [ "$mode" = on-demand ] || printf 'SAKALA_EDGE_IMAGE=sakala-edge-dns:test\n'
        [ -z "$trusted_line" ] || printf '%s\n' "$trusted_line"
    } > "$work/sakala.env"
    if [ "$mode" = dns ]; then
        printf 'SAKALA_DNS_API_TOKEN=sample-token\n' > "$work/secrets/dns.env"
    else
        rm -f "$work/secrets/dns.env"
    fi
    docker compose --project-directory . -f compose.yaml --env-file "$work/sakala.env" --env-file versions.env \
        config --format json
}

for mode in on-demand dns; do
    if ! json=$(render "$mode" 2> "$work/err"); then
        fail "$mode: docker compose config failed: $(cat "$work/err")"
        continue
    fi
    pass "$mode: docker compose config"

    unpinned=$(jq -r '.services | to_entries[] | select(.value.image | test("@sha256:[0-9a-f]{64}$") | not) | "\(.key)=\(.value.image)"' <<< "$json")
    if [ "$mode" = on-demand ]; then
        [ -z "$unpinned" ] && pass "$mode: every image is pinned by digest" || fail "$mode: unpinned images: $unpinned"
    else
        [ "$unpinned" = "edge=sakala-edge-dns:test" ] && pass "$mode: only the locally built edge is not a registry digest" || fail "$mode: unpinned images: $unpinned"
    fi

    public=$(jq -r '.services | to_entries[] | select(.value.ports != null) | .key as $s | .value.ports[] | select((.host_ip // "") != "127.0.0.1") | "\($s):\(.published)"' <<< "$json" | sort -u | tr '\n' ' ')
    [ "$public" = "edge:443 edge:80 " ] && pass "$mode: only the edge publishes public ports" || fail "$mode: public ports: $public"

    holders=$(jq -r '.services | to_entries[] | select(.value.environment.SAKALA_DNS_API_TOKEN != null) | .key' <<< "$json" | tr '\n' ' ')
    if [ "$mode" = dns ]; then
        [ "$holders" = "edge " ] && pass "$mode: only the edge gets the DNS token" || fail "$mode: DNS token in: $holders"
    else
        [ -z "$holders" ] && pass "$mode: no service gets a DNS token" || fail "$mode: DNS token in: $holders"
    fi

    got=$(jq -r '.services["runtime-caddy"].environment.SAKALA_RUNTIME_TRUSTED_PROXIES // "missing"' <<< "$json")
    [ "$got" = "$trusted" ] && pass "$mode: the runtime router gets SAKALA_RUNTIME_TRUSTED_PROXIES" || fail "$mode: runtime router trusts: $got"
    holders=$(jq -r '.services | to_entries[] | select(.value.environment.SAKALA_RUNTIME_TRUSTED_PROXIES != null) | .key' <<< "$json" | tr '\n' ' ')
    [ "$holders" = "runtime-caddy " ] && pass "$mode: only the runtime router gets the trusted addresses" || fail "$mode: trusted addresses in: $holders"
done

# Without the value the router would trust nobody and tell every app the visitor used plain HTTP.
for line in '' 'SAKALA_RUNTIME_TRUSTED_PROXIES='; do
    if render on-demand "$line" > /dev/null 2> "$work/err"; then
        fail "compose config accepts ${line:-a missing SAKALA_RUNTIME_TRUSTED_PROXIES}"
    elif grep -q 'SAKALA_RUNTIME_TRUSTED_PROXIES' "$work/err"; then
        pass "compose config refuses ${line:-a missing SAKALA_RUNTIME_TRUSTED_PROXIES}"
    else
        fail "compose config failed for another reason: $(cat "$work/err")"
    fi
done

# The router trusts X-Forwarded-* from the edge's network alone; the edge trusts no one.
# Comments are stripped first, so only directives count.
directives() { sed -e 's/#.*//' "$@"; }
# shellcheck disable=SC2016 # a literal Caddy placeholder, not a shell expansion
directives caddy/runtime.Caddyfile | grep -qE '^[[:space:]]*trusted_proxies static \{\$SAKALA_RUNTIME_TRUSTED_PROXIES\}[[:space:]]*$' &&
    pass "runtime router: trusted_proxies comes from SAKALA_RUNTIME_TRUSTED_PROXIES" || fail "runtime router: no trusted_proxies static {\$SAKALA_RUNTIME_TRUSTED_PROXIES}"
directives caddy/runtime.Caddyfile | grep -qE '^[[:space:]]*trusted_proxies_strict[[:space:]]*$' &&
    pass "runtime router: trusted_proxies_strict" || fail "runtime router: no trusted_proxies_strict"
directives caddy/runtime.Caddyfile | grep -qE '^[[:space:]]*client_ip_headers X-Forwarded-For[[:space:]]*$' &&
    pass "runtime router: client_ip_headers X-Forwarded-For" || fail "runtime router: no client_ip_headers X-Forwarded-For"
[ "$(directives caddy/runtime.Caddyfile | grep -c 'trusted_proxies ')" -eq 1 ] &&
    pass "runtime router: exactly one trusted_proxies" || fail "runtime router: more than one trusted_proxies"
broad=$(directives caddy/*.Caddyfile caddy/*.caddy | grep -nE 'private_ranges|0\.0\.0\.0/0|::/0' || true)
[ -z "$broad" ] && pass "no Caddy file trusts private_ranges or a /0 range" || fail "broad trusted range: $broad"
edge_trust=$(directives caddy/edge.Caddyfile caddy/global-tls-internal.caddy caddy/run-tls.*.caddy | grep -nE 'trusted_proxies|client_ip_headers' || true)
[ -z "$edge_trust" ] && pass "the edge trusts no proxy" || fail "the edge trusts a proxy: $edge_trust"

[ "$failures" -eq 0 ] || exit 1
printf 'All compose checks passed.\n'
