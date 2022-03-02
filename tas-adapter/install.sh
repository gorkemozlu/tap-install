#!/bin/bash
mkdir -p generated
export VALUES_YAML=values.yaml
if [ $(yq e .provider-config.dns $VALUES_YAML) = "rfc2136" ] && [ $(yq e .provider-config.k8s $VALUES_YAML) == "tkgs" ];
then
  # certs
  #tas-adapter wildcard
  export TAS_ADAPTER_DOMAIN='*.tas-adapter.'$(yq e .ingress.domain $VALUES_YAML)
  additonal-ingress-config/ad/cert-ingress/cert/req-cnf.sh $TAS_ADAPTER_DOMAIN TAS_ADAPTER_DOMAIN
  export CERT_TAS_CNF=generated/certs/TAS_ADAPTER_DOMAIN-req.cnf
  export CERT_TAS_KEY=generated/certs/TAS_ADAPTER_DOMAIN.key
  export CERT_TAS_PEM=generated/certs/TAS_ADAPTER_DOMAIN.pem
  cp additonal-ingress-config/ad/cert-ingress/cert/req-cert.sh generated/certs/req-cert.sh
  export CA_SERVER=$(yq e .rfc2136.host $VALUES_YAML)
  sed -i -e "s~changeme-ca-server~$CA_SERVER~g" generated/certs/req-cert.sh
  # generate cert for lc wildcard
  generated/certs/req-cert.sh TAS_ADAPTER_DOMAIN $(yq e .rfc2136.domain_user $VALUES_YAML) $(yq e .rfc2136.domain_user_pass $VALUES_YAML) $CERT_TAS_CNF
  #modify and apply certificate as secret
  cp additonal-ingress-config/ad/cert-ingress/cert/cert-secret.yaml generated/certs/cert-secret.yaml
  CERT_ROOT_KEY_B64=$(cat $CERT_TAS_KEY|base64 -w 0)
  CERT_ROOT_PEM_B64=$(cat $CERT_TAS_PEM|base64 -w 0)
  sed -i -e "s~change-me-secret-key1~$CERT_ROOT_KEY_B64~g" generated/certs/cert-secret.yaml
  sed -i -e "s~change-me-secret-crt1~$CERT_ROOT_PEM_B64~g" generated/certs/cert-secret.yaml
  ytt --ignore-unknown-comments -f values.yaml -f generated/certs/cert-secret.yaml | kubectl apply -f-
  ytt --ignore-unknown-comments -f values.yaml -f config/ad/cert-ingress/cert/tls-cert-delegation.yaml | kubectl apply -f-
fi

if [ $(yq e .provider-config.dns $VALUES_YAML) = "gcloud-dns" ] && [ $(yq e .provider-config.k8s $VALUES_YAML) == "tkgm" ];
then
ytt --ignore-unknown-comments -f values.yaml -f additonal-ingress-config/cert-manager | kubectl apply -f-
fi
sudo wget -O /etc/yum.repos.d/cloudfoundry-cli.repo https://packages.cloudfoundry.org/fedora/cloudfoundry-cli.repo
sudo yum install cf8-cli
cf version

kubectl create ns tas-adapter-install

export INSTALL_REGISTRY_HOSTNAME=registry.tanzu.vmware.com
export INSTALL_REGISTRY_USERNAME=$(cat values.yaml | grep tanzunet -A 3 | awk '/username:/ {print $2}')
export INSTALL_REGISTRY_PASSWORD=$(cat values.yaml  | grep tanzunet -A 3 | awk '/password:/ {print $2}')
tanzu secret registry add tap-registry \
  --username ${INSTALL_REGISTRY_USERNAME} --password ${INSTALL_REGISTRY_PASSWORD} \
  --server ${INSTALL_REGISTRY_HOSTNAME} \
  --namespace tas-adapter-install

tanzu package repository add tas-adapter-repository \
  --url registry.tanzu.vmware.com/app-service-adapter/tas-adapter-package-repo:0.3.0 \
  --namespace tas-adapter-install
ytt -f tas-adapter-values.yaml -f values.yaml --ignore-unknown-comments > generated/tas-adapter-values.yaml
tanzu package install tas-adapter \
  --package-name application-service-adapter.tanzu.vmware.com \
  --version 0.3.0 \
  --values-file generated/tas-adapter-values.yaml \
  --namespace tas-adapter-install

while kubectl get app application-service-adapter -n tas-adapter-install | grep "Reconcile succeeded" ; [ $? -ne 0 ]; do
	echo Tanzu Application Service Adapter is not ready yet. Sleeping 60s
	sleep 60s
done


# Due to a bug with the ordering of files in ytt version 0.38.0, the schema override doesn't work and we have to specific the full schema in the schema-overlay.yaml before the override as a workaround!
kubectl create secret generic ingress-overlay --from-file=ingress-secret-name-overlay.yaml=overlays/tas-adapter/ingress-overlay.yaml --from-file=overlays/tas-adapter/configuration-overlay.yaml --from-file=schema-overlay.yaml=overlays/tas-adapter/schema-overlay.yaml -n tas-adapter-install
kubectl annotate packageinstalls tas-adapter -n tas-adapter-install ext.packaging.carvel.dev/ytt-paths-from-secret-name.0=ingress-overlay

# Delete cf-k8s-controllers-controller-manager pod so that configuration changes take effect 
INGRESS_SECRET=$(cat values.yaml  | grep ingress -A 3 | awk '/contour_tls_secret:/ {print $2}')
OVERRIDEN_CONFIG=$(kubectl get cm cf-k8s-controllers-config -n cf-k8s-controllers-system -o jsonpath='{.data}')
until grep -q "$INGRESS_SECRET" <<< "$OVERRIDEN_CONFIG";
do
  echo "Waiting until config override happend ..."
  sleep 1
  OVERRIDEN_CONFIG=$(kubectl get cm cf-k8s-controllers-config -n cf-k8s-controllers-system -o jsonpath='{.data}')
done
kubectl delete pods -l control-plane=controller-manager -n cf-k8s-controllers-system