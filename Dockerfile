# -----------------------------------------------------------------------------
# Kafka Connect (Confluent) + Debezium JDBC + Confluent JDBC + Camel SFTP Sink
# -----------------------------------------------------------------------------
FROM confluentinc/cp-kafka-connect:8.0.0

# ---- Versions (override at build time if needed)
ARG DEBEZIUM_JDBC_VERSION=3.2.2.Final
ARG CONFLUENT_JDBC_VERSION=10.8.4
ARG CKC_VERSION=4.8.5

# ---- Paths
ENV CONNECT_PLUGIN_PATH=/usr/share/java/connect-plugins \
    CAMEL_SFTP_DIR=/usr/share/java/connect-plugins/camel-sftp-sink

USER root

# -----------------------------------------------------------------------------
# Base tools
# -----------------------------------------------------------------------------
RUN set -eux; \
    microdnf -y install openssl tar; \
    microdnf clean all; \
    rm -rf /var/cache/{yum,dnf} /var/tmp/* /tmp/*

# -----------------------------------------------------------------------------
# Debezium JDBC connector
# -----------------------------------------------------------------------------
RUN set -eux; \
    mkdir -p "${CONNECT_PLUGIN_PATH}/debezium-jdbc"; \
    curl -fL "https://repo1.maven.org/maven2/io/debezium/debezium-connector-jdbc/${DEBEZIUM_JDBC_VERSION}/debezium-connector-jdbc-${DEBEZIUM_JDBC_VERSION}-plugin.tar.gz" \
      | tar -xz -C "${CONNECT_PLUGIN_PATH}/debezium-jdbc"

# -----------------------------------------------------------------------------
# Confluent JDBC connector (copy only jars to plugin.path)
# -----------------------------------------------------------------------------
RUN set -eux; \
    mkdir -p /tmp/jdbc "${CONNECT_PLUGIN_PATH}/kafka-connect-jdbc"; \
    confluent-hub install --no-prompt --component-dir /tmp/jdbc "confluentinc/kafka-connect-jdbc:${CONFLUENT_JDBC_VERSION}"; \
    cp -a /tmp/jdbc/confluentinc-kafka-connect-jdbc/lib/*.jar "${CONNECT_PLUGIN_PATH}/kafka-connect-jdbc/"; \
    rm -rf /tmp/jdbc /var/tmp/* /tmp/*

# -----------------------------------------------------------------------------
# Apache Camel Kafka Connector - SFTP Sink
#  - Remove jars that conflict with Connect/Kafka/converters bundled in base
# -----------------------------------------------------------------------------
RUN set -eux; \
    mkdir -p "${CAMEL_SFTP_DIR}"; \
    curl -fL -o /tmp/camel-sftp-sink.tgz \
      "https://repo1.maven.org/maven2/org/apache/camel/kafkaconnector/camel-sftp-sink-kafka-connector/${CKC_VERSION}/camel-sftp-sink-kafka-connector-${CKC_VERSION}-package.tar.gz"; \
    tar -xzf /tmp/camel-sftp-sink.tgz -C "${CAMEL_SFTP_DIR}"; \
    rm -f /tmp/camel-sftp-sink.tgz; \
    # prune conflicting/duplicated jars shipped with the CKC package
    find "${CAMEL_SFTP_DIR}" -type f \( \
        -name 'connect-*.jar' -o \
        -name 'kafka-*.jar'  -o \
        -name 'kafka_*'      -o \
        -name '*apicurio*converter*.jar' -o \
        -name '*converter*.jar' \
      \) -print -delete

# -----------------------------------------------------------------------------
# Entrypoint
# -----------------------------------------------------------------------------
COPY --chown=appuser:appuser main.sh /usr/local/bin/main.sh
RUN chmod 0755 /usr/local/bin/main.sh && sed -i 's/\r$//' /usr/local/bin/main.sh

USER appuser
CMD ["/usr/local/bin/main.sh"]