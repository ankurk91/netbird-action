#!/usr/bin/env bash
# Wait until the names the job depends on resolve inside the network.
#
# `netbird status --check startup` - what connect.sh waits on - covers
# management, signal and a relay. That is the control plane, and it says nothing
# about DNS, so a step that reaches a peer by name rather than by address can
# still fail on the line right after this action while the peer is perfectly
# connected. This runs last, after the exit node is selected, so it sees the
# network the way the rest of the job will.
#
# Does nothing unless 'dns-hostnames' names something.
set -euo pipefail

DNS_HOSTNAMES="${INPUT_DNS_HOSTNAMES:-}"
REQUIRE_PRIVATE="${INPUT_DNS_REQUIRE_PRIVATE:-true}"
TIMEOUT="${INPUT_TIMEOUT:-60}"

# Nothing asked for, so there is nothing to wait on. Checked before the inputs
# below are validated: a workflow that never sets 'dns-hostnames' should not be
# able to fail here at all.
if [ -z "${DNS_HOSTNAMES//[[:space:],]/}" ]; then
  exit 0
fi

case "$REQUIRE_PRIVATE" in
  true | false) ;;
  *)
    echo "::error::input 'dns-require-private' must be 'true' or 'false', got '$REQUIRE_PRIVATE'"
    exit 1
    ;;
esac

case "$TIMEOUT" in
  '' | *[!0-9]*)
    echo "::error::input 'timeout' must be a whole number of seconds, got '$TIMEOUT'"
    exit 1
    ;;
esac

if [ "$TIMEOUT" -lt 1 ]; then
  echo "::error::input 'timeout' must be at least 1 second, got '$TIMEOUT'"
  exit 1
fi

# Commas, spaces and newlines all separate, so the list reads the same written
# on one line or as a YAML block. Splitting with `read -a` on its own would stop
# at the first newline and go on to check only the names before it, which passes
# while proving less than it was asked to.
hosts=()
declare -A seen=()

read -r -a entries <<< "$(printf '%s' "$DNS_HOSTNAMES" | tr ',\n\t' '   ')"

for entry in "${entries[@]}"; do
  # A hostname and nothing else, so a URL, a 'host:port' or a stray quote is
  # refused by name here rather than waited on and reported as a name that
  # would not resolve.
  if ! [[ $entry =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
    echo "::error::input 'dns-hostnames' contains '$entry', which is not a hostname. Pass the name on its own, without a scheme, port or path."
    exit 1
  fi

  # A name asked for twice is still one thing to wait for.
  if [ -z "${seen[$entry]+set}" ]; then
    seen["$entry"]=1
    hosts+=("$entry")
  fi
done

# The NetBird range, plus RFC 1918.
is_private_ip() {
  local first second

  [[ $1 =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1

  # Base 10 explicitly, or an octet written as '010' is read as octal.
  first="$((10#${BASH_REMATCH[1]}))"
  second="$((10#${BASH_REMATCH[2]}))"

  [ "$first" -eq 10 ] && return 0
  [ "$first" -eq 100 ] && [ "$second" -ge 64 ] && [ "$second" -le 127 ] && return 0
  [ "$first" -eq 172 ] && [ "$second" -ge 16 ] && [ "$second" -le 31 ] && return 0
  [ "$first" -eq 192 ] && [ "$second" -eq 168 ] && return 0

  return 1
}

# getent goes through NSS, the same path curl and everything else on the runner
# takes, so this proves the thing a later step actually depends on. Querying a
# nameserver directly would prove less, and would need a dig that is not on
# every runner.
resolve_ipv4() {
  getent ahostsv4 "$1" 2> /dev/null | awk '{ print $1 }' | sort -u
}

echo '=== Waiting for DNS ==='

# systemd-resolved caches a miss for as long as the zone's SOA asks it to, so a
# name looked up before NetBird registered its domain can stay missing here long
# past the point where it would answer. Best effort: a runner need not be
# running resolved at all.
sudo resolvectl flush-caches > /dev/null 2>&1 || true

if [ "$REQUIRE_PRIVATE" = 'true' ]; then
  echo "waiting for ${hosts[*]} to resolve to a private address"
else
  echo "waiting for ${hosts[*]} to resolve"
fi

declare -A reason=()
pending=("${hosts[@]}")

# A deadline rather than a count of passes. A name that does not resolve holds
# getent for as long as the resolver takes to give up - seconds, not the
# instant a name that does resolve takes - so counting passes would let
# 'timeout' overrun by a multiple of itself on exactly the names it is there to
# bound. The condition is checked between passes, so a pass already under way
# always finishes and every name is tried at least once.
deadline=$((SECONDS + TIMEOUT))

while true; do
  still_pending=()

  for host in "${pending[@]}"; do
    mapfile -t ips < <(resolve_ipv4 "$host")

    if [ "${#ips[@]}" -eq 0 ]; then
      still_pending+=("$host")
      reason["$host"]='did not resolve'
      continue
    fi

    # Resolving is not enough on a split-horizon name. Public DNS can answer
    # first while NetBird's zone is still settling, and then the name points at
    # the far side of the network: the step after this one leaves the mesh to
    # reach it, and says nothing about having done so.
    if [ "$REQUIRE_PRIVATE" = 'true' ]; then
      public_ips=()

      for ip in "${ips[@]}"; do
        is_private_ip "$ip" || public_ips+=("$ip")
      done

      if [ "${#public_ips[@]}" -gt 0 ]; then
        still_pending+=("$host")
        reason["$host"]="resolved outside the network, to ${public_ips[*]}"
        continue
      fi
    fi

    echo "$host resolved to ${ips[*]}"
  done

  pending=("${still_pending[@]}")

  # Recorded rather than inferred from the clock below: a last pass that lands
  # exactly on the deadline succeeded, and reading the time again would call it
  # a timeout.
  if [ "${#pending[@]}" -eq 0 ]; then
    ready=1
    break
  fi

  if [ "$SECONDS" -ge "$deadline" ]; then
    break
  fi

  sleep 1
done

if [ -z "${ready:-}" ]; then
  details=()

  for host in "${pending[@]}"; do
    details+=("$host ${reason[$host]}")
  done

  # A GitHub annotation is one line, so the per-name detail is joined into it
  # rather than printed above it where it would be separated from the error.
  joined="$(printf '%s; ' "${details[@]}")"

  echo "::error::DNS was not ready within ${TIMEOUT}s: ${joined%; }. Check that NetBird DNS is on for this peer's group and that the name belongs to a NetBird zone. A name that is meant to answer with a public address needs 'dns-require-private: false'."
  sudo netbird status -d -A || true

  if command -v resolvectl > /dev/null; then
    resolvectl status || true
  fi

  exit 1
fi

echo 'DNS is ready'
