#!/usr/bin/env bash
# Exercise src/dns-check.sh against a stubbed resolver.
#
# assert-dns-check.sh covers the same script against a real peer on a real
# server, and that is where the resolver path belongs. What is left here is what
# no live network can be asked to produce on demand:
#
#   - one name answering with a private and a public address at once,
#   - an address in RFC 1918 rather than in the range NetBird hands out,
#
# and input that is refused before DNS is ever consulted, which needs no network
# and should not wait for one to boot in order to say so.
set -uo pipefail

SCRIPT="${GITHUB_WORKSPACE:-$PWD}/src/dns-check.sh"
WORK="$(mktemp -d)"
BIN="$WORK/bin"
FIXTURE="$WORK/hosts"

trap 'rm -rf "$WORK"' EXIT
mkdir -p "$BIN"

# One line per name: '<name> <ip> <ip>...'. A name that is not listed is
# NXDOMAIN, which getent reports as exit 2.
cat > "$BIN/getent" << 'EOF'
#!/usr/bin/env bash
if [ "$1" != 'ahostsv4' ]; then
  exec /usr/bin/getent "$@"
fi

answer="$(grep -E "^$2 " "$GETENT_FIXTURE" 2> /dev/null | head -n1)"

if [ -z "$answer" ]; then
  exit 2
fi

for ip in ${answer#* }; do
  echo "$ip STREAM $2"
  echo "$ip DGRAM"
done
EOF

# Only the failure path shells out, and only to print diagnostics. Swallowing
# that here keeps the assertions looking at what the script itself said.
cat > "$BIN/sudo" << 'EOF'
#!/usr/bin/env bash
exit 0
EOF

chmod +x "$BIN"/*

cat > "$FIXTURE" << 'EOF'
lan.example.com 10.1.2.3
api.example.com 93.184.216.34
dual.example.com 100.64.0.9 93.184.216.34
EOF

failures=0

# Runs the script with the given inputs and checks how it ended and what it
# said. Every case needs both: an exit code alone would not tell a name that was
# rejected for answering publicly from one that never resolved at all. An empty
# expectation means the script should have had nothing to say.
check() {
  local description="$1" expected_status="$2" expected_output="$3"
  shift 3

  local output status
  output="$(
    env PATH="$BIN:$PATH" GETENT_FIXTURE="$FIXTURE" INPUT_TIMEOUT=2 "$@" \
      bash "$SCRIPT" 2>&1
  )"
  status=$?

  if [ "$status" -ne "$expected_status" ]; then
    echo "::error::${description}: expected exit ${expected_status}, got ${status}"
    printf '%s\n' "$output"
    failures=$((failures + 1))
    return
  fi

  if [ -z "$expected_output" ]; then
    if [ -n "$output" ]; then
      echo "::error::${description}: expected no output, got:"
      printf '%s\n' "$output"
      failures=$((failures + 1))
      return
    fi
  elif ! printf '%s' "$output" | grep -qF "$expected_output"; then
    echo "::error::${description}: the output does not mention '${expected_output}'"
    printf '%s\n' "$output"
    failures=$((failures + 1))
    return
  fi

  echo "ok - ${description}"
}

# The end-to-end peer only ever holds a 100.64/10 address, so the other half of
# what counts as inside the network goes untested without a stub.
echo '=== An address inside the network but outside the NetBird range ==='
check 'RFC 1918 counts as inside too' 0 'lan.example.com resolved to 10.1.2.3' \
  INPUT_DNS_HOSTNAMES='lan.example.com'

# One name, two answers, one of them public. Real DNS cannot be made to hold
# that pose to order, and it is what the guard is really for: a name only half
# published in the NetBird zone still sends the next step out of the mesh.
echo '=== A name answering from both sides at once ==='
check 'a public answer alongside a private one is still rejected' 1 'dual.example.com resolved outside the network' \
  INPUT_DNS_HOSTNAMES='dual.example.com'
check 'the rejection names the address that was outside' 1 'to 93.184.216.34' \
  INPUT_DNS_HOSTNAMES='dual.example.com'
check 'it passes once private addresses are not required' 0 'dual.example.com resolved to' \
  INPUT_DNS_HOSTNAMES='dual.example.com' INPUT_DNS_REQUIRE_PRIVATE='false'

# A name that is ready cannot drag one that is not through with it.
echo '=== One name ready, one not ==='
check 'one good name does not carry a bad one' 1 'api.example.com resolved outside the network' \
  INPUT_DNS_HOSTNAMES='lan.example.com,api.example.com'

echo '=== Nothing asked for ==='
check 'an empty input does nothing at all' 0 '' \
  INPUT_DNS_HOSTNAMES=''
check 'separators on their own do nothing either' 0 '' \
  INPUT_DNS_HOSTNAMES=' , ,  '
# The other inputs are only worth validating once there is a wait to run.
check 'a workflow that never sets dns-hostnames cannot fail here' 0 '' \
  INPUT_DNS_HOSTNAMES='' INPUT_DNS_REQUIRE_PRIVATE='nonsense' INPUT_TIMEOUT='not-a-number'

echo '=== Input that cannot be used ==='
check 'a name that is not a hostname is refused' 1 "input 'dns-hostnames' contains 'not_a_host!'" \
  INPUT_DNS_HOSTNAMES='not_a_host!'
check 'a URL is refused rather than unwrapped' 1 "input 'dns-hostnames' contains 'https://db.netbird.cloud/health'" \
  INPUT_DNS_HOSTNAMES='https://db.netbird.cloud/health'
check 'a host:port is refused' 1 "input 'dns-hostnames' contains 'db.netbird.cloud:5432'" \
  INPUT_DNS_HOSTNAMES='db.netbird.cloud:5432'
check 'a trailing dot is refused' 1 "input 'dns-hostnames' contains 'db.netbird.cloud.'" \
  INPUT_DNS_HOSTNAMES='db.netbird.cloud.'
check 'an IPv6 literal is refused' 1 "input 'dns-hostnames' contains" \
  INPUT_DNS_HOSTNAMES='[::1]'
check 'dns-require-private takes only true or false' 1 "input 'dns-require-private' must be" \
  INPUT_DNS_HOSTNAMES='lan.example.com' INPUT_DNS_REQUIRE_PRIVATE='yes'
check 'a timeout that is not a number is refused' 1 "input 'timeout' must be" \
  INPUT_DNS_HOSTNAMES='lan.example.com' INPUT_TIMEOUT='soon'

if [ "$failures" -ne 0 ]; then
  echo "::error::${failures} dns-check case(s) failed"
  exit 1
fi

echo 'every dns-check case passed'
