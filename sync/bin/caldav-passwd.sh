#!/bin/zsh
# caldav-passwd.sh: make a new CalDAV app password, store only its sha256 as the Worker secret, show it once.
# Run it in your own Terminal. Re-running replaces the password on every device (that's how you revoke).
set -eu
PASS=$(LC_ALL=C tr -dc 'a-km-np-z2-9' </dev/urandom | head -c 20 | sed -E 's/(.{5})/\1-/g; s/-$//')
printf %s "$PASS" | shasum -a 256 | cut -d' ' -f1 | (cd ${0:A:h}/../../calendar && npx --prefix ${0:A:h}/../../library wrangler secret put CALDAV_PASS_HASH >/dev/null)
print -P "\n%BCalDAV account%b\n  Server:   sync.improvdiplomat.workers.dev\n  User:     chau\n  Password: $PASS\n\nAdd it on the Mac and iPhone now, then clear this window (cmd-K). It is not stored anywhere else."
