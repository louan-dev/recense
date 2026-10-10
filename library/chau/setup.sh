#!/bin/zsh
# One-time setup on the Mac. Asks for the keys made in the Cloudflare dashboard, without
# showing them, and stores them where Gallery's tools look:
#   - rclone remotes gallery-public, gallery-main, and gallery (both together, for the mount)
#   - the Access service token, in the Keychain, for copy-public-link.sh
#
#   zsh mac/setup.sh
set -e

rclone=/opt/homebrew/bin/rclone
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
  print ""
  print "[gallery-public]"
  print "type = s3"
  print "provider = Cloudflare"
  print "access_key_id = $public_id"
  print "secret_access_key = $public_secret"
  print "endpoint = $endpoint"
  print "no_check_bucket = true"
  print ""
  print "[gallery-main]"
  print "type = s3"
  print "provider = Cloudflare"
  print "access_key_id = $main_id"
  print "secret_access_key = $main_secret"
  print "endpoint = $endpoint"
  print "no_check_bucket = true"
  print ""
  print "[gallery]"
  print "type = combine"
  print "upstreams = Public=gallery-public:gallery-public/folders Main=gallery-main:gallery-main/files"
} >> "$conf"

# -T lets `security` read the items back for copy-public-link.sh without asking each time
/usr/bin/security add-generic-password -U -s gallery-access -a client-id -T /usr/bin/security -w "$client_id"
/usr/bin/security add-generic-password -U -s gallery-access -a client-secret -T /usr/bin/security -w "$client_secret"

print ""
print "Checking…"
"$rclone" lsf gallery: && print "Gallery remotes work."
code=$(/usr/bin/curl -s -o /dev/null -w '%{http_code}' \
  -H "CF-Access-Client-Id: $client_id" -H "CF-Access-Client-Secret: $client_secret" \
  https://gallery.improvdiplomat.workers.dev/main/api/whoami)
[[ "$code" = 200 ]] && print "This Mac can make links." || print "Link sign-in check answered HTTP $code."
