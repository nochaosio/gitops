#!/usr/bin/env bash
# One-shot bootstrap: instala o Argo CD e entrega o cluster ao GitOps usando o
# caminho "default" (env-agnóstico, apenas values.yaml de cada componente).
#
# Uso:
#   curl -fsSL https://raw.githubusercontent.com/nochaosio/gitops/main/bootstrap.sh | bash
#
# Pré-requisitos: git, helm e kubectl no PATH, e um kubeconfig já apontando para
# o cluster alvo (current-context). NÃO força o contexto do kind — usa o atual.
#
# Variáveis de ambiente (opcionais):
#   REPO_URL      repo a clonar          (default: https://github.com/nochaosio/gitops.git)
#   REPO_REF      branch/tag/commit      (default: main)
#   ARGOCD_NS     namespace do Argo CD   (default: argocd)
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/nochaosio/gitops.git}"
REPO_REF="${REPO_REF:-main}"
ARGOCD_NS="${ARGOCD_NS:-argocd}"

log() { printf '\033[36m>> %s\033[0m\n' "$*"; }
die() { printf '\033[31mERRO: %s\033[0m\n' "$*" >&2; exit 1; }

for bin in git helm kubectl; do
  command -v "$bin" >/dev/null 2>&1 || die "'$bin' não encontrado no PATH."
done

CTX="$(kubectl config current-context 2>/dev/null)" || die "Nenhum current-context no kubeconfig."
kubectl cluster-info >/dev/null 2>&1 || die "Não consegui falar com o cluster (context: $CTX)."
log "Cluster alvo (current-context): $CTX"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
log "Clonando $REPO_URL ($REPO_REF)"
git clone --depth 1 --branch "$REPO_REF" "$REPO_URL" "$WORKDIR/repo"
cd "$WORKDIR/repo"

log "Instalando Argo CD (chart vendorizado: clusters/default/argocd)"
kubectl create namespace "$ARGOCD_NS" --dry-run=client -o yaml | kubectl apply -f -
helm dependency build clusters/default/argocd
helm upgrade --install argocd clusters/default/argocd \
  -n "$ARGOCD_NS" -f clusters/default/argocd/values.yaml
kubectl -n "$ARGOCD_NS" rollout status deploy/argocd-server --timeout=300s

log "Aplicando o root app-of-apps (default) — entregando tudo ao GitOps"
kubectl apply -f clusters/default/bootstrap/root.yaml

printf '\n\033[32mPronto.\033[0m O Argo CD agora sincroniza a plataforma a partir do Git.\n'
cat <<EOF
Acompanhe os apps:   kubectl -n $ARGOCD_NS get applications -w
Senha inicial admin: kubectl -n $ARGOCD_NS get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
UI (port-forward):   kubectl -n $ARGOCD_NS port-forward svc/argocd-server 8080:443
EOF
