# GitOps Platform

Repositório GitOps que entrega um conjunto de ferramentas de plataforma via
**Argo CD**. Dois caminhos de uso:

- **`default`** — env-agnóstico, usa **só o `values.yaml`** de cada componente.
  Ideal para subir um cluster zerado num comando (`bootstrap.sh`).
- **`dev` / `qa` / `prod`** — os mesmos charts com overlay `values-<env>.yaml`.

> Os mesmos charts rodam em todos os caminhos. A única coisa que muda é qual
> `values` é aplicado: só `values.yaml` (default) ou `values.yaml` +
> `values-<env>.yaml` (por ambiente).

---

## Setup rápido (curl one-shot)

Pré-requisitos na máquina: `git`, `helm`, `kubectl`, e um **kubeconfig já
apontando para o cluster alvo** (o script usa o `current-context`, não força o
kind).

```bash
curl -fsSL https://raw.githubusercontent.com/nochaosio/gitops/main/bootstrap.sh | bash
```

O `bootstrap.sh` faz, contra o current-context:

1. `git clone` do repo (público).
2. `helm upgrade --install argocd clusters/default/argocd` (chart vendorizado).
3. `kubectl apply -f clusters/default/bootstrap/root.yaml`.
4. O Argo CD assume e instala a plataforma inteira usando **só `values.yaml`**.

Variáveis opcionais: `REPO_URL`, `REPO_REF` (default `main`), `ARGOCD_NS`
(default `argocd`).

---

## Setup por ambiente (dev / qa / prod, local com kind)

```bash
make vendor               # venda os charts upstream (uma vez)
make kind-up ENV=dev      # cria o cluster kind
make argocd-install ENV=dev
make bootstrap ENV=dev    # aplica o root app-of-apps do ambiente
make argocd-password      # senha inicial do admin
make argocd-ui            # UI em https://localhost:8080 (user: admin)
```

> Ajuste o `repoURL` nos arquivos de `clusters/` para o seu remote Git
> (default: `https://github.com/nochaosio/gitops.git`).

---

## Como funciona

```
Operador  →  helm install argocd  +  kubectl apply root.yaml   (1x por cluster)
              │
Argo CD   →  sincroniza clusters/<path>/bootstrap/apps:
              ├── argocd.yaml          self-manage (upgrades viram git push)
              ├── platform-project.yaml AppProject
              └── platform-appset.yaml  ApplicationSet
                       │
ApplicationSet → git generator varre platform/*/*/config.json
                 e gera 1 Application por componente (fan-out, sem lista manual).
```

- **`<path>`** é `default`, `dev`, `qa` ou `prod` (em `clusters/`).
- O `root.yaml` é o **único manifesto aplicado à mão** (o `bootstrap.sh`
  automatiza isso no caminho `default`).
- A Application `argocd` usa `prune: false` de propósito (evita o Argo CD se
  auto-deletar com config quebrada).

### Sync waves (ordenação)

O campo `syncWave` do `config.json` vira a annotation `argocd.argoproj.io/sync-wave`:

| Wave | O quê |
|---|---|
| `-2` | **cert-manager** (antes dos webhooks dos operators) |
| `0`  | **operators** (instalam os CRDs) |
| `1`  | **charts standalone** (kube-prometheus-stack, gitea) |
| `2`  | **instâncias** (CRs que dependem dos CRDs) |

Não há ordenação estrita entre Applications: cada uma tem `retry` + `selfHeal`,
então um CR que sincronize antes do CRD apenas re-tenta. Sistema
**eventualmente consistente**.

---

## Estrutura do repositório

```
.
├── bootstrap.sh                      # one-shot do caminho default
├── clusters/                         # a engine (Argo CD) + bootstrap, por caminho
│   ├── default/                      #   env-agnóstico: appset usa só values.yaml
│   ├── dev/  qa/  prod/              #   por ambiente: + values-<env>.yaml (prod = HA)
│   │   ├── argocd/                   #   umbrella chart do Argo CD (vendored) + values
│   │   └── bootstrap/
│   │       ├── root.yaml             #   app-of-apps raiz
│   │       └── apps/                 #   argocd.yaml + platform-project + platform-appset
│
├── platform/                         # as workloads (charts + values), 1 pasta = 1 App
│   ├── cert-manager/operator/
│   ├── postgres/{operator,instance}/
│   ├── kafka/{operator,instance}/
│   ├── flink/{operator,instance}/
│   ├── jaeger/{operator,instance}/
│   ├── opentelemetry/{operator,instance}/
│   ├── kube-prometheus-stack/stack/
│   └── gitea/app/
│
├── kind/{dev,qa,prod}.yaml           # clusters locais (3 / 4 / 5 workers)
└── Makefile                          # vendor / lint / kind / argocd
```

### Anatomia de um componente

Cada diretório-folha em `platform/<tool>/<component>/` é **uma Application**:

| Arquivo | Função |
|---|---|
| `config.json` | Metadados lidos pelo ApplicationSet: `name`, `tool`, `namespace`, `syncWave`. |
| `Chart.yaml` | Umbrella com dependência do chart upstream (operators) ou chart local com CRs (instances). |
| `values.yaml` | Defaults auto-suficientes — **é o que o caminho `default` usa sozinho**. |
| `values-<env>.yaml` | Overrides de dev/qa/prod (HA, storage, retenção, réplicas). |
| `templates/` | Só nos *instances* — contém os CRs aplicados pelo operator. |

