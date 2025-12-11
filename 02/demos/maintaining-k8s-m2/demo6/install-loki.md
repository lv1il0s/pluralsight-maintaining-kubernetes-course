### Install Loki and Grafana Alloy

# Add Grafana Helm repository
helm repo add grafana https://grafana.github.io/helm-charts

# Update Helm repositories
helm repo update

# Install Loki with custom values
helm install loki grafana/loki \
    --namespace monitoring \
    --values monitoring/loki-values.yaml

# Install Grafana Alloy (log collector)
helm install alloy grafana/alloy \
    --namespace monitoring \
    --values monitoring/alloy-values.yaml

# Verify Loki and Alloy pods running
k get pods -n monitoring

### Deploy Application with Structured Logging

# Upgrade guestbook with structured logging enabled
helm upgrade guestbook ./guestbook

# Verify pods running
k get pods

# Port-forward frontend to generate logs
k port-forward svc/guestbook-frontend 8080:80

# Click buttons in app to generate log events

### Configure Loki in Grafana

# Port-forward Grafana
k port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80

# Access Grafana at: http://localhost:3000/dashboards
