#!/bin/bash

mkdir -p generated/keys

export INSTALL_REGISTRY_HOSTNAME=registry.tanzu.vmware.com
export INSTALL_REGISTRY_USERNAME=$(cat values.yaml | grep tanzunet -A 3 | awk '/username:/ {print $2}')
export INSTALL_REGISTRY_PASSWORD=$(cat values.yaml  | grep tanzunet -A 3 | awk '/password:/ {print $2}')
export VALUES_YAML=values.yaml
export PROJECT_ID=$(yq e .gcloud.project_name $VALUES_YAML)

if [ $(yq e .provider-config.dns $VALUES_YAML) = "gcloud-dns" ] && [ $(yq e .provider-config.k8s $VALUES_YAML) == "gke" ];
then

  kubectl create ns tanzu-kapp
  kubectl create namespace tanzu-system-service-discovery

  CLOUD_DNS_SA=dns-admin-$(date +%s)
  gcloud --project $PROJECT_ID iam service-accounts create $CLOUD_DNS_SA \
      --display-name "Service Account to support ACME DNS-01 challenge."
  CLOUD_DNS_SA=$CLOUD_DNS_SA@$PROJECT_ID.iam.gserviceaccount.com
  gcloud projects add-iam-policy-binding $PROJECT_ID \
       --member serviceAccount:$CLOUD_DNS_SA \
       --role roles/dns.admin
  gcloud iam service-accounts keys create generated/keys/key.json  --iam-account $CLOUD_DNS_SA

  while cat generated/keys/key.json 2> /dev/null | grep $PROJECT_ID >> /dev/null; [ $? -ne 0 ]; do
  	echo key.json file for gcloud-dns service account not created yet. Sleeping 60s
  	sleep 30s
  done

  kubectl -n tanzu-system-service-discovery create secret \
      generic gcloud-dns-credentials \
      --from-file=credentials.json=generated/keys/key.json \
      -o yaml --dry-run=client | kubectl apply -f-
  
  ytt --ignore-unknown-comments -f values.yaml -f config/gcloud/external-dns-gcloud-values.yaml  > generated/external-dns-gcloud-values.yaml
  tanzu package repository add tanzu-standard --url projects.registry.vmware.com/tkg/packages/standard/repo:v1.4.0 -n tanzu-kapp
  VERSION=$(tanzu package available list external-dns.tanzu.vmware.com -oyaml -n tanzu-kapp| yq eval ".[0].version" -)
  tanzu package install external-dns \
      --package-name external-dns.tanzu.vmware.com \
      --version $VERSION \
      --namespace tanzu-kapp \
      --values-file generated/external-dns-gcloud-values.yaml \
      --poll-timeout 10m0s

  while kubectl get app external-dns -n tanzu-kapp | grep "Reconcile succeeded" ; [ $? -ne 0 ]; do
  	echo external-dns is not ready yet. Sleeping 60s
  	sleep 60s
  done

fi



kubectl create ns tap-install
tanzu secret registry add tap-registry \
  --username ${INSTALL_REGISTRY_USERNAME} --password ${INSTALL_REGISTRY_PASSWORD} \
  --server ${INSTALL_REGISTRY_HOSTNAME} \
  --export-to-all-namespaces --yes --namespace tap-install
tanzu package repository add tanzu-tap-repository \
  --url registry.tanzu.vmware.com/tanzu-application-platform/tap-packages:1.0.1 \
  --namespace tap-install
tanzu package repository get tanzu-tap-repository --namespace tap-install

while tanzu package repository get tanzu-tap-repository --namespace tap-install | grep "Reconcile succeeded" ; [ $? -ne 0 ]; do
	echo Tanzu Application Platform repo is not ready yet. Sleeping 60s
	sleep 60s
done

ytt -f tap-values.yaml -f values.yaml --ignore-unknown-comments > generated/tap-values.yaml

DEVELOPER_NAMESPACE=$(cat values.yaml  | grep developer_namespace | awk '/developer_namespace:/ {print $2}')
kubectl create ns $DEVELOPER_NAMESPACE

tanzu package install tap -p tap.tanzu.vmware.com -v 1.0.1 --values-file generated/tap-values.yaml -n tap-install

