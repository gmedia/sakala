#!/usr/bin/env bash

# Proves the edge Caddy configuration with real Caddy containers on this machine:
#   - the on-demand TLS gate says yes only for hostnames the runtime router has a route for,
#     even when that project itself answers 404;
#   - a TLS handshake for a routed project succeeds and one for an unknown name fails;
#   - the DNS-mode configuration parses.
# Certificates come from Caddy's internal CA (`local_certs`), so nothing reaches an ACME server.
# Needs Docker. Touches no server.

set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
. ./versions.env

prefix="sakala-edge-test-$$"
work=$(mktemp -d)
failures=0

cleanup() {
    docker rm -f "$prefix-router" "$prefix-edge" > /dev/null 2>&1 || true
    docker network rm "$prefix" > /dev/null 2>&1 || true
    rm -rf "$work"
}
trap cleanup EXIT

pass() { printf 'ok   %s\n' "$1"; }
fail() {
    printf 'FAIL %s\n' "$1" >&2
    failures=$((failures + 1))
}

mkdir -p "$work/sites" "$work/edge/global.d"
cp caddy/run-tls.on-demand.caddy "$work/edge/run-tls.caddy"
printf 'local_certs\n' > "$work/edge/global.d/test.caddy"
# What the agent writes for a deployed project; this one answers 404 on purpose.
printf 'known.run.example.test:80 {\n\trespond "the project says not found" 404\n}\n' > "$work/sites/0190-test.Caddyfile"
chmod -R a+rX "$work"

docker network create "$prefix" > /dev/null
docker run -d --name "$prefix-router" --network "$prefix" --network-alias sakala-caddy \
    -v "$PWD/caddy/runtime.Caddyfile:/etc/caddy/Caddyfile:ro" \
    -v "$work/sites:/etc/caddy/sites:ro" \
    "$SAKALA_CADDY_IMAGE" > /dev/null
docker run -d --name "$prefix-edge" --network "$prefix" -p 127.0.0.1::443 \
    -e SAKALA_DOMAIN=example.test -e SAKALA_ADMIN_EMAIL=admin@example.test \
    -e SAKALA_ACME_CA=https://127.0.0.1:9/directory \
    -v "$PWD/caddy/edge.Caddyfile:/etc/caddy/Caddyfile:ro" \
    -v "$work/edge:/etc/caddy/sakala:ro" \
    "$SAKALA_CADDY_IMAGE" > /dev/null

ask() {
    docker exec "$prefix-edge" wget -q -O /dev/null "http://127.0.0.1:5555/tls-ask?domain=$1" 2> /dev/null
}

for _ in $(seq 1 50); do
    docker exec "$prefix-edge" wget -q -O /dev/null http://127.0.0.1:5555/ 2> /dev/null && break
    # The catch-all answers 404, which wget reports as an error; any HTTP answer means it is up.
    docker exec "$prefix-edge" wget -S -O /dev/null http://127.0.0.1:5555/ 2>&1 | grep -q 'HTTP/' && break
    sleep 0.2
done

if ask known.run.example.test; then pass "ask: a routed project may get a certificate"; else fail "ask: routed project was refused"; fi
if ask unknown.run.example.test; then fail "ask: an unknown project was allowed"; else pass "ask: an unknown project is refused"; fi
if ask known.run.example.test.evil.example; then fail "ask: a name outside run.<domain> was allowed"; else pass "ask: a name outside run.<domain> is refused"; fi
if ask ''; then fail "ask: an empty name was allowed"; else pass "ask: an empty name is refused"; fi

port=$(docker port "$prefix-edge" 443/tcp | head -n 1 | sed 's/.*://')
body=$(curl -sk --max-time 20 --resolve "known.run.example.test:$port:127.0.0.1" "https://known.run.example.test:$port/" || true)
if [ "$body" = "the project says not found" ]; then
    pass "tls: a routed project is served over HTTPS"
else
    fail "tls: routed project over HTTPS answered: $body"
    docker logs "$prefix-edge" 2>&1 | tail -20 >&2
fi
if curl -sk --max-time 20 --resolve "unknown.run.example.test:$port:127.0.0.1" "https://unknown.run.example.test:$port/" > /dev/null 2>&1; then
    fail "tls: an unknown project completed a TLS handshake"
else
    pass "tls: an unknown project gets no certificate"
fi

# DNS mode: the same Caddyfile with the wildcard snippet must parse once a module provides `dns`.
# The stock image has no DNS module, so only the adapter's verdict on everything else is checked.
sed 's/@@SAKALA_DNS_PROVIDER@@/cloudflare/' caddy/run-tls.dns.caddy > "$work/edge/run-tls.caddy"
out=$(docker exec -e SAKALA_DNS_API_TOKEN=placeholder "$prefix-edge" caddy adapt --config /etc/caddy/Caddyfile 2>&1 || true)
if grep -q 'dns.providers.cloudflare' <<< "$out"; then
    pass "dns mode: the configuration asks for the cloudflare DNS module"
else
    fail "dns mode: unexpected adapter output: $out"
fi

if [ "$failures" -gt 0 ]; then
    printf '%s check(s) failed.\n' "$failures" >&2
    exit 1
fi
printf 'All edge checks passed.\n'
