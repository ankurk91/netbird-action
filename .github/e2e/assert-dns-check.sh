#!/usr/bin/env bash
# Run src/dns-check.sh against the network the action just joined.
#
# No stubs: a real peer on a real server, names resolved through the runner's
# own resolver. The peer's own record is what makes this possible - a network of
# one peer still publishes a name, and it is the only name here that is certain
# to exist.
set -uo pipefail

DNS_CHECK="${GITHUB_WORKSPACE:-$PWD}/src/dns-check.sh"

# The client is the only thing that knows the domain the server hands out, which
# differs between NetBird cloud and a self-hosted deployment. Reading it back
# keeps this from hard-coding a domain the throwaway server may not use.
fqdn="$(sudo netbird status -d | awk '/FQDN:/ { print $NF; exit }')"

if [ -z "$fqdn" ]; then
  echo '::error::the client reports no FQDN, so it was never given a DNS name'
  sudo netbird status -d
  exit 1
fi

echo "the peer calls itself $fqdn, and holds $NETBIRD_IP"

# A name under the peer's own domain that nothing registered. NetBird answers
# for that zone, so this is its NXDOMAIN rather than the public resolver's.
missing="no-such-peer-${GITHUB_RUN_ID:-0}.${fqdn#*.}"

failures=0

# Runs the script the action runs, with the inputs a workflow would set. The
# timeout is per case: the ones expected to pass need room for NetBird's DNS to
# settle, and the ones expected to fail should not spend it.
check() {
  local description="$1" expected_status="$2" expected_output="$3"
  shift 3

  local output status
  output="$(env "$@" bash "$DNS_CHECK" 2>&1)"
  status=$?

  if [ "$status" -ne "$expected_status" ]; then
    echo "::error::${description}: expected exit ${expected_status}, got ${status}"
    printf '%s\n' "$output"
    failures=$((failures + 1))
    return
  fi

  if [ -n "$expected_output" ] && ! printf '%s' "$output" | grep -qF "$expected_output"; then
    echo "::error::${description}: the output does not mention '${expected_output}'"
    printf '%s\n' "$output"
    failures=$((failures + 1))
    return
  fi

  echo "ok - ${description}"
}

echo '=== A name the network really publishes ==='
# The whole point of the input: the peer's own name, resolved through NSS the
# way a later step's curl would, and answering with its address on the overlay.
check 'the peer resolves its own name to its own overlay address' 0 "$fqdn resolved to $NETBIRD_IP" \
  INPUT_DNS_HOSTNAMES="$fqdn" INPUT_TIMEOUT=30

check 'the same list written over several lines is read in full' 0 "resolved to $NETBIRD_IP" \
  INPUT_DNS_HOSTNAMES="$fqdn,
$fqdn" INPUT_TIMEOUT=30

echo '=== A name the network does not publish ==='
check 'a name nothing registered is waited on, then fails' 1 "$missing did not resolve" \
  INPUT_DNS_HOSTNAMES="$missing" INPUT_TIMEOUT=5

echo '=== A name that answers from outside the network ==='
# Public DNS still works after joining: NetBird takes over its own zone, not
# every name. So this really is a public answer reaching a real resolver, which
# is the split-horizon failure the guard exists to catch.
check 'a public answer is refused while private addresses are required' 1 'resolved outside the network' \
  INPUT_DNS_HOSTNAMES='example.com' INPUT_TIMEOUT=5

check 'the same name passes once private addresses are not required' 0 'example.com resolved to' \
  INPUT_DNS_HOSTNAMES='example.com' INPUT_DNS_REQUIRE_PRIVATE=false INPUT_TIMEOUT=15

echo '=== Nothing asked for ==='
check 'a workflow that sets no names does nothing' 0 '' \
  INPUT_DNS_HOSTNAMES='' INPUT_TIMEOUT=5

if [ "$failures" -ne 0 ]; then
  echo "::error::${failures} dns-check case(s) failed against the real network"
  sudo netbird status -d
  exit 1
fi

echo 'the DNS wait behaves against a real network'