while kubectl get app tap -n tap-install | grep "Reconcile succeeded" ; [ $? -ne 0 ]; do
	echo Tanzu Application Platform is not ready yet. Sleeping 60s
	sleep 60s
done

if [ $(yq e .provider-config.dns $VALUES_YAML) = "gcloud-dns" ];
then

  while cat generated/keys/key.json 2> /dev/null | grep $PROJECT_ID >> /dev/null; [ $? -ne 0 ]; do
  	echo key.json file for gcloud-dns service account not created yet. Sleeping 60s
  	sleep 30s
  done
  kubectl create secret generic clouddns-dns01-solver-svc-acct -n cert-manager \
     --from-file=generated/keys/key.json
  
  ytt --ignore-unknown-comments -f values.yaml -f config/cert-ingress | kubectl apply -f-
  ytt --ignore-unknown-comments -f values.yaml -f config/gcloud/lets-encrypt-cluster-issuer.yaml | kubectl apply -f-

fi

if [ $(yq e .provider-config.dns $VALUES_YAML) = "aws" ];
then

  # install external dns
  kubectl create ns tanzu-system-ingress
  ytt --ignore-unknown-comments -f values.yaml -f config/aws | kubectl apply -f-
  ytt --ignore-unknown-comments -f values.yaml -f config/cert-ingress | kubectl apply -f-

fi

if [ $(yq e .provider-config.dns $VALUES_YAML) = "rfc2136" ] && [ $(yq e .provider-config.k8s $VALUES_YAML) == "tkgs" ];
then
  kubectl create clusterrolebinding default-tkg-admin-privileged-binding --clusterrole=psp:vmware-system-privileged --group=system:authenticated
  #prep external-dns
  ytt --ignore-unknown-comments -f values.yaml -f config/ad/external-dns/external-dns-ad-values.yaml  > generated/external-dns-ad-values.yaml
  #install external-dns
  kubectl apply -f config/ad/external-dns/external-dns-namespace-role.yaml
  kubectl create secret generic external-dns-data-values --from-file=values.yaml=generated/external-dns-ad-values.yaml -n tanzu-system-service-discovery
  kubectl apply -f config/ad/external-dns/external-dns-extension.yaml
  #create certs
  #root wildcard
  export ROOT_DOMAIN='*.'$(yq e .ingress.domain $VALUES_YAML)
  config/ad/cert-ingress/cert/req-cnf.sh $ROOT_DOMAIN ROOT_DOMAIN
  #learning-center wildcard
  export LC_DOMAIN='*.learning-center.'$(yq e .ingress.domain $VALUES_YAML)
  config/ad/cert-ingress/cert/req-cnf.sh $LC_DOMAIN LC_DOMAIN
  #cnr wildcard
  export CNR_DOMAIN='*.cnrs.'$(yq e .ingress.domain $VALUES_YAML)
  config/ad/cert-ingress/cert/req-cnf.sh $CNR_DOMAIN CNR_DOMAIN
  cp config/ad/cert-ingress/cert/req-cert.sh generated/certs/req-cert.sh
  export CA_SERVER=$(yq e .rfc2136.host $VALUES_YAML)
  sed -i -e "s~changeme-ca-server~$CA_SERVER~g" generated/certs/req-cert.sh
  export CERT_ROOT_CNF=generated/certs/ROOT_DOMAIN-req.cnf
  export CERT_ROOT_KEY=generated/certs/ROOT_DOMAIN.key
  export CERT_ROOT_PEM=generated/certs/ROOT_DOMAIN.pem

  export CERT_LC_CNF=generated/certs/LC_DOMAIN-req.cnf
  export CERT_LC_KEY=generated/certs/LC_DOMAIN.key
  export CERT_LC_PEM=generated/certs/LC_DOMAIN.pem

  export CERT_CNR_CNF=generated/certs/CNR_DOMAIN-req.cnf
  export CERT_CNR_KEY=generated/certs/CNR_DOMAIN.key
  export CERT_CNR_PEM=generated/certs/CNR_DOMAIN.pem
  # generate cert for root wildcard
  generated/certs/req-cert.sh ROOT_DOMAIN $(yq e .rfc2136.domain_user $VALUES_YAML) $(yq e .rfc2136.domain_user_pass $VALUES_YAML) $CERT_ROOT_CNF
  # generate cert for lc wildcard
  generated/certs/req-cert.sh LC_DOMAIN $(yq e .rfc2136.domain_user $VALUES_YAML) $(yq e .rfc2136.domain_user_pass $VALUES_YAML) $CERT_LC_CNF
  # generate cert for cnr wildcard
  generated/certs/req-cert.sh CNR_DOMAIN $(yq e .rfc2136.domain_user $VALUES_YAML) $(yq e .rfc2136.domain_user_pass $VALUES_YAML) $CERT_CNR_CNF
  
  #modify and apply certificate as secret
  cp config/ad/cert-ingress/cert/cert-secret.yaml generated/certs/cert-secret.yaml

  CERT_ROOT_KEY_B64=$(cat $CERT_ROOT_KEY|base64 -w 0)
  CERT_ROOT_PEM_B64=$(cat $CERT_ROOT_PEM|base64 -w 0)
  CERT_LC_KEY_B64=$(cat $CERT_ROOT_KEY|base64 -w 0)
  CERT_LC_PEM_B64=$(cat $CERT_ROOT_PEM|base64 -w 0)
  CERT_CNR_KEY_B64=$(cat $CERT_ROOT_KEY|base64 -w 0)
  CERT_CNR_PEM_B64=$(cat $CERT_ROOT_KEY|base64 -w 0)

  sed -i -e "s~change-me-secret-key1~$CERT_ROOT_KEY_B64~g" generated/certs/cert-secret.yaml
  sed -i -e "s~change-me-secret-crt1~$CERT_ROOT_PEM_B64~g" generated/certs/cert-secret.yaml
  sed -i -e "s~change-me-secret-key2~$CERT_LC_KEY_B64~g" generated/certs/cert-secret.yaml
  sed -i -e "s~change-me-secret-crt2~$CERT_LC_PEM_B64~g" generated/certs/cert-secret.yaml
  sed -i -e "s~change-me-secret-key3~$CERT_CNR_KEY_B64~g" generated/certs/cert-secret.yaml
  sed -i -e "s~change-me-secret-crt3~$CERT_CNR_PEM_B64~g" generated/certs/cert-secret.yaml
  ytt --ignore-unknown-comments -f values.yaml -f generated/certs/cert-secret.yaml | kubectl apply -f-
  ytt --ignore-unknown-comments -f values.yaml -f config/ad/cert-ingress/cert/tls-cert-delegation.yaml | kubectl apply -f-
  ytt --ignore-unknown-comments -f values.yaml -f config/ad/cert-ingress/ingress | kubectl apply -f-
