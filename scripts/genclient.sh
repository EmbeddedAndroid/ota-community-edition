#!/usr/bin/env bash

set -euo pipefail

export SERVERNAME=${SERVERNAME:-ota.ce}
export DEVICE_ID=${1}
export DEVICE_SSH_PORT=${2:-2222}
export DEVICE_UUID=$(uuidgen | tr A-Z a-z)

readonly GATEWAY_ADDR=${GATEWAY_ADDR:-$(kubectl get nodes -o jsonpath --template='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')}
readonly DEVICE_ADDR=${DEVICE_ADDR:-localhost}
readonly REGISTRY_HOST=$(kubectl get ingress -o jsonpath --template='{.items[?(@.metadata.name=="device-registry")].spec.rules[0].host}')
readonly SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
readonly SERVER_DIR="${SCRIPT_DIR}/../${SERVERNAME}"
readonly DEVICES_DIR=${SERVER_DIR}/devices
readonly DIR=${DEVICES_DIR}/${DEVICE_ID}
mkdir -p ${DIR}

openssl ecparam -genkey -name prime256v1 | openssl ec -out ${DIR}/pkey.ec.pem
openssl pkcs8 -topk8 -nocrypt -in ${DIR}/pkey.ec.pem -out ${DIR}/pkey.pem
openssl req -new -config ${SCRIPT_DIR}/client.cnf -key ${DIR}/pkey.pem -out ${DIR}/${DEVICE_ID}.csr
openssl x509 -req -days 365 -extfile ${SCRIPT_DIR}/client.ext -in ${DIR}/${DEVICE_ID}.csr \
  -CAkey ${DEVICES_DIR}/ca.key -CA ${DEVICES_DIR}/ca.crt -CAcreateserial -out ${DIR}/client.pem
cat ${DIR}/client.pem ${DEVICES_DIR}/ca.crt > ${DIR}/${DEVICE_ID}.chain.pem
ln -s ${SERVER_DIR}/server_ca.pem ${DIR}/ca.pem || true

openssl x509 -in ${DIR}/client.pem -text -noout

if ! which minikube > /dev/null 2>&1; then
  # Allow generating keys only
  exit 0
fi

readonly MINIKUBE_IP=${MINIKUBE_IP:-$(minikube ip)}
http PUT http://${MINIKUBE_IP}/api/v1/devices "Host:${REGISTRY_HOST}" deviceUuid="${DEVICE_UUID}" \
  deviceId=${DEVICE_ID} deviceName=${DEVICE_ID} deviceType=Other credentials=@${DIR}/client.pem

ssh -o StrictHostKeyChecking=no root@${DEVICE_ADDR} -p ${DEVICE_SSH_PORT} "echo \"${GATEWAY_ADDR} ota.ce\" >> /etc/hosts"
scp -P ${DEVICE_SSH_PORT} -o StrictHostKeyChecking=no ${DIR}/client.pem root@${DEVICE_ADDR}:/var/sota/client.pem
scp -P ${DEVICE_SSH_PORT} -o StrictHostKeyChecking=no ${DIR}/pkey.pem root@${DEVICE_ADDR}:/var/sota/pkey.pem
