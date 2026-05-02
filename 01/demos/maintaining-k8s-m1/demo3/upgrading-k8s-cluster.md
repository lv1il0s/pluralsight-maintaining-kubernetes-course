### Part 1: Planning

# Check current node versions
k get nodes -o wide

# Check Kubernetes API server version
k version

# Verify pods are running and distributed across nodes
k get pods -o wide

# Check Pod Disruption Budgets that will protect during drain
k get pdb

### Part 2: Control Plane Upgrade

# SSH to control plane node
ssh -i keypair/k8s-cluster-key.pem ubuntu@<CONTROL_PLANE_IP>

# Backup etcd database before upgrade
sudo etcdctl snapshot save /home/ubuntu/etcd-snapshot-pre-upgrade-1.33.db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key

# Check current kubeadm version
kubeadm version

# Update package list
sudo apt-get update

# Check available kubeadm versions
apt-cache madison kubeadm

# Add Kubernetes 1.34 repository
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
  https://pkgs.k8s.io/core:/stable:/v1.34/deb/ /" | \
  sudo tee /etc/apt/sources.list.d/kubernetes-v1.34.list

# Update package list with new repository
sudo apt-get update

# Check available kubeadm versions again
apt-cache madison kubeadm

# Allow kubeadm to be upgraded
sudo apt-mark unhold kubeadm

# Install kubeadm 1.34.2
sudo apt-get install -y kubeadm=1.34.2-1.1

# Verify kubeadm upgraded
kubeadm version

# Prevent kubeadm from being auto-upgraded
sudo apt-mark hold kubeadm

# Preview upgrade plan
sudo kubeadm upgrade plan

# Verify cluster still on old version
k get nodes

# Upgrade control plane to 1.34.2
sudo kubeadm upgrade apply v1.34.2

# Verify pods still running
k get pods

# Check nodes (still shows 1.33 because kubelet not upgraded yet)
k get nodes

# Check API server version (now 1.34.2)
k version

# Allow kubelet and kubectl to be upgraded
sudo apt-mark unhold kubelet kubectl

# Install kubelet and kubectl 1.34.2
sudo apt-get install -y kubelet=1.34.2-1.1 kubectl=1.34.2-1.1

# Prevent kubelet and kubectl from being auto-upgraded
sudo apt-mark hold kubelet kubectl

# Reload systemd manager configuration
sudo systemctl daemon-reload

# Restart kubelet with new version
sudo systemctl restart kubelet

# Verify control plane node now shows 1.34.2
k get nodes

# Verify system pods are healthy
k get pods -n kube-system

### Part 3: Worker Node Upgrades (Worker 1)

# Show HA features before drain
k get pods -o wide  # Verify pods distributed across all 3 worker nodes
k get pdb           # Verify PodDisruptionBudgets in place

# Mark worker-1 as unschedulable
kubectl cordon k8s-worker-1

# Verify scheduling disabled
k get nodes

# Drain worker-1 (evict all pods)
kubectl drain k8s-worker-1 \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --timeout=120s

# Verify pods moved to other nodes (PDBs limiting eviction rate)
kubectl get pods -o wide

# Test app still works during maintenance
k port-forward svc/guestbook-frontend 8080:80
# Access http://localhost:8080 - app still fully operational!

# SSH to worker-1
ssh -i keypair/k8s-cluster-key.pem ubuntu@<WORKER_1_IP>

# Add Kubernetes 1.34 repository
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
  https://pkgs.k8s.io/core:/stable:/v1.34/deb/ /" | \
  sudo tee /etc/apt/sources.list.d/kubernetes-v1.34.list

# Update package list
sudo apt-get update

# Allow kubeadm to be upgraded
sudo apt-mark unhold kubeadm

# Install kubeadm 1.34.2
sudo apt-get install -y kubeadm=1.34.2-1.1

# Prevent kubeadm from being auto-upgraded
sudo apt-mark hold kubeadm

# Upgrade worker node configuration
sudo kubeadm upgrade node

# Allow kubelet and kubectl to be upgraded
sudo apt-mark unhold kubelet kubectl

# Install kubelet and kubectl 1.34.2
sudo apt-get install -y kubelet=1.34.2-1.1 kubectl=1.34.2-1.1

# Prevent kubelet and kubectl from being auto-upgraded
sudo apt-mark hold kubelet kubectl

# Reload systemd manager configuration
sudo systemctl daemon-reload

# Restart kubelet with new version
sudo systemctl restart kubelet

# Verify worker-1 upgraded to 1.34.2
k get nodes

# Mark worker-1 as schedulable again
k uncordon k8s-worker-1

### Part 3: Worker Node Upgrades (Worker 2)

# Mark worker-2 as unschedulable
k cordon k8s-worker-2

# Drain worker-2 (evict all pods)
kubectl drain k8s-worker-2 \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --timeout=120s

# Verify pods redistributed
k get pods -o wide

# SSH to worker-2 and repeat upgrade steps (same as worker-1)
# (Add repo, update, install kubeadm, upgrade node, install kubelet/kubectl, restart)

# Mark worker-2 as schedulable again
k uncordon k8s-worker-2

### Part 3: Worker Node Upgrades (Worker 3)

# Mark worker-3 as unschedulable
k cordon k8s-worker-3

# Drain worker-3 (evict all pods)
kubectl drain k8s-worker-3 \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --timeout=120s

# Verify pods redistributed
k get pods -o wide

# SSH to worker-3 and repeat upgrade steps (same as worker-1)
# (Add repo, update, install kubeadm, upgrade node, install kubelet/kubectl, restart)

# Mark worker-3 as schedulable again
k uncordon k8s-worker-3

### Part 4: Final Verification

# Verify all nodes upgraded to 1.34.2
k get nodes -o wide

# Verify all pods healthy and distributed
k get pods
k get pods -o wide

# Test application still works
k port-forward svc/guestbook-frontend 8080:80
# Access http://localhost:8080 - zero downtime achieved!

# Verify HA features protected us throughout
k get pdb  # PodDisruptionBudgets ensured gradual pod eviction
