// The job is over: hand back whatever the action took from the runner.
//
// The state the cleanup needs arrives as STATE_NB_* variables, written to
// $GITHUB_STATE by the install and connect scripts, so there is nothing to pass
// on here - the child inherits them.

import { spawnSync } from 'node:child_process';
import { join } from 'node:path';

const { status, error } = spawnSync('bash', [join(import.meta.dirname, 'cleanup.sh')], {
  stdio: 'inherit',
});

// Cleanup is best effort by design. A job that did its work and then failed to
// tidy up is a warning, not a failure, and the script says what went wrong - so
// this exits 0 either way.
if (error) {
  console.log(`::warning::cannot run cleanup.sh: ${error.message}`);
} else if (status !== 0) {
  console.log(`::warning::the cleanup exited with ${status ?? 'a signal'}`);
}
