#!/bin/zsh
# Adds the rclone remote "gallery-tmp" from a gallery-tmp-only R2 token. Keys are typed hidden, never echoed or logged.
read -rs "AK?R2 Access Key ID: "; echo
read -rs "SK?R2 Secret Access Key: "; echo
EP=$(rclone config show gallery-main | awk -F' = ' '$1=="endpoint"{print $2}')
rclone config create gallery-tmp s3 provider=Cloudflare env_auth=false no_check_bucket=true endpoint="$EP" access_key_id="$AK" secret_access_key="$SK" >/dev/null
unset AK SK EP
rclone lsf gallery-tmp:gallery-tmp --max-depth 1 >/dev/null && echo OK || echo "FAILED: check the keys"
