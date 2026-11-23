#!/usr/bin/env bash

# Proves the edge Caddy configuration with real Caddy containers on this machine:
#   - the on-demand TLS gate says yes only for hostnames the runtime router has a route for,
#     even when that project itself answers 404;
#   - a TLS handshake for a routed project succeeds and one for an unknown name fails;
#   - the DNS-mode configuration parses;
#   - a project sees the visitor's scheme and address in X-Forwarded-*, while a
#     forged X-Forwarded-For, from a visitor or from a workload that shares a
#     network with the router, never reaches it as the client address.
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
    docker rm -f "$prefix-router" "$prefix-edge" "$prefix-app" > /dev/null 2>&1 || true
    docker network rm "$prefix" "$prefix-project" "$prefix-public" > /dev/null 2>&1 || true
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
# A project that echoes the forwarding headers it receives, routed as the agent
# routes projects today, and as it will once it sets the client address itself.
printf 'fwd.run.example.test:80 {\n\treverse_proxy app:8080\n}\n' > "$work/sites/0191-fwd.Caddyfile"
printf 'fwd-next.run.example.test:80 {\n\treverse_proxy app:8080 {\n\t\theader_up X-Forwarded-For {client_ip}\n\t\theader_up X-Real-IP {client_ip}\n\t}\n}\n' \
    > "$work/sites/0192-fwd-next.Caddyfile"
mkdir -p "$work/app"
printf '{\n\tadmin off\n\tauto_https off\n}\n:8080 {\n\trespond "proto={header.X-Forwarded-Proto} host={header.X-Forwarded-Host} for={header.X-Forwarded-For} real={header.X-Real-IP}"\n}\n' \
    > "$work/app/Caddyfile"
chmod -R a+rX "$work"

# "$prefix" stands in for sakala-runtime (the edge and the router only),
# "$prefix-project" for a project's network (the router and that project's
# containers), and "$prefix-public" for the internet in front of the edge.
docker network create "$prefix" > /dev/null
docker network create "$prefix-project" > /dev/null
docker network create "$prefix-public" > /dev/null
trusted=$(docker network inspect "$prefix" --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}')
docker run -d --name "$prefix-router" --network "$prefix" --network-alias sakala-caddy \
    -e SAKALA_RUNTIME_TRUSTED_PROXIES="$trusted" -e SAKALA_DOMAIN=example.test \
    -v "$PWD/caddy/runtime.Caddyfile:/etc/caddy/Caddyfile:ro" \
    -v "$work/sites:/etc/caddy/sites:ro" \
    "$SAKALA_CADDY_IMAGE" > /dev/null
docker network connect --alias fwd.run.example.test --alias fwd-next.run.example.test "$prefix-project" "$prefix-router"
docker run -d --name "$prefix-app" --network "$prefix-project" --network-alias app \
    -v "$work/app/Caddyfile:/etc/caddy/Caddyfile:ro" \
    "$SAKALA_CADDY_IMAGE" > /dev/null
docker run -d --name "$prefix-edge" --network "$prefix" -p 127.0.0.1::443 \
    -e SAKALA_DOMAIN=example.test -e SAKALA_ADMIN_EMAIL=admin@example.test \
    -e SAKALA_ACME_CA=https://127.0.0.1:9/directory \
    -v "$PWD/caddy/edge.Caddyfile:/etc/caddy/Caddyfile:ro" \
    -v "$work/edge:/etc/caddy/sakala:ro" \
    "$SAKALA_CADDY_IMAGE" > /dev/null
docker network connect --alias fwd.run.example.test --alias fwd-next.run.example.test "$prefix-public" "$prefix-edge"

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

# The router's answer for a hostname it has no route for: the not-found page,
# 404, never cached, the Console at app.<domain>, and the hostname not repeated.
page=$(docker run --rm --network "$prefix" "$SAKALA_CADDY_IMAGE" sh -c \
    'printf "GET / HTTP/1.0\r\nHost: gone.run.example.test\r\n\r\n" | nc sakala-caddy 80' 2>&1 || true)
if grep -q '^HTTP/1.0 404' <<< "$page" && grep -qi '^Cache-Control: no-store' <<< "$page" \
    && grep -qi '^X-Sakala-Route: missing' <<< "$page" \
    && grep -q '<title>Belum ada aplikasi di alamat ini</title>' <<< "$page" \
    && grep -q '<a href="https://app.example.test">Console Sakala</a>' <<< "$page" \
    && ! grep -q 'gone.run.example.test' <<< "$page"; then
    pass "router: an unknown hostname gets the not-found page, linking app.<domain>"
else
    fail "router: unknown hostname answered: $(head -c 600 <<< "$page")"
fi

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

# Forwarding headers. A visitor on the public network forges all of them; the
# edge must replace them from the connection, and the router must keep what the
# edge set. (A visitor through the published port would arrive from the Docker
# gateway, which is inside the trusted subnet, and prove less.)
forged=203.0.113.9
edge_ip=$(docker inspect --format "{{(index .NetworkSettings.Networks \"$prefix\").IPAddress}}" "$prefix-edge")
# visit <network> <url>: prints the visitor's own address, then the project's answer.
visit() {
    docker run --rm --network "$1" "$SAKALA_CADDY_IMAGE" sh -c \
        'printf "%s " "$(hostname -i)"; wget -qO- --no-check-certificate --header "X-Forwarded-For: $1" --header "X-Forwarded-Proto: http" --header "X-Forwarded-Host: forged.example" --header "X-Real-IP: $1" "$2"' \
        sh "$forged" "$2" 2>&1 || true
}
out=$(visit "$prefix-public" https://fwd.run.example.test/)
visitor=${out%% *}
body=${out#* }
if [ "$body" = "proto=https host=fwd.run.example.test for=$visitor, $edge_ip real=$forged" ]; then
    pass "headers: the project sees https, its host, and the visitor then the edge in X-Forwarded-For"
else
    fail "headers: the project behind the edge received: $body (visitor $visitor, edge $edge_ip)"
fi
out=$(visit "$prefix-public" https://fwd-next.run.example.test/)
visitor=${out%% *}
body=${out#* }
if [ "$body" = "proto=https host=fwd-next.run.example.test for=$visitor real=$visitor" ]; then
    pass "headers: with {client_ip}, X-Forwarded-For and X-Real-IP name only the visitor"
else
    fail "headers: with {client_ip} the project behind the edge received: $body (visitor $visitor)"
fi

# A workload on the project network talks to the router directly and forges the
# headers. The router must not trust it, although it shares a network with the router.
out=$(visit "$prefix-project" http://fwd.run.example.test/)
neighbor=${out%% *}
body=${out#* }
if [ "$body" = "proto=http host=fwd.run.example.test for=$neighbor real=$forged" ]; then
    pass "headers: a workload next to the router cannot forge X-Forwarded-For or -Proto"
else
    fail "headers: a forging workload ($neighbor) got the project to see: $body"
fi
out=$(visit "$prefix-project" http://fwd-next.run.example.test/)
neighbor=${out%% *}
body=${out#* }
if [ "$body" = "proto=http host=fwd-next.run.example.test for=$neighbor real=$neighbor" ]; then
    pass "headers: with {client_ip}, a forging workload is named by its own address"
else
    fail "headers: with {client_ip} a forging workload ($neighbor) got the project to see: $body"
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
