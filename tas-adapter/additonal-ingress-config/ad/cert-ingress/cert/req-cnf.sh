#!/bin/bash

# $1 - CN
# $2 - type
mkdir -p generated/certs
cat >> generated/certs/$2-req.cnf <<EOF
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no
[req_distinguished_name]
C = TR
ST = Istanbul
L = Istanbul
O = VMware
OU = IT
CN = $1
[v3_req]
keyUsage = keyEncipherment, dataEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names
[alt_names]
DNS.1 = $1

EOF
