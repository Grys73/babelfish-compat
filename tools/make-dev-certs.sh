#!/bin/sh
# Development certificates for TLS / TDS 8.0 strict (tds8-strict.patch).
# NOT for production: issue production certificates from your internal CA.
#
#   tools/make-dev-certs.sh [out_dir] [host names...]
#
# Creates out_dir/ca.crt + ca.key (a throwaway CA) and out_dir/server.crt +
# server.key for the given host names (default: localhost 127.0.0.1).
# Mount server.crt/server.key at /run/secrets/ in the container; clients trust
# ca.crt (Windows: Trusted Root store) or pin server.crt with
# ServerCertificate=<path> in the SqlClient connection string.
set -eu
OUT=${1:-./certs}
[ $# -gt 0 ] && shift
[ $# -eq 0 ] && set -- localhost 127.0.0.1
mkdir -p "$OUT"

SAN=""
for h in "$@"; do
	case "$h" in
		*[!0-9.]*) SAN="${SAN:+$SAN,}DNS:$h" ;;
		*) SAN="${SAN:+$SAN,}IP:$h" ;;
	esac
done

if [ ! -f "$OUT/ca.key" ]; then
	openssl req -x509 -newkey rsa:3072 -nodes -days 365 \
		-subj "/CN=babelfish-compat dev CA" \
		-addext "basicConstraints=critical,CA:TRUE" \
		-addext "keyUsage=critical,keyCertSign,cRLSign" \
		-keyout "$OUT/ca.key" -out "$OUT/ca.crt" 2>/dev/null
fi

openssl req -newkey rsa:3072 -nodes -subj "/CN=$1" \
	-keyout "$OUT/server.key" -out "$OUT/server.csr" 2>/dev/null
printf 'subjectAltName=%s\nextendedKeyUsage=serverAuth\nkeyUsage=critical,digitalSignature,keyEncipherment\n' "$SAN" > "$OUT/server.ext"
openssl x509 -req -in "$OUT/server.csr" -CA "$OUT/ca.crt" -CAkey "$OUT/ca.key" \
	-CAcreateserial -days 90 -extfile "$OUT/server.ext" -out "$OUT/server.crt" 2>/dev/null
rm -f "$OUT/server.csr" "$OUT/server.ext"
echo "wrote $OUT/ca.crt $OUT/server.crt $OUT/server.key for $SAN"
