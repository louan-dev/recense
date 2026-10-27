#!/bin/zsh
# One-time setup on the Mac. Asks for the keys made in the Cloudflare dashboard, without
# showing them, and stores them where Gallery's tools look:
#   - rclone remotes gallery-public, gallery-main, and gallery (both together, for the mount)
#   - the Access service token, in the Keychain, for copy-share-link.sh
#   - a copy of copy-share-link.sh in ~/Library/Application Support/Gallery, so the Finder Quick Action
#     never depends on where this project folder is
#
#   zsh chau/setup.sh
set -e

here="${0:A:h}"
rclone=/opt/homebrew/bin/rclone
[[ -x "$rclone" ]] || rclone="$(command -v rclone || true)"
[[ -x "$rclone" ]] || { print "rclone isn't installed. Run: brew install rclone" >&2; exit 1; }
[[ -f "$here/copy-share-link.sh" ]] || { print "copy-share-link.sh must sit next to setup.sh ($here)." >&2; exit 1; }
account=7a7972b724b508c99a42844632b8a44c
endpoint="https://$account.r2.cloudflarestorage.com"
conf="$("$rclone" config file | tail -1)"

ask() {
  local prompt="$1" var="$2" value
  print -n "$prompt: "
  read -rs value
  print
  [[ -n "$value" ]] || { print "Nothing entered; stopping." >&2; exit 1; }
  typeset -g "$var=$value"
}

print "R2 token gallery-main-chau"
ask "  Access Key ID" main_id
ask "  Secret Access Key" main_secret
print "R2 token gallery-public-chau"
ask "  Access Key ID" public_id
ask "  Secret Access Key" public_secret
print "Access service token gallery-chau"
ask "  Client ID" client_id
ask "  Client Secret" client_secret

# replace any earlier copies of these remotes, then append them to the config (readable only by you)
for r in gallery gallery-main gallery-public; do "$rclone" config delete "$r" 2>/dev/null || true; done

mkdir -p "${conf:h}"
touch "$conf"
chmod 600 "$conf"

{
  print -r -- ""
  print -r -- "[gallery-public]"
  print -r -- "type = s3"
  print -r -- "provider = Cloudflare"
  print -r -- "access_key_id = $public_id"
  print -r -- "secret_access_key = $public_secret"
  print -r -- "endpoint = $endpoint"
  print -r -- "no_check_bucket = true"
  print -r -- ""
  print -r -- "[gallery-main]"
  print -r -- "type = s3"
  print -r -- "provider = Cloudflare"
  print -r -- "access_key_id = $main_id"
  print -r -- "secret_access_key = $main_secret"
  print -r -- "endpoint = $endpoint"
  print -r -- "no_check_bucket = true"
  print -r -- ""
  print -r -- "[gallery]"
  print -r -- "type = combine"
  print -r -- "upstreams = Public=gallery-public:gallery-public/folders Main=gallery-main:gallery-main/files"
} >> "$conf"

# -T lets `security` read the items back for copy-share-link.sh without asking each time
/usr/bin/security add-generic-password -U -s gallery-access -a client-id -T /usr/bin/security -w "$client_id"
/usr/bin/security add-generic-password -U -s gallery-access -a client-secret -T /usr/bin/security -w "$client_secret"

# the Quick Action runs from here, whatever happens to the project folder
support="$HOME/Library/Application Support/Gallery"
mkdir -p "$support"
cp "$here/copy-share-link.sh" "$support/copy-share-link.sh"
chmod 755 "$support/copy-share-link.sh"

print ""
print "Checking…"
errs="$(mktemp)"
r2_ok=1
for bucket in gallery-public gallery-main; do
  if ! "$rclone" lsf --max-depth 1 "${bucket}:${bucket}" >/dev/null 2>"$errs"; then
    r2_ok=0
    print "R2 bucket $bucket did not answer:"
    tail -n 3 "$errs" | sed 's/^/  /'
  fi
done
rm -f "$errs"
if [[ "$r2_ok" = 1 ]]; then
  print "Both R2 buckets answer."
else
  print "Check that bucket's token (Object Read & Write, that bucket only) and the bucket name."
fi
code=$(/usr/bin/curl -s -o /dev/null -w '%{http_code}' \
  -H "CF-Access-Client-Id: $client_id" -H "CF-Access-Client-Secret: $client_secret" \
  -H "x-gallery: 1" \
  https://gallery.improvdiplomat.workers.dev/main/api/whoami)
if [[ "$code" = 200 ]]; then
  print "This Mac can make links."
else
  print "Link sign-in check answered HTTP $code."
  print "  302/401/403/404: Access did not accept the token. In Zero Trust, the application \"Gallery Main\" needs a policy with action Service Auth that includes the token gallery-chau, and the application path must cover /main/* (not only /main)."
fi

# the Quick Action reads the token back through /usr/bin/security; confirm that works
if [[ -n "$(/usr/bin/security find-generic-password -s gallery-access -a client-id -w 2>/dev/null)" ]]; then
  print "Keychain read works."
else
  print "Keychain read FAILED: the Quick Action will not be able to sign in."
fi

print ""
print "Quick Action: in Automator make a Quick Action that receives files or folders in Finder, add Run Shell Script"
print "(shell /bin/bash, pass input as arguments), save it as \"Copy Share Link\", and put only this in the script box:"
print ""
print "  exec /bin/bash \"\$HOME/Library/Application Support/Gallery/copy-share-link.sh\" \"\$@\""
print ""
print "If Finder says it can't read a file, give Finder and Automator access under System Settings > Privacy & Security > Files and Folders (or Full Disk Access)."
print "Everything the Quick Action does is logged in ~/Library/Logs/gallery-link.log."