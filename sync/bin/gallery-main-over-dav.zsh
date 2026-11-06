#!/bin/zsh
# Gallery's Main folder through the Worker's WebDAV (Access, trash, versions, chunked uploads) instead of the
# gallery-main S3 key. Uses this Mac's Access service token from the Keychain (gallery-access). Asks once for the
# Gallery keys password. Undo:  zsh gallery-main-over-dav.zsh undo
set -eu
read -rs "RCLONE_CONFIG_PASS?Gallery keys password: "; echo
export RCLONE_CONFIG_PASS
s3="Public=gallery-public:gallery-public/folders Main=gallery-main:gallery-main/files tmp=gallery-tmp:gallery-tmp"
dav="Public=gallery-public:gallery-public/folders Main=gallery-main-dav: tmp=gallery-tmp:gallery-tmp"
if [[ ${1:-} == undo ]]; then
  rclone config update gallery upstreams "$s3" >/dev/null
  echo "Main is back on the S3 key."
  exit
fi
ID=$(security find-generic-password -s gallery-access -a client-id -w)
SEC=$(security find-generic-password -s gallery-access -a client-secret -w)
rclone config create gallery-main-dav webdav url=https://gallery.improvdiplomat.workers.dev/main/nc/dav/files/owner/ \
  vendor=nextcloud nextcloud_chunk_size=50M headers="CF-Access-Client-Id,$ID,CF-Access-Client-Secret,$SEC" >/dev/null
unset ID SEC
rclone lsf gallery-main-dav: --max-depth 1 >/dev/null
rclone config update gallery upstreams "$dav" >/dev/null
echo "Main now goes through the Worker. Close and reopen Gallery."
