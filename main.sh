#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Kafka Connect Entrypoint Script
# - SSL 인증서 처리 (ENV → 파일 → keystore/truststore)
# - Kafka Connect 환경 변수 구성
# - 커넥터 자동 등록 (Heroku 환경 변수 기반)
# ============================================================================

# ===== Required ENVs =====
: "${PORT:?PORT env is required}"
: "${KAFKA_URL:?ssl://host1:9096,ssl://host2:9096 ...}"
: "${SCHEMA_REGISTRY_URL:?Schema Registry URL is required}"
: "${KAFKA_CLIENT_CERT:?PEM cert chain text}"
: "${KAFKA_CLIENT_CERT_KEY:?PEM private key text}"
: "${KAFKA_TRUSTED_CERT:?PEM CA bundle text}"
: "${SSL_KEY_PASSWORD:?set SSL_KEY_PASSWORD (your passphrase)}"

command -v python3 >/dev/null
command -v openssl  >/dev/null

# ----------------------------------------------------------------------------
# Normalize helper: ENV 값을 파일로 내릴 때 줄바꿈/따옴표/CRLF 문제 해결
# ----------------------------------------------------------------------------
normalize_from_env() {
  python3 - <<'PY' "$1"
import os, sys
name=sys.argv[1]
v=os.environ.get(name,"")
if len(v)>=2 and v[0]==v[-1]=='"': v=v[1:-1]
v=v.replace("\\r\\n","\n").replace("\\n","\n").replace("\r","")
sys.stdout.write(v)
PY
}

# ----------------------------------------------------------------------------
# 1. ENV → 파일 변환
# ----------------------------------------------------------------------------
tmpdir="$(mktemp -d)"; export TMPDIR="$tmpdir"
normalize_from_env KAFKA_CLIENT_CERT     > "${tmpdir}/chain.orig.pem"
normalize_from_env KAFKA_CLIENT_CERT_KEY > "${tmpdir}/key_in.pem"
normalize_from_env KAFKA_TRUSTED_CERT    > "${tmpdir}/ca.pem"

# ----------------------------------------------------------------------------
# 2. Private Key → PKCS#8 (암호화된 형태 보장)
# ----------------------------------------------------------------------------
if grep -q "ENCRYPTED PRIVATE KEY" "${tmpdir}/key_in.pem"; then
  cp "${tmpdir}/key_in.pem" "${tmpdir}/key_pkcs8_enc.pem"
else
  openssl pkcs8 -topk8 -v2 aes-256-cbc \
    -passout env:SSL_KEY_PASSWORD \
    -in "${tmpdir}/key_in.pem" \
    -out "${tmpdir}/key_pkcs8_enc.pem"
fi

# ----------------------------------------------------------------------------
# 3. Leaf cert 추출 & 체인 정렬
#    - 개인키와 매칭되는 leaf cert 찾기
# ----------------------------------------------------------------------------
# 개인키 평문 추출
if grep -q "ENCRYPTED PRIVATE KEY" "${tmpdir}/key_in.pem"; then
  openssl pkcs8 -topk8 -nocrypt -passin env:SSL_KEY_PASSWORD \
    -in "${tmpdir}/key_in.pem" -out "${tmpdir}/key_plain.pem"
else
  openssl pkcs8 -topk8 -nocrypt \
    -in "${tmpdir}/key_in.pem" -out "${tmpdir}/key_plain.pem"
fi

# 개인키의 PublicKey SHA
key_pub_sha="$(openssl pkey -pubout -in "${tmpdir}/key_plain.pem" \
  2>/dev/null | openssl sha256 | awk '{print $2}')"
[ -n "${key_pub_sha:-}" ] || { echo "cannot extract public key"; exit 1; }

# 체인 분리 → cert_00.pem, cert_01.pem ...
awk 'BEGIN{c=0} /-----BEGIN CERTIFICATE-----/{c++}
     {print > sprintf("'"${tmpdir}"'/cert_%02d.pem", c)}' \
     "${tmpdir}/chain.orig.pem" || true