fi

# configure developer namespace
export CONTAINER_REGISTRY_HOSTNAME=$(cat values.yaml | grep container_registry -A 3 | awk '/hostname:/ {print $2}')
export CONTAINER_REGISTRY_USERNAME=$(cat values.yaml | grep container_registry -A 3 | awk '/username:/ {print $2}')
export CONTAINER_REGISTRY_PASSWORD=$(cat values.yaml | grep container_registry -A 3 | awk '/password:/ {print $2}')
#tanzu secret registry add registry-credentials --username ${CONTAINER_REGISTRY_USERNAME} --password ${CONTAINER_REGISTRY_PASSWORD} --server ${CONTAINER_REGISTRY_HOSTNAME} --namespace ${DEVELOPER_NAMESPACE}
kubectl create secret docker-registry registry-credentials --docker-server=$CONTAINER_REGISTRY_HOSTNAME --docker-username=$CONTAINER_REGISTRY_USERNAME --docker-password=$CONTAINER_REGISTRY_PASSWORD -n $DEVELOPER_NAMESPACE
ytt --ignore-unknown-comments -f values.yaml -f config/dev-ns-prep | kubectl apply -f-

# configure 
ytt --ignore-unknown-comments -f values.yaml -f demo/tekton-pipeline.yaml | kubectl apply -f-
ytt --ignore-unknown-comments -f values.yaml -f demo/scan-policy.yaml | kubectl apply -f-
#ytt --ignore-unknown-comments -f values.yaml -f demo/rbmq-cluster.yaml | kubectl apply -f-