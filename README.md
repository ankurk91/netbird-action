# NetBird Action

[![tests](https://github.com/ankurk91/netbird-action/actions/workflows/tests.yaml/badge.svg)](https://github.com/ankurk91/netbird-action/actions)
[![lint](https://github.com/ankurk91/netbird-action/actions/workflows/lint.yaml/badge.svg)](https://github.com/ankurk91/netbird-action/actions)

A GitHub Action that installs the [NetBird](https://netbird.io) client on an Ubuntu runner and joins your network with a
setup key, so the rest of the job can reach your private peers. It can also route the runner's traffic through an exit
node.

## Setup

1. In the NetBird dashboard, open Settings-> **Setup Keys** and create one for your runners:

- **One-off** if a single job uses it, **reusable** otherwise.
- Turn on **Ephemeral** so the peer is removed automatically once the job ends. Without it every run leaves a dead peer
  behind.
- Set a proper expiry
- Give it a group your access policies already allow, so the runner can reach what it needs.

2. Add the key as a repository secret named `NETBIRD_SETUP_KEY`.

> [!WARNING]
> Never commit the setup key or pass it as a plain string — anyone holding it can register a peer on your network.

## Usage

The only input you need is `setup-key`. Everything else below is optional and shown at its default, apart from
`exit-node`, which does nothing until you set it:

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
          # Appended to `netbird up`, split on whitespace.
          args: ''
          # Client release to install. Pin it to keep runs reproducible.
          version: latest
          # Seconds to wait for the peer to connect, and for the exit node route.
          timeout: 60
          diagnostics: false

      # From here the runner is a peer and can reach the others.
      - name: Do work on the private network
        run: |
          echo "this runner is ${{ steps.netbird.outputs.netbird-ip }} on the network"
          curl -s http://internal-service.netbird.cloud
```

There is no disconnect step to add. With an ephemeral setup key the peer disappears on its own once the runner is gone.

> [!WARNING]
> An exit node carries `0.0.0.0/0`, so the runner's connection to GitHub goes through it too. If the exit node cannot
> reach GitHub, the job hangs after this step rather than failing.

## Inputs

| Input            | Required | Default                      | Description                                                                       |
|------------------|----------|------------------------------|-----------------------------------------------------------------------------------|
| `setup-key`      | **yes**  | —                            | Setup key from the dashboard. Always pass this from a secret.                     |
| `management-url` | no       | `https://api.netbird.io:443` | Management service URL. Set this when you self-host NetBird.                      |
| `hostname`       | no       | `gh-<run id>-<run attempt>`  | Peer name shown in the dashboard.                                                 |
| `exit-node`      | no       | —                            | Network ID to route through. The route must be distributed to this peer's group.  |
| `args`           | no       | —                            | Extra flags appended to `netbird up`, split on whitespace.                        |
| `version`        | no       | `latest`                     | Client release to install. See [Client version](#client-version).                 |
| `github-token`   | no       | `${{ github.token }}`        | Raises the API rate limit when `version` is pinned. Only sent then.               |
| `timeout`        | no       | `60`                         | Seconds to wait for the peer to connect, and for the exit node route to reach it. |
| `diagnostics`    | no       | `false`                      | Print the peer state to the job log. See [Diagnostics](#diagnostics).             |

## Outputs

| Output       | Description                                                               |
|--------------|---------------------------------------------------------------------------|
| `netbird-ip` | The runner's IPv4 address inside the NetBird network, e.g. `100.64.0.33`. |

This is the address the runner holds *on the overlay network* — what other peers use to reach it. It is not the runner's
public IP, and it does not change when an exit node is selected: an exit node changes where the runner's outbound
traffic leaves from, not the address it answers on.

## Requirements

An Ubuntu runner (`ubuntu-latest`, `ubuntu-24.04`, `ubuntu-26.04`, their `-arm` variants, or self-hosted Ubuntu). The
runner needs passwordless `sudo`, which GitHub-hosted runners have — the client runs as a system service.

## Client version

`version` takes `0.78.1` or `v0.78.1`, and installs the newest release when left at `latest`. Pin it when you want
every run to install the same client, or to hold back a release that broke something for you.

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