# Leaf cert 탐색
best=""
for f in $(ls "${tmpdir}"/cert_*.pem 2>/dev/null | sort); do
  [ -s "$f" ] || continue
  csha="$(openssl x509 -pubkey -noout -in "$f" \
          2>/dev/null | openssl sha256 | awk '{print $2}' || true)"
  [ "$csha" = "$key_pub_sha" ] && { best="$f"; break; }
done
[ -n "$best" ] || { echo "no leaf in KAFKA_CLIENT_CERT matching the private key"; exit 1; }

# 체인 정렬 (leaf → 나머지)
{ cat "$best"; for f in $(ls "${tmpdir}"/cert_*.pem | sort); do
    [ "$f" = "$best" ] || cat "$f"; done; } > "${tmpdir}/chain.fixed.pem"

# ----------------------------------------------------------------------------
# 4. PKCS12 Keystore 생성
# ----------------------------------------------------------------------------
openssl pkcs12 -export -name client \
  -inkey "${tmpdir}/key_pkcs8_enc.pem" -passin env:SSL_KEY_PASSWORD \
  -in "${tmpdir}/chain.fixed.pem" \
  -out "${tmpdir}/keystore.p12" -passout env:SSL_KEY_PASSWORD

# ----------------------------------------------------------------------------
# 5. Kafka Connect 공통 SSL 설정
# ----------------------------------------------------------------------------
BOOTSTRAP_SERVERS="$(echo "$KAFKA_URL" | sed -E 's#(^|,)[A-Za-z0-9+._-]+://#\1#g; s/[[:space:]]//g')"
export CONNECT_BOOTSTRAP_SERVERS="$BOOTSTRAP_SERVERS"
export CONNECT_SECURITY_PROTOCOL="SSL"

# Keystore
export CONNECT_SSL_KEYSTORE_TYPE="PKCS12"
export CONNECT_SSL_KEYSTORE_LOCATION="${tmpdir}/keystore.p12"
export CONNECT_SSL_KEYSTORE_PASSWORD="${SSL_KEY_PASSWORD}"

# Truststore
export CONNECT_SSL_TRUSTSTORE_TYPE="PEM"
export CONNECT_SSL_TRUSTSTORE_LOCATION="${tmpdir}/ca.pem"

# SAN 검증 비활성화 (호스트 mismatch 회피)
export CONNECT_SSL_ENDPOINT_IDENTIFICATION_ALGORITHM=""

# Producer/Consumer 동일 설정
for prefix in CONNECT_PRODUCER CONNECT_CONSUMER; do
  export ${prefix}_BOOTSTRAP_SERVERS="$BOOTSTRAP_SERVERS"
  export ${prefix}_SECURITY_PROTOCOL="SSL"
  export ${prefix}_SSL_KEYSTORE_TYPE="PKCS12"
  export ${prefix}_SSL_KEYSTORE_LOCATION="${tmpdir}/keystore.p12"
  export ${prefix}_SSL_KEYSTORE_PASSWORD="${SSL_KEY_PASSWORD}"
  export ${prefix}_SSL_TRUSTSTORE_TYPE="PEM"
  export ${prefix}_SSL_TRUSTSTORE_LOCATION="${tmpdir}/ca.pem"
  export ${prefix}_SSL_ENDPOINT_IDENTIFICATION_ALGORITHM=""
done

