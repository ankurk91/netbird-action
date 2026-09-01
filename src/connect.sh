#!/usr/bin/env bash
# Register the runner as a peer and put it on the network.
set -euo pipefail

SETUP_KEY="${INPUT_SETUP_KEY:-}"
MANAGEMENT_URL="${INPUT_MANAGEMENT_URL:-https://api.netbird.io:443}"
PEER_HOSTNAME="${INPUT_HOSTNAME:-}"
EXIT_NODE="${INPUT_EXIT_NODE:-}"
EXTRA_ARGS="${INPUT_ARGS:-}"
TIMEOUT="${INPUT_TIMEOUT:-60}"
DIAGNOSTICS="${INPUT_DIAGNOSTICS:-false}"

if [ -z "$SETUP_KEY" ]; then
  echo "::error::input 'setup-key' is empty"
  exit 1
fi

# A key passed from `vars` instead of `secrets` reaches the log unmasked
# otherwise, and every failure path below prints diagnostics.
echo "::add-mask::$SETUP_KEY"

case "$DIAGNOSTICS" in
  true | false) ;;
  *)
    echo "::error::input 'diagnostics' must be 'true' or 'false', got '$DIAGNOSTICS'"
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

public_ip() {
  curl -4 -s --connect-timeout 5 --max-time 10 https://api.ipify.org || echo 'unavailable'
}

# The action fills this in from the run it belongs to, so it is only ever empty
# when someone passes an empty string deliberately - which means the client
# falls back to the runner's own hostname.
if [ -n "$PEER_HOSTNAME" ] &&
  ! [[ $PEER_HOSTNAME =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
  echo "::error::input 'hostname' is not a valid hostname: '$PEER_HOSTNAME'. Use letters, digits and hyphens, up to 63 characters, not starting or ending with a hyphen."
  exit 1
fi

if [ "$DIAGNOSTICS" = 'true' ]; then
  ip_before_netbird="$(public_ip)"
fi

# Passing the key as --setup-key would leave it in the process list, where any
# other job on a shared self-hosted runner can read it.
key_file="$(mktemp "${RUNNER_TEMP:-/tmp}/netbird-setup-key.XXXXXX")"
trap 'rm -f "$key_file"' EXIT

printf '%s' "$SETUP_KEY" > "$key_file"

up_args=(--setup-key-file "$key_file" --management-url "$MANAGEMENT_URL")

if [ -n "$PEER_HOSTNAME" ]; then
  up_args+=(--hostname "$PEER_HOSTNAME")
fi

# Whitespace is the only separator here, so an argument cannot contain one.
read -r -a extra_args <<< "$EXTRA_ARGS"
up_args+=("${extra_args[@]}")

echo "=== Connecting as '${PEER_HOSTNAME:-$(hostname)}' ==="
sudo netbird up "${up_args[@]}"

rm -f "$key_file"
trap - EXIT

# `netbird up` returns once the daemon has accepted the login, which is earlier
# than the peer being able to carry traffic: the signal connection and the
# network map both follow. Waiting here keeps a later step from failing on a
# peer that was merely registered.
echo '=== Waiting for the peer to connect ==='
for _ in $(seq "$TIMEOUT"); do
  status="$(sudo netbird status 2>&1 || true)"

  if printf '%s' "$status" | grep -q 'Management: Connected' &&
    printf '%s' "$status" | grep -q 'Signal: Connected'; then
    connected=1
    break
  fi

  sleep 1
done

if [ -z "${connected:-}" ]; then
  echo "::error::the peer did not reach the network within ${TIMEOUT}s. Check the setup key has not expired or hit its usage limit, and that the management URL is right."
  sudo netbird status -d -A || true
  exit 1
fi

echo 'peer connected'

if [ -n "$EXIT_NODE" ]; then
  echo "=== Selecting the exit node '$EXIT_NODE' ==="

  # The route only exists on this peer once the management service has pushed a
  # network map naming it, which lands after the login the loop above waited on.
  for _ in $(seq "$TIMEOUT"); do
    if sudo netbird routes ls | grep -qF "$EXIT_NODE"; then
      route_available=1
      break
    fi

    sleep 1
  done

  if [ -z "${route_available:-}" ]; then
    echo "::error::exit node '$EXIT_NODE' was never distributed to this peer. Check the network ID, and that the route's distribution groups cover the group the setup key assigns."
    sudo netbird routes ls || true
    sudo netbird status -d -A || true
    exit 1
  fi

  # Replaces the current selection, so from here the runner's traffic for that
  # network - the whole internet, for an exit node - goes through it.
  sudo netbird routes select "$EXIT_NODE"
  echo 'exit node selected'
fi

# The peer's own address on the overlay network, which is what a later step
# needs to tell other peers where to reach this runner.
netbird_ip="$(sudo netbird status -4 2> /dev/null || true)"
netbird_ip="${netbird_ip%%/*}"
echo "netbird-ip=${netbird_ip}" >> "$GITHUB_OUTPUT"

# Everything below describes the network the runner just joined: the other peers
# and their addresses, every route the peer holds, where its traffic now leaves
# from. A job log is readable by more people than the dashboard is, so it is
# printed only when asked for.
if [ "$DIAGNOSTICS" = 'true' ]; then
  echo
  echo '=== NetBird IP ==='
  echo "$netbird_ip"

  echo
  echo '=== NetBird status ==='
  sudo netbird status -d

  echo
  echo '=== Networks ==='
  sudo netbird routes ls

  echo
  echo '=== Routes ==='
  ip route

  echo
  echo "Public IP before NetBird: $ip_before_netbird"
  echo "Public IP after NetBird: $(public_ip)"
fi
