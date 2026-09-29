#!/bin/bash
set -e

NAMESPACE=$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace)
SA_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
CA_CERT="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
KUBE_API="https://kubernetes.default.svc"
MLFLOW_URL="https://mlflow.redhat-ods-applications.svc:8443/mlflow"
MODEL_NAME="hoi"
S3_MODEL_PREFIX="models/hoi"

kube_get() {
  curl -sf --cacert "${CA_CERT}" \
    -H "Authorization: Bearer ${SA_TOKEN}" \
    "${KUBE_API}/api/v1/namespaces/${NAMESPACE}/$1"
}

# Get bucket info from the pipeline-artifacts OBC configmap
BUCKET_NAME=$(kube_get "configmaps/pipeline-artifacts" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['BUCKET_NAME'])")
BUCKET_HOST=$(kube_get "configmaps/pipeline-artifacts" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['BUCKET_HOST'])")
BUCKET_PORT=$(kube_get "configmaps/pipeline-artifacts" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['BUCKET_PORT'])")

SECRET_DATA=$(kube_get "secrets/pipeline-artifacts")
AWS_ACCESS_KEY_ID=$(echo "${SECRET_DATA}" | python3 -c "import sys,json,base64; print(base64.b64decode(json.load(sys.stdin)['data']['AWS_ACCESS_KEY_ID']).decode())")
AWS_SECRET_ACCESS_KEY=$(echo "${SECRET_DATA}" | python3 -c "import sys,json,base64; print(base64.b64decode(json.load(sys.stdin)['data']['AWS_SECRET_ACCESS_KEY']).decode())")

S3_ENDPOINT="https://${BUCKET_HOST}:${BUCKET_PORT}"
echo "Bucket: ${BUCKET_NAME}"
echo "Endpoint: ${S3_ENDPOINT}"

# Wait for the model to be registered in MLflow
echo "Waiting for model '${MODEL_NAME}' to appear in MLflow..."
timeout=600
elapsed=0
step=15
MODEL_INFO=""
while [ -z "${MODEL_INFO}" ]; do
  MODEL_INFO=$(curl -sf --cacert "${CA_CERT}" \
    "${MLFLOW_URL}/api/2.0/mlflow/registered-models/get?name=${MODEL_NAME}" \
    -H "Authorization: Bearer ${SA_TOKEN}" \
    -H "X-Mlflow-Workspace: ${NAMESPACE}" 2>/dev/null) || true
  if [ -z "${MODEL_INFO}" ]; then
    if [ ${elapsed} -ge ${timeout} ]; then
      echo "Timed out waiting for model to be registered in MLflow"
      exit 1
    fi
    echo "  Model not found yet, retrying in ${step}s... (${elapsed}/${timeout}s)"
    sleep ${step}
    elapsed=$((elapsed + step))
  fi
done
echo "Model found in MLflow."

LATEST_VERSION=$(echo "${MODEL_INFO}" | python3 -c "import sys,json; m=json.load(sys.stdin); print(m['registered_model']['latest_versions'][0]['version'])")
RUN_ID=$(echo "${MODEL_INFO}" | python3 -c "import sys,json; m=json.load(sys.stdin); print(m['registered_model']['latest_versions'][0]['run_id'])")
echo "Latest version: ${LATEST_VERSION}, run_id: ${RUN_ID}"

# Download model artifacts from MLflow
ARTIFACTS=("MLmodel" "model.pkl" "conda.yaml" "python_env.yaml" "requirements.txt")
mkdir -p /tmp/model

for artifact in "${ARTIFACTS[@]}"; do
  echo "Downloading ${artifact}..."
  curl -sf --cacert "${CA_CERT}" \
    -o "/tmp/model/${artifact}" \
    "${MLFLOW_URL}/model-versions/get-artifact?name=${MODEL_NAME}&version=${LATEST_VERSION}&path=${artifact}" \
    -H "Authorization: Bearer ${SA_TOKEN}" \
    -H "X-Mlflow-Workspace: ${NAMESPACE}" 2>/dev/null || true
  if [ -f "/tmp/model/${artifact}" ] && [ -s "/tmp/model/${artifact}" ]; then
    echo "  Downloaded ${artifact}"
  else
    echo "  Skipping ${artifact} (not found)"
    rm -f "/tmp/model/${artifact}"
  fi
done

echo "Downloaded model files:"
ls -la /tmp/model/

# Upload to S3
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
for file in /tmp/model/*; do
  filename=$(basename "$file")
  s3_key="${S3_MODEL_PREFIX}/${filename}"
  echo "Uploading ${filename} -> s3://${BUCKET_NAME}/${s3_key}"

  python3 -c "
import boto3, os
from botocore.config import Config
s3 = boto3.client('s3',
    endpoint_url='${S3_ENDPOINT}',
    aws_access_key_id=os.environ['AWS_ACCESS_KEY_ID'],
    aws_secret_access_key=os.environ['AWS_SECRET_ACCESS_KEY'],
    verify=False,
    config=Config(signature_version='s3v4'))
s3.upload_file('${file}', '${BUCKET_NAME}', '${s3_key}')
"
done

echo "Model uploaded to s3://${BUCKET_NAME}/${S3_MODEL_PREFIX}/"

# Create RHOAI data connection secret
echo "Creating RHOAI data connection..."

# Delete existing secret if present
curl -sf --cacert "${CA_CERT}" \
  -X DELETE \
  -H "Authorization: Bearer ${SA_TOKEN}" \
  "${KUBE_API}/api/v1/namespaces/${NAMESPACE}/secrets/model-data-connection" 2>/dev/null || true

# Create the data connection secret
python3 -c "
import json, base64
secret = {
    'apiVersion': 'v1',
    'kind': 'Secret',
    'metadata': {
        'name': 'model-data-connection',
        'namespace': '${NAMESPACE}',
        'labels': {
            'opendatahub.io/dashboard': 'true',
            'opendatahub.io/managed': 'true'
        },
        'annotations': {
            'opendatahub.io/connection-type': 's3',
            'openshift.io/display-name': 'MLflow Model Store'
        }
    },
    'type': 'Opaque',
    'data': {
        'AWS_ACCESS_KEY_ID': base64.b64encode(b'${AWS_ACCESS_KEY_ID}').decode(),
        'AWS_SECRET_ACCESS_KEY': base64.b64encode(b'${AWS_SECRET_ACCESS_KEY}').decode(),
        'AWS_S3_ENDPOINT': base64.b64encode(b'${S3_ENDPOINT}').decode(),
        'AWS_S3_BUCKET': base64.b64encode(b'${BUCKET_NAME}').decode(),
        'AWS_DEFAULT_REGION': base64.b64encode(b'us-east-1').decode()
    }
}
print(json.dumps(secret))
" | curl -sf --cacert "${CA_CERT}" \
  -X POST \
  -H "Authorization: Bearer ${SA_TOKEN}" \
  -H "Content-Type: application/json" \
  -d @- \
  "${KUBE_API}/api/v1/namespaces/${NAMESPACE}/secrets"

echo ""
echo "Data connection 'MLflow Model Store' created successfully."
echo "Deploy the model from the RHOAI dashboard using:"
echo "  Data connection: MLflow Model Store"
echo "  Path: ${S3_MODEL_PREFIX}"
