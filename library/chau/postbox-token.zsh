#!/bin/zsh
# Derived from the owner's Postbox request (2026-11-16). Make or replace one account's Postbox token.
# Usage: zsh chau/postbox-token.zsh <name>        e.g. web-icloud, web-gmail4, cli-mac
# Prints the token ONCE (paste it into that Claude account's environment); keeps only its SHA-256 in
# ~/.config/recense/postbox-tokens.json (0600), then sets the worker secret POSTBOX_TOKENS from that file.
set -eu
name="${1:?usage: postbox-token.zsh <name>}"
f="$HOME/.config/recense/postbox-tokens.json"
mkdir -p "${f:h}"; [ -f "$f" ] || { echo '{}' > "$f"; chmod 600 "$f"; }
tok="$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=')"
hash="$(printf %s "$tok" | shasum -a 256 | cut -d' ' -f1)"
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
NAME="$name" HASH="$hash" node -e 'const f=process.argv[1];const j=JSON.parse(require("fs").readFileSync(f,"utf8"));j[process.env.NAME]=process.env.HASH;process.stdout.write(JSON.stringify(j))' "$f" > "$tmp"
cp "$tmp" "$f"
(cd "${0:A:h}/.." && npx wrangler secret put POSTBOX_TOKENS < "$f")
echo "token for $name (shown once): $tok"
