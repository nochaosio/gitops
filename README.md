# GitOps Platform

Um comando sobe o Argo CD, que instala toda a plataforma a partir do Git.

## Setup (curl)

Pré-requisitos: `git`, `helm`, `kubectl` e um kubeconfig no cluster alvo.

```bash
curl -fsSL https://raw.githubusercontent.com/nochaosio/gitops/main/bootstrap.sh | bash
```

## Setup por ambiente (kind)

```bash
make vendor               # baixa os charts upstream (uma vez)
make kind-up ENV=dev      # cria o cluster kind
make argocd-install ENV=dev
make bootstrap ENV=dev    # aplica o root app-of-apps
make argocd-password      # senha inicial do admin
make argocd-ui            # UI em https://localhost:8080 (user: admin)
```

## Ferramentas

PostgreSQL (cloudnative-pg), Kafka (strimzi), Flink, Jaeger, OpenTelemetry,
kube-prometheus-stack, Gitea, cert-manager. Cada uma é uma App gerada pelo
ApplicationSet a partir de `platform/*/*/config.json`.
</content>
