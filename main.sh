#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Kafka Connect Entrypoint
#  - CONNECTOR_NAMES="A B C"                # 공백 구분
#  - CONNECTOR_A / CONNECTOR_B ...          # 각 커넥터 flat JSON (one-line/pretty OK)
# =============================================================================

: "${KAFKA_URL:?ssl://host1:9096,ssl://host2:9096 ...}"
: "${KAFKA_CLIENT_CERT:?PEM cert chain text}"
: "${KAFKA_CLIENT_CERT_KEY:?PEM private key text}"
: "${KAFKA_TRUSTED_CERT:?PEM CA bundle text}"
: "${SSL_KEY_PASSWORD:?set SSL_KEY_PASSWORD}"
: "${SCHEMA_REGISTRY_URL:?Schema Registry URL is required}"

command -v openssl >/dev/null
command -v curl    >/dev/null

CONNECT_BASE_URL="${CONNECT_BASE_URL:-}"

# -----------------------------------------------------------------------------
# 1) SSL 파일 (PEM → PKCS12)
# -----------------------------------------------------------------------------
tmpdir="$(mktemp -d)"; export TMPDIR="$tmpdir"
printf "%s" "$KAFKA_CLIENT_CERT"     > "${tmpdir}/chain.pem"
printf "%s" "$KAFKA_CLIENT_CERT_KEY" > "${tmpdir}/key.pem"
printf "%s" "$KAFKA_TRUSTED_CERT"    > "${tmpdir}/ca.pem"

openssl pkcs12 -export -name client \
  -inkey "${tmpdir}/key.pem" -passin env:SSL_KEY_PASSWORD \
  -in "${tmpdir}/chain.pem" \
  -out "${tmpdir}/keystore.p12" -passout env:SSL_KEY_PASSWORD

# -----------------------------------------------------------------------------
# 2) Kafka Connect 환경
# -----------------------------------------------------------------------------
BOOTSTRAP_SERVERS="$(echo "$KAFKA_URL" | sed -E 's#(^|,)[A-Za-z0-9+._-]+://#\1#g; s/[[:space:]]//g')"
export CONNECT_BOOTSTRAP_SERVERS="$BOOTSTRAP_SERVERS"
export CONNECT_SECURITY_PROTOCOL="SSL"

export CONNECT_SSL_KEYSTORE_TYPE="PKCS12"
export CONNECT_SSL_KEYSTORE_LOCATION="${tmpdir}/keystore.p12"
export CONNECT_SSL_KEYSTORE_PASSWORD="${SSL_KEY_PASSWORD}"
export CONNECT_SSL_TRUSTSTORE_TYPE="PEM"
export CONNECT_SSL_TRUSTSTORE_LOCATION="${tmpdir}/ca.pem"
export CONNECT_SSL_ENDPOINT_IDENTIFICATION_ALGORITHM=""

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

export KAFKA_HEAP_OPTS="${KAFKA_HEAP_OPTS:-"-Xms256m -Xmx1024m"}"
export CONNECT_GROUP_ID="${CONNECT_GROUP_ID:-kafka-connect}"
export CONNECT_CONFIG_STORAGE_TOPIC="${CONNECT_CONFIG_STORAGE_TOPIC:-kafka-connect-configs}"
export CONNECT_OFFSET_STORAGE_TOPIC="${CONNECT_OFFSET_STORAGE_TOPIC:-kafka-connect-offsets}"
export CONNECT_STATUS_STORAGE_TOPIC="${CONNECT_STATUS_STORAGE_TOPIC:-kafka-connect-status}"
export CONNECT_CONFIG_STORAGE_REPLICATION_FACTOR=3
export CONNECT_OFFSET_STORAGE_REPLICATION_FACTOR=3
export CONNECT_STATUS_STORAGE_REPLICATION_FACTOR=3

# -----------------------------------------------------------------------------
# Converters: Avro + Schema Registry
# -----------------------------------------------------------------------------
export CONNECT_KEY_CONVERTER="io.confluent.connect.avro.AvroConverter"
export CONNECT_VALUE_CONVERTER="io.confluent.connect.avro.AvroConverter"
export CONNECT_KEY_CONVERTER_SCHEMA_REGISTRY_URL="${SCHEMA_REGISTRY_URL}"
export CONNECT_VALUE_CONVERTER_SCHEMA_REGISTRY_URL="${SCHEMA_REGISTRY_URL}"

# 내부 토픽용
export CONNECT_INTERNAL_KEY_CONVERTER="org.apache.kafka.connect.json.JsonConverter"
export CONNECT_INTERNAL_VALUE_CONVERTER="org.apache.kafka.connect.json.JsonConverter"
export CONNECT_INTERNAL_KEY_CONVERTER_SCHEMAS_ENABLE=false
export CONNECT_INTERNAL_VALUE_CONVERTER_SCHEMAS_ENABLE=false

export CONNECT_PLUGIN_PATH=/usr/share/java/connect-plugins

