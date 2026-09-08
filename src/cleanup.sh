#!/usr/bin/env bash
# Hand the runner back the way it was found, once the job is over.
#
# A hosted runner is destroyed after the job, so none of this matters there. A
# self-hosted one is not: without this the daemon stays connected, the routes and
# DNS stay up, an exit node keeps carrying the runner's traffic and the peer's
# key stays on disk - and the next job on that machine, from any workflow in any
# repository, inherits a network it never asked to join.
#
# Every step here is best effort. The work of the job is already done by the time
# this runs, so a cleanup that cannot finish is a warning, never a failure: no
# 'set -e', and each command carries its own '|| true'.
set -uo pipefail

CONNECTED="${STATE_NB_CONNECTED:-false}"
EXIT_NODE="${STATE_NB_EXIT_NODE:-}"
INSTALLED="${STATE_NB_INSTALLED:-false}"
SERVICE_STARTED="${STATE_NB_SERVICE_STARTED:-false}"
WAS_LOGGED_IN="${STATE_NB_WAS_LOGGED_IN:-false}"

# The end-to-end job runs this script itself so it can check what it did, and the
# post step then runs it again. Rather than have the second pass warn its way
# through commands that cannot work twice, it stops here.
MARKER="${RUNNER_TEMP:-/tmp}/netbird-action-cleaned"

if [ -e "$MARKER" ]; then
  echo 'the runner was already cleaned up, nothing to do'
  exit 0
fi

if ! command -v netbird > /dev/null; then
  echo 'no NetBird client on this runner, nothing to do'
  exit 0
fi

# Nothing was recorded, so the install never got far enough to change anything -
# a setup key that was rejected, say.
if [ "$CONNECTED" != 'true' ] && [ "$INSTALLED" != 'true' ] && [ "$SERVICE_STARTED" != 'true' ]; then
  echo 'the action did not connect or install anything, nothing to do'
  exit 0
fi

echo '=== Cleaning up ==='
touch "$MARKER" 2> /dev/null || true

done_steps=()

if [ -n "$EXIT_NODE" ]; then
  if sudo netbird routes deselect "$EXIT_NODE" > /dev/null 2>&1; then
    done_steps+=("deselected the exit node '$EXIT_NODE'")
  else
    echo "::warning::could not deselect the exit node '$EXIT_NODE'"
  fi
fi

if [ "$CONNECTED" = 'true' ]; then
  # connect.sh records the login before attempting it, so a peer that never came
  # up reaches this point too. Deregistering that one fails, and rightly - which
  # is worth a warning only when there was a live peer here to remove.
  if sudo netbird status --check startup > /dev/null 2>&1; then
    peer_was_up=1
  fi

  # 'logout' is an alias for 'deregister': it removes the peer from the
  # management service and drops the credentials it was holding, so the peer
  # leaves the dashboard now instead of after the ephemeral timeout. It reaches
  # the management service through the daemon, so it has to happen while both are
  # still up - before the 'down' and the service stop below.
  if sudo netbird logout > /dev/null 2>&1; then
    done_steps+=('deregistered the peer')
  elif [ -n "${peer_was_up:-}" ]; then
    echo '::warning::could not deregister the peer, so it may still be registered with the management service. An ephemeral setup key removes it once it has been offline for 10 minutes; a key that is not ephemeral leaves it in the dashboard to delete by hand.'
  fi

  if sudo netbird down > /dev/null 2>&1; then
    done_steps+=('disconnected from the network')
  fi
fi

if [ "$INSTALLED" = 'true' ]; then
  # The action put this client here, so it takes the whole thing back out. The
  # binary is left alone on purpose: it holds nothing secret, and a self-hosted
  # runner would otherwise download it again on every job.
  sudo netbird service stop > /dev/null 2>&1 || true

  if sudo netbird service uninstall > /dev/null 2>&1; then
    done_steps+=('uninstalled the service')
  else
    echo '::warning::could not uninstall the NetBird service'
  fi

  # Whatever the deregister above did not take with it. The private key lives in
  # here, so this is the part that matters most on a runner that keeps its disk.
  # /etc/netbird is where older clients kept the same thing.
  if sudo rm -rf /var/lib/netbird /etc/netbird > /dev/null 2>&1; then
    done_steps+=('removed the client configuration')
  else
    echo '::warning::could not remove /var/lib/netbird, which holds the peer key'
  fi
elif [ "$SERVICE_STARTED" = 'true' ]; then
  # The client was already here and its service was not running until the action
  # started it, so stopping it is what puts the runner back.
  if sudo netbird service stop > /dev/null 2>&1; then
    done_steps+=('stopped the service the action started')
  else
    echo '::warning::could not stop the NetBird service'
  fi
fi

# Said at the end rather than in passing, because it is the one thing here the
# action cannot put right by itself.
if [ "$WAS_LOGGED_IN" = 'true' ]; then
  echo '::warning::this runner was already logged in to a NetBird network before the action ran. That session was replaced by the one the action created, and has now been ended - the runner is no longer on its original network. Log it back in, or keep this action off runners that manage their own NetBird client.'
fi

if [ "${#done_steps[@]}" -eq 0 ]; then
  echo 'nothing could be cleaned up, see the warnings above'
else
  for step in "${done_steps[@]}"; do
    echo "$step"
  done
fi
