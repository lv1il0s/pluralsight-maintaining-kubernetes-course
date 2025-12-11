
# Add Prometheus Helm repository
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts

# Update Helm repositories
helm repo update

# Create monitoring namespace
k create namespace monitoring

# Install kube-prometheus-stack (Prometheus + Grafana + exporters)
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false

### Access Grafana

# Get Grafana admin password
kubectl get secret --namespace monitoring kube-prometheus-stack-grafana -o jsonpath="{.data.admin-password}" | base64 --decode

# Port-forward Grafana (login: admin + password from above)
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80

# Access Grafana at: http://localhost:3000/login


### Deploy Application with Metrics

# Upgrade guestbook with Prometheus metrics enabled
helm upgrade guestbook ./guestbook

# Verify pods running
k get pods

# Verify ServiceMonitor created
k get servicemonitor

### Access Application and Metrics

# Port-forward frontend application
k port-forward svc/guestbook-frontend 8080:80

# Port-forward backend metrics endpoint
k port-forward svc/guestbook-backend 5001:5000

# Access metrics at: http://localhost:5001/metrics

# Port-forward Prometheus UI
k port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090

# Access Prometheus at: http://localhost:9090/query


