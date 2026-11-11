#!/usr/bin/env bash

# Renders compose.yaml with sample settings in a temporary directory, in both TLS
# modes, and checks the parts that matter: every image is the pinned digest, only
# the edge publishes public ports, and the DNS token reaches the edge alone.
# Needs the docker CLI with the compose plugin; no daemon.

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

render() {
    local mode=$1
    {
        printf 'SAKALA_DOMAIN=sakala.example.com\nSAKALA_ADMIN_EMAIL=admin@example.com\n'
        printf 'SAKALA_TLS_MODE=%s\nSAKALA_CONFIG_DIR=%s\nSAKALA_SECRETS_DIR=%s\nSAKALA_STATE_DIR=%s\n' \
            "$mode" "$work" "$work/secrets" "$work/state"
        [ "$mode" = on-demand ] || printf 'SAKALA_EDGE_IMAGE=sakala-edge-dns:test\n'
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
done

[ "$failures" -eq 0 ] || exit 1
printf 'All compose checks passed.\n'
