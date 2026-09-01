# Troubleshooting

Most of these are quicker to diagnose with the action's diagnostics turned on, which prints the NetBird IP,
`netbird status -d`, the networks the peer holds, the routes and the public IP before and after connecting:

```yaml
- uses: ankurk91/netbird-action@v1
  with:
    setup-key: ${{ secrets.NETBIRD_SETUP_KEY }}
    diagnostics: true
```

It is off by default — see [Diagnostics](README.md#diagnostics) — so turn it back off once the connection works.

## The peer did not reach the network within 60s

The client registered with the management service but never came up as connected. In order of likelihood:

- **The setup key expired or hit its usage limit.** Check it under **Setup Keys** in the dashboard; a one-off key is
  spent after a single peer and a reusable one has a peer count. Rotate it and update the secret.
- **The key is for a different management service.** A self-hosted deployment needs its `management-url` passed too.
- **The management or signal service is unreachable from the runner.** Self-hosted only — a GitHub-hosted runner has to
  be able to reach both over the public internet.

## Exit node was never distributed to this peer

The route exists, but not for this peer. The `exit-node` value has to be the network ID as the dashboard and
`netbird routes ls` show it, and the route's **distribution groups** have to include a group the setup key assigns to
the peer. A key that puts runners in their own group needs that group added to the route.

Turn on `diagnostics` and read the `=== Networks ===` section to see which networks did arrive.

## The job hangs after connecting

An exit node routes all of the runner's traffic, including its connection to GitHub. If the exit node cannot reach
GitHub the runner stops reporting and the job sits until it times out. Drop `exit-node` to confirm that is the cause.

## Reaching a peer by name does not work

NetBird publishes peers under `.netbird.cloud` through its own nameserver. Check the `Nameservers` line in
`netbird status` — if it reports none available, the nameserver group in the dashboard does not cover this peer's group.
Its NetBird IP works either way.

## Peers pile up in the dashboard

Every run registers a new peer, and one that is not ephemeral stays after the runner is destroyed. Turn on **Ephemeral**
for the setup key so peers are removed once they stop talking to the management service.

## The NetBird daemon did not come up

The client installed but its service never started. Almost always a self-hosted runner without systemd — a container,
typically. The client runs as a system service and needs an init system to run under.

## Permission denied running the client

The runner has no passwordless `sudo`. The client is a system service and every command the action runs goes through
`sudo`. GitHub-hosted runners are fine; a self-hosted one needs its runner user allowed.
