# Platform — exposição via NodePort

Alguns serviços da plataforma são expostos via **NodePort** em portas fixas.

> **Princípio:** a exposição é **aditiva** — os Services originais de cada chart
> (ClusterIP) **não são alterados**. Para Prometheus, Grafana, OTel Collector,
> Gitea e Argo CD criamos um Service `NodePort` **adicional** apontando para os
> mesmos pods; para o Kafka adicionamos um **listener `nodeport`** ao CR (os
> listeners internos `plain`/`tls` continuam intactos).

## Tabela de portas

| Serviço | Origem (path) | Mecanismo | Porta no pod | NodePort | Acesso |
|---|---|---|---|---|---|
| **Grafana** | `platform/kube-prometheus-stack/stack` | Service NodePort extra | 3000 | **30030** | `http://<node-ip>:30030` (admin/admin no dev) |
| **Prometheus** | `platform/kube-prometheus-stack/stack` | Service NodePort extra | 9090 | **30090** | `http://<node-ip>:30090` |
| **OTel Collector — OTLP gRPC** | `platform/opentelemetry/instance` | Service NodePort extra | 4317 | **30317** | `<node-ip>:30317` |
| **OTel Collector — OTLP HTTP** | `platform/opentelemetry/instance` | Service NodePort extra | 4318 | **30318** | `http://<node-ip>:30318` |
| **Kafka — bootstrap externo** | `platform/kafka/instance` | listener `nodeport` (Strimzi) | 9094 | **30094** | `<node-ip>:30094` |
| **Kafka — broker N** | `platform/kafka/instance` | listener `nodeport` (Strimzi) | — | **30095 + N** | broker-0 `30095`, broker-1 `30096`, … |
| **Gitea (UI HTTP)** | `platform/gitea/app` | Service NodePort extra | 3000 | **30300** | `http://<node-ip>:30300` |
| **Argo CD (UI)** | `clusters/dev/argocd` | Service NodePort extra | 8080 | **30443** | `http://<node-ip>:30443` (server roda insecure → HTTP) |

> O Argo CD não fica em `platform/` (é a *engine*, vive em `clusters/<env>/argocd`),
> mas o NodePort dele está listado aqui para centralizar a referência.

## Como ligar/desligar e trocar portas

Cada componente tem um bloco em seu `values.yaml`:

```yaml
# Prometheus/Grafana — platform/kube-prometheus-stack/stack/values.yaml
nodePorts:
  enabled: true
  grafana: 30030
  prometheus: 30090

# OTel — platform/opentelemetry/instance/values.yaml
nodePort:
  enabled: true
  grpc: 30317
  http: 30318

# Gitea — platform/gitea/app/values.yaml
nodePort:
  enabled: true
  http: 30300

# Kafka — platform/kafka/instance/values.yaml
external:
  enabled: true
  bootstrapNodePort: 30094
  brokerNodePortBase: 30095   # broker-N -> base + N

# Argo CD — clusters/dev/argocd/values.yaml
nodePort:
  enabled: true
  http: 30443
```

Para desligar a exposição de um serviço, basta `enabled: false`.

## Acesso a partir do host (kind)

NodePorts ficam abertos na interface dos **nós** do cluster. Em `kind`, os nós são
containers Docker, então para alcançar essas portas **de fora do host** é preciso
publicá-las no `kind-config.yaml` via `extraPortMappings`, por exemplo:

```yaml
  extraPortMappings:
    - { containerPort: 30030, hostPort: 30030, protocol: TCP }  # grafana
    - { containerPort: 30090, hostPort: 30090, protocol: TCP }  # prometheus
    - { containerPort: 30443, hostPort: 30443, protocol: TCP }  # argocd
    # ... demais portas conforme necessário
```

Sem `extraPortMappings`, as NodePorts continuam acessíveis de dentro do host
(via IP do container do nó / `docker inspect`) ou por `kubectl port-forward`.