---

## Ferramentas instaladas

Onde há operator, seguimos o fluxo do operator (operator + instância como
Applications separadas).

| Ferramenta | Operator (chart) | Instância (CR) | Namespace |
|---|---|---|---|
| **PostgreSQL** | `cloudnative-pg` | `Cluster` | `postgres` |
| **Apache Kafka (KRaft)** | `strimzi-kafka-operator` | `Kafka` + `KafkaNodePool` | `kafka` |
| **Apache Flink** | `flink-kubernetes-operator` | `FlinkDeployment` (session) | `flink` |
| **Jaeger** | `jaeger-operator` | `Jaeger` | `jaeger` |
| **OpenTelemetry** | `opentelemetry-operator` | `OpenTelemetryCollector` | `opentelemetry` |
| **kube-prometheus-stack** | inclui o `prometheus-operator` | — (o próprio chart) | `monitoring` |
| **Gitea** | sem operator → Helm chart | — | `gitea` |
| **cert-manager** | `cert-manager` (pré-requisito) | — | `cert-manager` |

Cada ferramenta vive no seu namespace, criado por `CreateNamespace=true`.

---

## Charts vendored

Os charts upstream são vendados para o `charts/` de cada umbrella, então o
cluster não acessa repositórios Helm públicos durante o sync.

```bash
make vendor   # helm repo add + helm dependency build; commite charts/*.tgz e Chart.lock
```

| Componente | Chart | Versão | Repositório |
|---|---|---|---|
| cert-manager | `cert-manager` | `v1.16.2` | charts.jetstack.io |
| postgres/operator | `cloudnative-pg` | `0.23.0` | cloudnative-pg.github.io/charts |
| kafka/operator | `strimzi-kafka-operator` | `0.45.0` | strimzi.io/charts |
| flink/operator | `flink-kubernetes-operator` | `1.15.0` | downloads.apache.org/flink |
| jaeger/operator | `jaeger-operator` | `2.57.0` | jaegertracing.github.io/helm-charts |
| opentelemetry/operator | `opentelemetry-operator` | `0.74.0` | open-telemetry.github.io |
| kube-prometheus-stack | `kube-prometheus-stack` | `67.5.0` | prometheus-community.github.io |
| gitea | `gitea` | `11.0.1` | dl.gitea.com/charts |
| argo-cd | `argo-cd` | `7.7.0` | argoproj.github.io/argo-helm |

---

## Diferenças por ambiente (overlays `values-<env>.yaml`)

| Componente | dev | qa | prod |
|---|---|---|---|
| Postgres | 1 instância | 2 instâncias, 10Gi | 3 instâncias, 50Gi |
| Kafka | 1 broker, RF=1 | 2 brokers, RF=2 | 3 brokers, RF=3, minISR=2 |
| Flink | 2 task slots | 4 slots, 2 TMs | 4 slots, 3 TMs |
| Jaeger | allInOne/memory | allInOne/memory | production/badger |
| OTel Collector | 1 réplica | 1 réplica | 2 réplicas |
| kube-prometheus-stack | retenção 2d | retenção 5d | retenção 30d, 2 réplicas, 50Gi |
| cert-manager | 1 réplica | 1 réplica | 2 réplicas |
| Gitea | 1 réplica | 1 réplica | 2 réplicas, 20Gi |

O caminho `default` ignora esses overlays e usa só o `values.yaml`.

---

## Targets do Makefile

| Target | O que faz |
|---|---|
| `make vendor` | `helm repo add` + `helm dependency build` em todos os componentes. |
| `make lint` | `helm template` em todo componente para dev/qa/prod (sem cluster). |
| `make kind-up` / `kind-down` | Cria / destrói o cluster kind. |
| `make argocd-install ENV=<env>` | Instala o Argo CD a partir do chart vendored. |
| `make bootstrap ENV=<env>` | Aplica o root app-of-apps do ambiente. |
| `make argocd-password` | Imprime a senha inicial do admin. |
| `make argocd-ui` | Port-forward da UI para `https://localhost:8080`. |

---

## Como adicionar uma nova ferramenta

1. Crie `platform/<tool>/<component>/` (ex.: `platform/redis/operator/`).
2. Adicione `config.json` (`name`, `tool`, `namespace`, `syncWave`).
3. Adicione `Chart.yaml` (dependência upstream, ou chart local + `templates/`).
4. Adicione `values.yaml` (auto-suficiente) e os `values-<env>.yaml`.
5. `make vendor` (se tem dependência) e commit.

Todos os caminhos (default + dev/qa/prod) passam a gerenciar o componente
automaticamente, sem editar o bootstrap.

---

## Pontos de atenção

- **`repoURL`** precisa apontar para o seu remote real (em `clusters/*` e `bootstrap.sh`).
- **Versões dos charts** são pontos de partida — verifique antes de produção.
- **Repos privados:** o Argo CD precisa de um `Secret` repo-credential (label
  `argocd.argoproj.io/secret-type: repository`). Nunca commite em texto puro —
  use Sealed Secrets, SOPS ou External Secrets.
- **Jaeger em prod** com storage `badger` é placeholder; aponte para um backend
  real (Elasticsearch/Cassandra).
- **Gitea** está self-contained (SQLite + cache/queue em memória); para produção
  troque por Postgres externo (pode usar o CloudNativePG deste repo) e Redis/Valkey.
