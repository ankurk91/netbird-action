# Setup NetBird

<p align="center">
  <img src="https://raw.githubusercontent.com/ankurk91/netbird-action/main/.github/banner.jpg?v=2"
    alt="Setup NetBird - connect your GitHub Actions CI runners to your NetBird network" width="640">
</p>

[![tests](https://github.com/ankurk91/netbird-action/actions/workflows/tests.yaml/badge.svg)](https://github.com/ankurk91/netbird-action/actions)
[![lint](https://github.com/ankurk91/netbird-action/actions/workflows/lint.yaml/badge.svg)](https://github.com/ankurk91/netbird-action/actions)
[![marketplace](https://img.shields.io/badge/marketplace-setup--netbird-blue?logo=github)](https://github.com/marketplace/actions/setup-netbird)
[![runner](https://img.shields.io/badge/runner-Linux%20only-blue?logo=linux&logoColor=white)](#requirements)

A GitHub Action that installs the [NetBird](https://netbird.io) client on an Ubuntu runner and joins your network with a
setup key, so the rest of the job can reach your private peers. It can also route the runner's traffic through an exit
node.

## Setup

1. In the NetBird dashboard, open Settings-> **Setup Keys** and create one for your runners:

- **One-off** if a single job uses it, **reusable** otherwise.
- Turn on **Ephemeral**. The action deregisters the peer automatically, but this is a good backstop.
- Set a proper expiry
- Give it a group your access policies already allow, so the runner can reach what it needs.

2. Add the key as a repository secret named `NETBIRD_SETUP_KEY`.

> [!WARNING]
> Never commit the setup key or pass it as a plain string — anyone holding it can register a peer on your network.

## Usage

The only input you need is `setup-key`. Everything else below is optional and shown at its default, apart from
`exit-node` and `dns-hostnames`, which do nothing until you set them:

```yaml
name: Testing

on:
  workflow_dispatch:

jobs:
  test:
    runs-on: ubuntu-latest

    steps:
      - name: Connect to the NetBird network
        id: netbird
        uses: ankurk91/netbird-action@v1
        with:
          setup-key: ${{ secrets.NETBIRD_SETUP_KEY }}
          # Point this at your own deployment when you self-host.
          management-url: https://api.netbird.io:443
          # Peer name in the dashboard. Every leg of a matrix shares one run id,
          # so give those a name of their own.
          hostname: gh-${{ github.run_id }}-${{ github.run_attempt }}
          # Network ID of the route to send traffic through. Off when empty.
          exit-node: ${{ vars.NETBIRD_EXIT_NODE_ID }}
          # Names that must resolve before this step finishes. Off when empty.
          dns-hostnames: ''
          # Only accept an address inside the network, see the section below.
          dns-require-private: true
          # Appended to `netbird up`, split on whitespace.
          args: ''
          # Client release to install. Pin it to keep runs reproducible.
          version: latest
          # Budget for each wait: the peer, the exit node route, and the DNS names.
          timeout: 60
          diagnostics: false

      # From here the runner is a peer and can reach the others.
      - name: Do work on the private network
        run: |
          echo "this runner is ${{ steps.netbird.outputs.netbird-ip }} on the network"
          curl -s http://internal-service.netbird.cloud
```

There is no disconnect step to add — see [Cleanup](#cleanup).

> [!WARNING]
> An exit node carries `0.0.0.0/0`, so the runner's connection to GitHub goes through it too. If the exit node cannot
> reach GitHub, the job hangs after this step rather than failing.

## Inputs

| Input                 | Required | Default                      | Description                                                                                  |
|-----------------------|----------|------------------------------|----------------------------------------------------------------------------------------------|
| `setup-key`           | **yes**  | —                            | Setup key from the dashboard. Always pass this from a secret.                                |
| `management-url`      | no       | `https://api.netbird.io:443` | Management service URL. Set this when you self-host NetBird.                                 |
| `hostname`            | no       | `gh-<run id>-<run attempt>`  | Peer name shown in the dashboard.                                                            |
| `exit-node`           | no       | —                            | Network ID to route through. The route must be distributed to this peer's group.             |
| `dns-hostnames`       | no       | —                            | Names that must resolve before the action finishes. See [Waiting for DNS](#waiting-for-dns). |
| `dns-require-private` | no       | `true`                       | Only accept a `dns-hostnames` name once every address it resolves to is private.             |
| `args`                | no       | —                            | Extra flags appended to `netbird up`, split on whitespace.                                   |
| `version`             | no       | `latest`                     | Client release to install. See [Client version](#client-version).                            |
| `github-token`        | no       | `${{ github.token }}`        | Raises the API rate limit when `version` is pinned. Only sent then.                          |
| `timeout`             | no       | `60`                         | Seconds allowed for each wait: the peer, the exit node route, the `dns-hostnames` names.     |
| `diagnostics`         | no       | `false`                      | Print the peer state to the job log. See [Diagnostics](#diagnostics).                        |

## Outputs

| Output       | Description                                                               |
|--------------|---------------------------------------------------------------------------|
| `netbird-ip` | The runner's IPv4 address inside the NetBird network, e.g. `100.64.0.33`. |

This is the address the runner holds *on the overlay network* — what other peers use to reach it. It is not the runner's
public IP, and it does not change when an exit node is selected: an exit node changes where the runner's outbound
traffic leaves from, not the address it answers on.

## Waiting for DNS

The action always waits for the peer itself: management and signal connected, and a relay available when the network has
one. That is the control plane, and it says nothing about DNS. A job whose next step reaches a peer *by name* rather
than by address can still fail on the line right after this action, while the peer is perfectly connected.

`dns-hostnames` closes that gap. Give it the names the job actually depends on and the action will not finish until they
resolve:

```yaml
- uses: ankurk91/netbird-action@v1
  with:
    setup-key: ${{ secrets.NETBIRD_SETUP_KEY }}
    dns-hostnames: postgres.netbird.cloud, internal-service.netbird.cloud
```

Commas, spaces and newlines all separate, so a longer list can be written as a block:

```yaml
    dns-hostnames: |
      internal-service.netbird.cloud
      postgres.netbird.cloud
```

Hostnames only — a scheme, a port or a path is refused outright rather than waited on and reported later as a name that
would not resolve.

Names are resolved with `getent`, which goes through the same resolver path `curl` and everything else on the runner
takes — so a pass means the runner can really resolve the name, not just that NetBird reports a nameserver.

### Why the address has to be private

Resolving is not enough on a split-horizon name — one that exists in public DNS *and* in a NetBird zone. Public DNS can
answer first while NetBird's zone is still settling, and then the name resolves to the far side of the network: the step
after this one leaves the mesh to reach it and says nothing about having done so, which usually surfaces later as a
confusing `403` from an API that was supposed to be internal.

So `dns-require-private` is on by default, and a name only counts as ready once **every** address it resolves to is
inside the NetBird range (`100.64.0.0/10`) or RFC 1918 (`10/8`, `172.16/12`, `192.168/16`). Until then the action keeps
waiting, and on timeout it says which name answered with which public address.

Turn it off for a name that is *meant* to answer with a public address — one reached through an
[exit node](#usage), typically:

```yaml
    dns-hostnames: api.example.com
    dns-require-private: false
```

Each name gets up to `timeout` seconds. A name that never resolves is more often a configuration problem than a slow
one: check that NetBird DNS is enabled for this peer's group, and that the name really belongs to a zone the peer is
given.

## Cleanup

When the job ends the action logs out of NetBird, on a failed job as much as a passing one. The peer leaves your
dashboard and the runner is off your network again, so there is nothing to add to your workflow.

## Requirements

An Ubuntu runner (`ubuntu-latest`, `ubuntu-24.04`, `ubuntu-26.04`, their `-arm` variants, or self-hosted Ubuntu). The
runner needs passwordless `sudo`, which GitHub-hosted runners have — the client runs as a system service, and the
post-job [cleanup](#cleanup) needs it too.

NetBird client **0.67.0 or newer**. See [Client version](#client-version).

## Client version

`version` takes `0.78.1` or `v0.78.1`, and installs the newest release when left at `latest`. Pin it when you want every
run to install the same client, or to hold back a release that broke something for you. It has to be **0.67.0 or
newer**, because the action's waits use `netbird status --check`, which NetBird added in that release.

If the runner already carries a NetBird client, that one is kept: the action warns and does not replace it.

Pinning also changes where the version is looked up. `latest` reads NetBird's own CDN, while a pinned tag is resolved
through `api.github.com`, which allows 60 unauthenticated requests an hour per IP address. Hosted runners share egress
addresses, so a busy account can reach that limit and watch installs start failing.

So the action sends `github-token` when, and only when, you pin a version, which lifts the limit to 1000 requests an
hour for the repository. It defaults to the workflow's own `GITHUB_TOKEN` and needs no setup. The `latest` path gains
nothing from a token, so it never sees one.

## Diagnostics

With `diagnostics: true` the action prints the NetBird IP, `netbird status -d`, the networks the peer holds, the routing
table, and the runner's public IP before and after connecting.

It is off by default because that output describes your private network: every peer the runner can see, their addresses
and hostnames, every route distributed to it. Job logs are visible to more people than the dashboard is. Turn it on
while working out why a connection fails, then turn it back off.

Failures print `netbird status -d` with NetBird's own anonymizer on, so a broken run is still diagnosable without
diagnostics turned on.

## Troubleshooting

See [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## License

[MIT](LICENSE.txt)
