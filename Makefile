.DEFAULT_GOAL := help

ENV ?= dev
ARGOCD_NAMESPACE ?= argocd
KIND_CLUSTER ?= gitops-$(ENV)
KCTX := kind-$(KIND_CLUSTER)
KUBECTL := kubectl --context $(KCTX)

# Helm repositories used by the vendored umbrella charts.
define HELM_REPOS
helm repo add jetstack https://charts.jetstack.io ;\
helm repo add cnpg https://cloudnative-pg.github.io/charts ;\
helm repo add strimzi https://strimzi.io/charts/ ;\
helm repo add flink-operator https://downloads.apache.org/flink/flink-kubernetes-operator-1.15.0/ ;\
helm repo add jaegertracing https://jaegertracing.github.io/helm-charts ;\
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts ;\
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts ;\
helm repo add gitea-charts https://dl.gitea.com/charts/ ;\
helm repo add argo https://argoproj.github.io/argo-helm ;\
helm repo update
endef

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

.PHONY: vendor
vendor: ## Download (vendor) all upstream charts into each chart's charts/ dir
	@$(HELM_REPOS)
	@for d in $$(find platform clusters -name Chart.yaml -exec dirname {} \;); do \
		if grep -q '^dependencies:' $$d/Chart.yaml; then \
			echo ">> vendoring $$d"; \
			ok=0; \
			for try in 1 2 3 4 5; do \
				if helm dependency build $$d; then ok=1; break; fi; \
				echo "   retry $$try (github release-assets podem dar timeout)"; sleep 3; \
			done; \
			[ $$ok -eq 1 ] || { echo "FALHOU: $$d"; exit 1; }; \
		fi; \
	done
	@echo "Done. Commit the generated charts/*.tgz and Chart.lock files."

.PHONY: lint
lint: ## Helm-template every component for all environments (no cluster needed)
	@for cfg in $$(find platform -name config.json); do \
		d=$$(dirname $$cfg); \
		for e in dev qa prod; do \
			echo ">> $$d ($$e)"; \
			helm template test $$d -f $$d/values.yaml -f $$d/values-$$e.yaml >/dev/null || exit 1; \
		done; \
	done
	@echo "All components render."

.PHONY: kind-up
kind-up: ## Create the kind cluster for ENV (dev/qa/prod)
	kind create cluster --name $(KIND_CLUSTER) --config kind/$(ENV).yaml

.PHONY: kind-down
kind-down: ## Delete the kind cluster for ENV
	kind delete cluster --name $(KIND_CLUSTER)

.PHONY: argocd-install
argocd-install: ## Install Argo CD from the vendored chart (matches what Git will self-manage)
	$(KUBECTL) create namespace $(ARGOCD_NAMESPACE) --dry-run=client -o yaml | $(KUBECTL) apply -f -
	helm dependency build clusters/$(ENV)/argocd
	helm --kube-context $(KCTX) upgrade --install argocd clusters/$(ENV)/argocd -n $(ARGOCD_NAMESPACE) -f clusters/$(ENV)/argocd/values.yaml
	$(KUBECTL) -n $(ARGOCD_NAMESPACE) rollout status deploy/argocd-server --timeout=300s

.PHONY: bootstrap
bootstrap: ## Apply the root app-of-apps for ENV (hands everything over to GitOps)
	$(KUBECTL) apply -f clusters/$(ENV)/bootstrap/root.yaml

.PHONY: argocd-password
argocd-password: ## Print the initial Argo CD admin password
	$(KUBECTL) -n $(ARGOCD_NAMESPACE) get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo

.PHONY: argocd-ui
argocd-ui: ## Port-forward the Argo CD UI to https://localhost:8080
	$(KUBECTL) -n $(ARGOCD_NAMESPACE) port-forward svc/argocd-server 8080:443
