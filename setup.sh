#!/usr/bin/env bash
# Bring up the demo service on a local kind cluster.
# Idempotent: a second run must exit 0.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_NAME="demo"
NAMESPACE="demo"
RELEASE="demo"
IMAGE_REPO="demo-service"
IMAGE_TAG="1.0.0"
IMAGE="${IMAGE_REPO}:${IMAGE_TAG}"
INGRESS_MANIFEST="https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.15.1/deploy/static/provider/kind/deploy.yaml"

log() { printf '==> %s\n' "$*"; }

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

need docker
need kind
need kubectl
need helm

if ! kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  log "creating kind cluster ${CLUSTER_NAME}"
  kind create cluster --name "${CLUSTER_NAME}" --config - <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: demo
nodes:
  - role: control-plane
    extraPortMappings:
      - containerPort: 80
        hostPort: 80
        protocol: TCP
      - containerPort: 443
        hostPort: 443
        protocol: TCP
EOF
else
  log "reusing kind cluster ${CLUSTER_NAME}"
fi

kind export kubeconfig --name "${CLUSTER_NAME}"
kubectl config use-context "kind-${CLUSTER_NAME}"

log "installing ingress-nginx"
# Admission Jobs are immutable and use ttlSecondsAfterFinished: 0.
# Drop leftovers so a second apply can recreate them instead of failing.
# The namespace does not exist on the first run, so a missing delete is fine.
kubectl delete job -n ingress-nginx \
  ingress-nginx-admission-create \
  ingress-nginx-admission-patch \
  --ignore-not-found >/dev/null 2>&1 || true
kubectl apply -f "${INGRESS_MANIFEST}"

log "waiting for ingress-nginx"
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=240s

log "building ${IMAGE}"
docker build -t "${IMAGE}" "${ROOT}/service"

log "loading ${IMAGE} into kind"
kind load docker-image "${IMAGE}" --name "${CLUSTER_NAME}"

log "installing helm release ${RELEASE} into namespace ${NAMESPACE}"
# The admission webhook can lag the Ready condition on a cold cluster.
attempt=1
until helm upgrade --install "${RELEASE}" "${ROOT}/chart" \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  --set "image.repository=${IMAGE_REPO}" \
  --set "image.tag=${IMAGE_TAG}" \
  --wait \
  --timeout 180s
do
  if [ "${attempt}" -ge 5 ]; then
    echo "helm upgrade failed after ${attempt} attempts" >&2
    exit 1
  fi
  log "helm upgrade failed (attempt ${attempt}); retrying in 15s"
  attempt=$((attempt + 1))
  sleep 15
done

log "setup complete"
kubectl -n "${NAMESPACE}" get deploy,svc,ingress,pods
