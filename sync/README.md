# sync

Read-only iCloud ledger, canary round-trip and the plan for the Sync backend (Cloudflare R2). Private repo.
The plan of record is `PROGRESS.md`; agent rules are in `CLAUDE.md`.

## Run

    npm test                          # both selftests
    node src/ledger.mjs <command>     # run|watch|fold|verify|restore|health|audit|backup-status|quota|selftest
    node src/canary.mjs start|check

## Layout

- `src/` code, `bin/` launchd job, `tools/` Swift probes
- `docs/specs` what we are building, `docs/research` reports, `docs/runbooks` step-by-step,
  `docs/proposals` decisions waiting on the owner, `docs/archive` raw transcripts
- `requests/` inbox: files the owner uploads because a task asked for them (contents are git-ignored)

## launchd

    sed "s#__HOME__#$HOME#g" launchd/com.chauphan.ledger.obsidian.plist.example \
      > ~/Library/LaunchAgents/com.chauphan.ledger.obsidian.plist
