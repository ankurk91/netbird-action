#!/usr/bin/env bash
# Install the NetBird client and wait for its daemon to answer.
set -euo pipefail

VERSION="${INPUT_VERSION:-latest}"
GH_TOKEN="${INPUT_GITHUB_TOKEN:-}"
INSTALLER_DIR="${RUNNER_TEMP:-/tmp}/netbird-installer"

# Waiting on a local service to finish starting, not on anything across the
# network, so this is fixed rather than tied to the action's 'timeout' input.
DAEMON_TIMEOUT=30

if [ "${RUNNER_OS:-Linux}" != 'Linux' ]; then
  echo "::error::this action supports Linux runners only, this one is ${RUNNER_OS}"
  exit 1
fi

# Releases are tagged 'v0.78.1', but asking for the version as '0.78.1' is the
# more natural way to write it, so take either.
if [ "$VERSION" != 'latest' ]; then
  case "$VERSION" in
    v*) ;;
    *) VERSION="v${VERSION}" ;;
  esac

  if ! printf '%s' "$VERSION" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "::error::input 'version' must be 'latest' or a release such as '0.78.1', got '${INPUT_VERSION}'"
    exit 1
  fi
fi

echo "=== Installing the NetBird client (${VERSION}) ==="
if command -v netbird > /dev/null; then
  echo "already installed ($(netbird version)), skipping"

  # A runner that brings its own client keeps it, so say so plainly rather than
  # let a pinned 'version' look like it was honoured.
  if [ "$VERSION" != 'latest' ] && [ "v$(netbird version)" != "$VERSION" ]; then
    echo "::warning::this runner already has netbird $(netbird version), so ${VERSION} was not installed"
  fi
else
  mkdir -p "$INSTALLER_DIR"

  curl --fail --no-progress-meter --location \
    --connect-timeout 10 --max-time 60 --retry 2 \
    --output "$INSTALLER_DIR/install.sh" \
    https://pkgs.netbird.io/install.sh

  chmod 755 "$INSTALLER_DIR/install.sh"

  # Pass GITHUB_TOKEN only for pinned tags, not for 'latest'
  if [ "$VERSION" != 'latest' ] && [ -n "$GH_TOKEN" ]; then
    echo "::add-mask::$GH_TOKEN"
    export GITHUB_TOKEN="$GH_TOKEN"
  else
    unset GITHUB_TOKEN
  fi

  # Take the release binary rather than the apt package: it skips adding the
  # NetBird repository and the apt-get update that follows, and it covers the
  # arm64 runners on the same path. There is no desktop here to put a UI on.
  NETBIRD_RELEASE="$VERSION" USE_BIN_INSTALL=true SKIP_UI_APP=true "$INSTALLER_DIR/install.sh"
fi

netbird version

# The install registers the service and starts it, but the socket the CLI talks
# to appears a moment after the service does, so a connect that follows straight
# on can arrive before anything is listening.
echo '=== Waiting for the NetBird daemon ==='
for i in $(seq "$DAEMON_TIMEOUT"); do
  # Both "Daemon version" from a logged-in daemon and "Daemon status: NeedsLogin"
  # from a fresh one mean the same thing here: something is answering.
  if sudo netbird status 2>&1 | grep -q 'Daemon'; then
    daemon_ready=1
    break
  fi

  # A binary install leaves the service registered but not always running.
  if [ "$i" -eq 1 ]; then
    sudo netbird service start > /dev/null 2>&1 || true
  fi

  sleep 1
done

if [ -z "${daemon_ready:-}" ]; then
  echo "::error::the NetBird daemon did not come up within ${DAEMON_TIMEOUT}s"
  sudo netbird service status || true
  exit 1
fi

echo 'the daemon is up'
