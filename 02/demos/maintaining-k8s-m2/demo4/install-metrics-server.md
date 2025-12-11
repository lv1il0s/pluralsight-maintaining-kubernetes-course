# Add Metrics Server Helm repository
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/

# Update Helm repositories
helm repo update

# Install Metrics Server with kubelet insecure TLS flag
helm install metrics-server metrics-server/metrics-server \
  --namespace kube-system \
  --set 'args[0]=--kubelet-insecure-tls'

# Verify Metrics Server pod is running
k get pods -n kube-system -l app.kubernetes.io/name=metrics-server

# Show node-level CPU and memory metrics
k top nodes

# Show pod-level CPU and memory metrics
k top pods
