# heroku-kafka-connect
Heroku에서 Container 기반으로 Kafka Connect를 구성하는 스크립트

## 사전 요구사항
- Heroku Dyno
- Apache Kafka on Heroku

## 요구 파라미터
### Apache Kafka on Heroku 설치 시 자동 생성
- KAFKA_CLIENT_CERT  
- KAFKA_CLIENT_CERT_KEY  
- KAFKA_TRUSTED_CERT  
- KAFKA_URL

### 추가 필요
- KAFKA_HEAP_OPTS : `-Xms256m -Xmx1024m` 기본값
    - Dyno 크기에 맞게 조정할 것
- CONNECT_GROUP_ID : `kafka-connect` 기본값
- CONNECT_OFFSET_STORAGE_TOPIC : `kafka-connect-offsets` 기본값
- CONNECT_CONFIG_STORAGE_TOPIC : `kafka-connect-configs` 기본값
- CONNECT_STATUS_STORAGE_TOPIC : `kafka-connect-status` 기본값
- SCHEMA_REGISTRY_URL  
- SSL_KEY_PASSWORD  
- CONNECTOR_NAMES  
- CONNECTOR_${CONNECTOR_NAME}  

