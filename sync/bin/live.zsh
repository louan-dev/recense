#!/bin/zsh
# Derived from Spec: FEAT-39. Glue only: the logic is sync/src/livestate.mjs.
#   zsh live.zsh watch              the launchd job: keeps ~/Recense/live/live.json current (FSEvents, 5 s after the last save, no polling)
#   zsh live.zsh manifest           write the manifest once
#   zsh live.zsh snapshot [NAME]    review snapshot of a worktree (default: this one) → inbox/live/*.patch + a note posted to the coordinator inbox
#   zsh live.zsh built              run in a worktree after its cheapest check passed: marks its files BUILT
# Off switch: launchctl bootout gui/$(id -u)/com.chauphan.live
set -u
HERE=${0:A:h}
NODE=${LIVE_NODE:-}
if [[ -z $NODE || ! -x $NODE ]]; then
  NODE=
  for c in /opt/homebrew/bin/node /usr/local/bin/node $(command -v node 2>/dev/null) $HOME/.nvm/versions/node/*/bin/node(N); do [[ -x $c ]] && { NODE=$c; break; }; done
fi
[[ -x $NODE ]] || { print -u2 "live: no node found (set LIVE_NODE)"; exit 69; }
exec $NODE $HERE/../src/livestate.mjs "${@:-watch}"
