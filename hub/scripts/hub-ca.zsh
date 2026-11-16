#!/bin/zsh
# Derived from Spec: FEAT-18 (H1e). Makes the hub's own certificate root, name-constrained to recense.local, and the
# hub's TLS certificate. Run again to renew the certificate (the root is kept). The root's key never leaves
# ~/.config/recense/hub-ca and is never printed.
#   zsh hub/scripts/hub-ca.zsh [mac|mini]      (the name this hub also answers at, default: mac)
set -euo pipefail
OPENSSL=${OPENSSL:-/opt/homebrew/bin/openssl}
[ -x "$OPENSSL" ] || OPENSSL=openssl
NAME=${1:-mac}
CA=$HOME/.config/recense/hub-ca
OUT=$HOME/.config/recense/hub
umask 077
mkdir -p "$CA" "$OUT"
chmod 700 "$CA" "$OUT"

if [ ! -f "$CA/root.key" ]; then
  "$OPENSSL" ecparam -name prime256v1 -genkey -noout -out "$CA/root.key"
  cat > "$CA/root.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = Recense Hub Root
O = Recense
[v3]
basicConstraints = critical,CA:TRUE,pathlen:0
keyUsage = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
nameConstraints = critical,permitted;DNS:recense.local
EOF
  "$OPENSSL" req -x509 -new -key "$CA/root.key" -sha256 -days 3650 -config "$CA/root.cnf" -out "$CA/root.pem"
  echo "root made: $CA/root.pem"
fi

cat > "$OUT/leaf.cnf" <<EOF
[req]
distinguished_name = dn
req_extensions = v3
prompt = no
[dn]
CN = recense.local
O = Recense
[v3]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = serverAuth
subjectAltName = DNS:recense.local,DNS:*.recense.local,DNS:$NAME.recense.local
EOF
"$OPENSSL" ecparam -name prime256v1 -genkey -noout -out "$OUT/tls.key"
"$OPENSSL" req -new -key "$OUT/tls.key" -config "$OUT/leaf.cnf" -out "$OUT/tls.csr"
"$OPENSSL" x509 -req -in "$OUT/tls.csr" -CA "$CA/root.pem" -CAkey "$CA/root.key" -CAcreateserial \
  -days 820 -sha256 -extfile "$OUT/leaf.cnf" -extensions v3 -out "$OUT/tls.pem"
cat "$OUT/tls.pem" "$CA/root.pem" > "$OUT/tls-chain.pem"

# Apple's SecPKCS12Import needs a password and, with OpenSSL 3+/4, the older (legacy) encryption.
P12PASS=recense-hub
echo -n "$P12PASS" > "$OUT/tls.p12.pass"
"$OPENSSL" pkcs12 -export -inkey "$OUT/tls.key" -in "$OUT/tls.pem" -certfile "$CA/root.pem" \
  -name "recense-hub" -passout "pass:$P12PASS" -legacy -out "$OUT/tls.p12" 2>/dev/null \
  || "$OPENSSL" pkcs12 -export -inkey "$OUT/tls.key" -in "$OUT/tls.pem" -certfile "$CA/root.pem" \
       -name "recense-hub" -passout "pass:$P12PASS" -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 -out "$OUT/tls.p12"
rm -f "$OUT/tls.csr" "$CA/root.srl"
chmod 600 "$OUT"/tls.key "$OUT"/tls.p12 "$OUT"/tls.p12.pass

# The root for iPhone and iPad as a configuration profile (certificate payload only; no key).
ROOTB64=$(base64 < "$CA/root.pem" | tr -d '\n')
PL=$("$OPENSSL" x509 -in "$CA/root.pem" -noout -fingerprint -sha256 | sed 's/.*=//; s/://g' | cut -c1-32)
cat > "$OUT/recense-hub-root.mobileconfig" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
 <key>PayloadType</key><string>Configuration</string>
 <key>PayloadVersion</key><integer>1</integer>
 <key>PayloadIdentifier</key><string>local.recense.hub.root</string>
 <key>PayloadUUID</key><string>7E2B1C54-9A3D-4F10-8C66-0D5A4B7E9F21</string>
 <key>PayloadDisplayName</key><string>Recense Hub Root</string>
 <key>PayloadDescription</key><string>Lets this device trust https://recense.local (only that name).</string>
 <key>PayloadContent</key><array><dict>
  <key>PayloadType</key><string>com.apple.security.root</string>
  <key>PayloadVersion</key><integer>1</integer>
  <key>PayloadIdentifier</key><string>local.recense.hub.root.cert</string>
  <key>PayloadUUID</key><string>3C8D0E71-5B2A-4A9F-B1E4-6F7A2C9D8E03</string>
  <key>PayloadDisplayName</key><string>Recense Hub Root</string>
  <key>PayloadContent</key><data>$ROOTB64</data>
 </dict></array>
</dict></plist>
EOF
chmod 644 "$OUT/recense-hub-root.mobileconfig"
cp "$CA/root.pem" "$OUT/recense-hub-root.pem"
echo "hub certificate: $OUT/tls.p12 (valid 820 days); root fingerprint: $PL"