HOST_DEFAULT="${HEROKU_DNS_DYNO_NAME:-${HEROKU_APP_NAME:-${HOSTNAME}}}"
export CONNECT_REST_ADVERTISED_HOST_NAME="${CONNECT_REST_ADVERTISED_HOST_NAME:-${HOST_DEFAULT}}"
export CONNECT_REST_ADVERTISED_PORT="${CONNECT_REST_ADVERTISED_PORT:-${PORT}}"
export CONNECT_LISTENERS="http://0.0.0.0:${PORT}"
export CONNECT_REST_ADVERTISED_LISTENERS="${CONNECT_REST_ADVERTISED_LISTENERS:-http://${CONNECT_REST_ADVERTISED_HOST_NAME}:${PORT}}"

# -----------------------------------------------------------------------------
# 3) Helpers
# -----------------------------------------------------------------------------
CURL='curl -sS -L --max-time 10 --connect-timeout 3 -H Accept:application/json'
if [ -n "${CONNECT_BASIC_AUTH:-}" ]; then
  CURL="${CURL} -u ${CONNECT_BASIC_AUTH}"
fi

wait_connect_ready() {
  local tries=60 sleep_s=2 code
  for i in $(seq 1 "$tries"); do
    code="$(${CURL} -o /dev/null -w '%{http_code}' "${BASE_URL}/connectors" || true)"
    if [ "$code" = "200" ]; then
      echo "[INFO] Connect REST ready (/connectors 200) after ${i} tries"
      return 0
    fi
    sleep "$sleep_s"
  done
  echo "[ERROR] Connect REST not ready (no 200)"
  return 1
}

parse_connectors() {
  tr -d '\r\n' | grep -oE '"[^"]+"' | tr -d '"'
}

fetch_connectors() {
  local out code raw
  out="$(mktemp)"
  code="$(${CURL} "${BASE_URL}/connectors" -o "${out}" -w '%{http_code}' || true)"
  raw="$(cat "${out}" 2>/dev/null || true)"
  echo "[DEBUG] GET /connectors -> HTTP ${code} body=${raw}"
  if [ "$code" != "200" ]; then
    CONNECTORS_RAW=""; return 1
  fi
  CONNECTORS_RAW="$(printf '%s' "$raw" | parse_connectors)"   # 줄단위 목록
  return 0
}

delete_connector() {
  local name="$1" code
  for i in $(seq 1 8); do
    code="$(${CURL} -o /dev/null -w '%{http_code}' -X DELETE "${BASE_URL}/connectors/${name}?forward=true" || true)"
    case "$code" in
      200|204|404) echo "[OK] ${name} deleted (HTTP ${code})"; return 0 ;;
      409|5??)     echo "[WARN] ${name} delete retry ${i}/8 (HTTP ${code})"; sleep 2 ;;
      *)           echo "[WARN] ${name} delete failed (HTTP ${code})"; return 1 ;;
    esac
  done
  echo "[ERROR] ${name} delete exhausted retries"; return 1
}

# -----------------------------------------------------------------------------
# 4) Reconcile (Upsert → Prune)
# -----------------------------------------------------------------------------
reconcile_once() {
  # (A) Upsert
  if [ -n "${CONNECTOR_NAMES:-}" ]; then
    for name in ${CONNECTOR_NAMES}; do
      var="CONNECTOR_${name}"
      raw="${!var:-}"
      if [ -z "${raw}" ]; then
        echo "[WARN] ${var} is empty → skip upsert"; continue
      fi
      body_file="$(mktemp)"
      code="$(${CURL} -o "${body_file}" -w '%{http_code}' \
        -H 'Content-Type: application/json' \
        -X PUT --data-binary "${raw}" \
        "${BASE_URL}/connectors/${name}/config?forward=true")"
      echo "[DEBUG] PUT /connectors/${name}/config -> HTTP ${code} body=$(head -c 400 "${body_file}")"
      if [ "$code" = "200" ] || [ "$code" = "201" ]; then
        echo "[OK] upsert ${name} (HTTP ${code})"
      else
        echo "[WARN] upsert ${name} failed (HTTP ${code})"
      fi
    done
  else
    echo "[INFO] CONNECTOR_NAMES empty → skip upsert"
  fi

  # (B) Prune
  fetch_connectors || true

  if [ -z "${CONNECTORS_RAW:-}" ]; then
    echo "[INFO] connectors: (none)"
    return 0
  fi

  echo "[INFO] connectors:"
  for n in ${CONNECTORS_RAW}; do
    echo "  - $n"
  done

  in_desired() {
    local x="$1"
    for d in ${CONNECTOR_NAMES:-}; do [ "$d" = "$x" ] && return 0; done
    return 1
  }

  for cur in ${CONNECTORS_RAW}; do
    if ! in_desired "$cur"; then
      echo "[INFO] Deleting unmanaged connector: ${cur}"
      delete_connector "${cur}"
    fi
  done
}

# -----------------------------------------------------------------------------
# 5) 메인
# -----------------------------------------------------------------------------
BASE_URL="${CONNECT_BASE_URL:-http://127.0.0.1:${PORT}}"
echo "[INFO] Connect REST base = ${BASE_URL}"

(
  wait_connect_ready || exit 0
  reconcile_once
) &

exec /etc/confluent/docker/run