#!/bin/zsh
# Pair a browser on this Mac (or show the code for an iPhone/iPad) with no email and no Cloudflare sign-in.
# The Mac's own Access service token (Gallery's token.json) mints a one-time code; the device address
# opens with the code filled in, and one tap on Pair finishes it. The token is sent, never printed.
# Usage: zsh chau/pair-this-mac.zsh          opens the pair page in the default browser
#        zsh chau/pair-this-mac.zsh --print  prints the address and code only (for another device)
set -eu
main="${GALLERY_MAIN:-https://gallery.improvdiplomat.workers.dev}"
device="${GALLERY_DEVICE:-https://gallery-device.improvdiplomat.workers.dev}"
tok="${GALLERY_TOKEN_FILE:-$HOME/Library/Group Containers/48RZ72DNP3.gallery/token.json}"
[ -r "$tok" ] || { echo "No token file at: $tok" >&2; exit 1; }

id="$(plutil -extract id raw -o - "$tok")"
secret="$(plutil -extract secret raw -o - "$tok")"
reply="$(curl -sS -m 20 -X POST "$main/main/api/pair" -H "x-gallery: 1" \
  -H "CF-Access-Client-Id: $id" -H "CF-Access-Client-Secret: $secret")"
code="$(printf %s "$reply" | plutil -extract code raw -o - - 2>/dev/null || true)"
[[ "$code" =~ '^[0-9]{6}$' ]] || { echo "The Worker did not give a code (token rejected or pairing off)." >&2; exit 1; }

echo "Pair code: $code (valid 5 minutes)"
echo "Open: $device/pair?code=$code"
[ "${1:-}" = "--print" ] || open "$device/pair?code=$code"