# ----------------------------------------------------------------------------
# 6. Kafka Connect 기본 환경 변수
# ----------------------------------------------------------------------------
export KAFKA_HEAP_OPTS="${KAFKA_HEAP_OPTS:-"-Xms256m -Xmx1024m"}"
export CONNECT_GROUP_ID="${CONNECT_GROUP_ID:-kafka-connect}"
export CONNECT_CONFIG_STORAGE_TOPIC="${CONNECT_CONFIG_STORAGE_TOPIC:-kafka-connect-configs}"
export CONNECT_OFFSET_STORAGE_TOPIC="${CONNECT_OFFSET_STORAGE_TOPIC:-kafka-connect-offsets}"
export CONNECT_STATUS_STORAGE_TOPIC="${CONNECT_STATUS_STORAGE_TOPIC:-kafka-connect-status}"
export CONNECT_CONFIG_STORAGE_REPLICATION_FACTOR=3
export CONNECT_OFFSET_STORAGE_REPLICATION_FACTOR=3
export CONNECT_STATUS_STORAGE_REPLICATION_FACTOR=3

# Converters (Avro + Schema Registry)
export CONNECT_KEY_CONVERTER="io.confluent.connect.avro.AvroConverter"
export CONNECT_VALUE_CONVERTER="io.confluent.connect.avro.AvroConverter"
export CONNECT_KEY_CONVERTER_SCHEMA_REGISTRY_URL="${SCHEMA_REGISTRY_URL}"
export CONNECT_VALUE_CONVERTER_SCHEMA_REGISTRY_URL="${SCHEMA_REGISTRY_URL}"

# Internal converters (JSON, schema off)
export CONNECT_INTERNAL_KEY_CONVERTER="org.apache.kafka.connect.json.JsonConverter"
export CONNECT_INTERNAL_VALUE_CONVERTER="org.apache.kafka.connect.json.JsonConverter"
export CONNECT_INTERNAL_KEY_CONVERTER_SCHEMAS_ENABLE=false
export CONNECT_INTERNAL_VALUE_CONVERTER_SCHEMAS_ENABLE=false

# Plugins
export CONNECT_PLUGIN_PATH=/usr/share/java/connect-plugins

# REST API
export CONNECT_LISTENERS="http://0.0.0.0:${PORT}"
export CONNECT_REST_PORT="${PORT}"
export CONNECT_REST_ADVERTISED_HOST_NAME="${CONNECT_REST_ADVERTISED_HOST_NAME:-0.0.0.0}"
export CONNECT_REST_ADVERTISED_PORT="${PORT}"
export CONNECT_REST_ADVERTISED_LISTENERS="http://${CONNECT_REST_ADVERTISED_HOST_NAME}:${PORT}"

# ----------------------------------------------------------------------------
# 7. Connector Auto-register (환경변수 기반)
#    - CONNECTOR_NAMES="PG_SINK SFTP_SINK"
#    - CONNECTOR_PG_SINK='{...}'
# ----------------------------------------------------------------------------
(
  set -euo pipefail
  base_url="http://127.0.0.1:${PORT}"

  # REST API up 대기 (최대 90초)
  for i in $(seq 1 90); do
    curl -fsS "${base_url}/" >/dev/null 2>&1 && { echo "[INFO] Connect REST is up."; break; }
    sleep 1
  done

  # Connector upsert
  for name in ${CONNECTOR_NAMES:-}; do
    var="CONNECTOR_${name}"
    json="${!var:-}"

    if [ -z "${json}" ]; then
      echo "[WARN] ${var} is empty. Skipped."
      continue
    fi

    echo "[INFO] Upserting connector: ${name}"
    http_code="$(curl -sS -X PUT \
      -H "Content-Type: application/json" \
      --data-binary @- \
      --retry 5 --retry-delay 2 --retry-connrefused \
      -o /dev/stderr -w "%{http_code}" \
      "${base_url}/connectors/${name}/config" <<< "${json}")"

    case "${http_code}" in
      200|201) echo "[OK] ${name} upserted (HTTP ${http_code})";;
      *)       echo "[ERROR] ${name} upsert failed (HTTP ${http_code}) -- check payload (${var})";;
    esac
  done
) &

# ----------------------------------------------------------------------------
# 8. Run Kafka Connect
# ----------------------------------------------------------------------------
exec /etc/confluent/docker/run