// Runs the install and connect scripts in order.
//
// This action is a JavaScript action for one reason only: a composite action
// cannot declare a `post` entry point, and the runner has to tear the peer down
// when the job ends rather than when this step does. Everything of substance
// stays in the shell scripts next to this file.

import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import process from 'node:process';

// The runner hands a JavaScript action its inputs as INPUT_<NAME> with the
// hyphens left in, which no shell will export. The scripts read the underscored
// names, so the mapping happens here rather than in every script.
const INPUTS = [
  'setup-key',
  'management-url',
  'peer-name',
  'exit-node',
  'dns-hostnames',
  'dns-require-private',
  'args',
  'timeout',
  'diagnostics',
  'version',
  'github-token',
];

const env = { ...process.env };

for (const name of INPUTS) {
  const key = `INPUT_${name.toUpperCase()}`;
  env[key.replaceAll('-', '_')] = process.env[key] ?? '';
}

for (const script of ['install.sh', 'connect.sh', 'dns-check.sh']) {
  const { status, error } = spawnSync('bash', [join(import.meta.dirname, script)], {
    stdio: 'inherit',
    env,
  });

  if (error) {
    console.log(`::error::cannot run ${script}: ${error.message}`);
    process.exit(1);
  }

  // A script killed by a signal reports no status, and letting that read as
  // success would send the job on to steps that need a peer.
  if (status !== 0) {
    process.exit(status ?? 1);
  }
}
