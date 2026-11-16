ELASTIC_VERSION ?= 9.5.6
# Upstream OpenTelemetry Collector (contrib) used by the agent and cluster collectors.
OTEL_VERSION ?= 0.139.0
SET_VERSION = sed -e 's/$${ELASTIC_VERSION}/$(ELASTIC_VERSION)/g' -e 's/$${OTEL_VERSION}/$(OTEL_VERSION)/g'

ingress-controller:
	helm repo add traefik https://traefik.github.io/charts
	helm repo update
	helm upgrade --install traefik traefik/traefik -n traefik --create-namespace

eck:
	helm repo add elastic https://helm.elastic.co
	helm repo update
	helm upgrade --install elastic-operator elastic/eck-operator -n elastic-system --create-namespace \
		--set image.repository=elastic/eck-operator \
		--set image.tag=3.5.0

elastic-stack:
	kubectl create secret generic training-user --from-literal username=training --from-literal password=nonprodpwd --from-literal roles=superuser || true
	$(SET_VERSION) k8s/elastic-stack.yaml | kubectl apply -f -

ELASTIC_ENDPOINT ?= https://elasticsearch-es-http.default.svc:9200

# Gateway: Deployment that owns the connection to Elastic (logs in as the elastic user; the
# password is copied from the ECK-generated secret). Receives OTLP from the demo and the agents.
otel-gateway:
	kubectl wait --for=create secret/elasticsearch-es-elastic-user --timeout=300s
	kubectl create namespace otel || true
	kubectl create secret generic elastic-secret-otel -n otel \
		--from-literal=elastic_endpoint='$(ELASTIC_ENDPOINT)' \
		--from-literal=elastic_password="$$(kubectl get secret elasticsearch-es-elastic-user -o go-template='{{.data.elastic | base64decode}}')" \
		--dry-run=client -o yaml | kubectl apply -f -
	kubectl create configmap otel-gateway-config -n otel \
		--from-file=config.yaml=otel-gateway-config.yaml \
		--dry-run=client -o yaml | kubectl apply -f -
	$(SET_VERSION) k8s/otel-gateway.yaml | kubectl apply -f -
	kubectl -n otel rollout restart deploy/otel-gateway

# Agent: DaemonSet collecting Kubernetes and host metrics, forwarding to the gateway over OTLP/gRPC.
otel-agent:
	kubectl create namespace otel || true
	kubectl create configmap otel-agent-config -n otel \
		--from-file=config.yaml=otel-agent-config.yaml \
		--dry-run=client -o yaml | kubectl apply -f -
	$(SET_VERSION) k8s/otel-agent.yaml | kubectl apply -f -
	kubectl -n otel rollout restart ds/otel-agent

# Cluster receiver: single-replica Deployment running k8s_cluster (node conditions, allocatable
# resources, ...). Must not be scaled or run per node, or the metrics get duplicated.
otel-cluster:
	kubectl create namespace otel || true
	kubectl create configmap otel-cluster-config -n otel \
		--from-file=config.yaml=otel-cluster-config.yaml \
		--dry-run=client -o yaml | kubectl apply -f -
	$(SET_VERSION) k8s/otel-cluster.yaml | kubectl apply -f -
	kubectl -n otel rollout restart deploy/otel-cluster

otel-collector: otel-gateway otel-agent otel-cluster

# OpenTelemetry Demo, sending all telemetry to the collector in the otel namespace.
otel-demo:
	helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
	helm repo update
	helm upgrade --install otel-demo open-telemetry/opentelemetry-demo -n otel-demo --create-namespace \
		-f k8s/otel-demo-values.yaml
	kubectl apply -f k8s/otel-demo-ingress.yaml

all: ingress-controller eck elastic-stack otel-collector otel-demo
