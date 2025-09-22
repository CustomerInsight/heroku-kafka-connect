# heroku-kafka-connect
Heroku에서 Container 기반으로 Kafka Connect를 구성하는 스크립트

## 사전 요구사항
- Heroku Dyno (최소 M 사이즈 이상 권장)
- Apache Kafka on Heroku

## 요구 파라미터
### Apache Kafka on Heroku 설치 시 자동 생성
- KAFKA_CLIENT_CERT  
- KAFKA_CLIENT_CERT_KEY  
- KAFKA_TRUSTED_CERT  
- KAFKA_URL

### 추가 필요
- CONNECT_GROUP_ID  
- CONNECT_OFFSET_STORAGE_TOPIC  
- CONNECT_CONFIG_STORAGE_TOPIC  
- CONNECT_STATUS_STORAGE_TOPIC  
- SCHEMA_REGISTRY_URL  
- SSL_KEY_PASSWORD  
- CONNECTOR_NAMES  
- CONNECTOR_${CONNECTOR_NAME}  

