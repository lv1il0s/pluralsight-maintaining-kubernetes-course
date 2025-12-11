# AWS Kubernetes Cluster Setup Guide

**Purpose**: Production-like kubeadm cluster for course demonstrations
**Last Updated**: December 3, 2025
**AWS Region**: us-east-1
**Kubernetes Version**: 1.33.6
**Time to Build**: ~30 minutes from scratch

---

## Current Cluster Status

**Infrastructure**:
- 4× EC2 instances (t3.medium: 2vCPU, 4GB RAM, 20GB gp3 storage)
- Ubuntu 24.04 LTS
- Kubernetes 1.33.6 (kubeadm)
- Container runtime: containerd 1.7.28
- CNI: Calico v3.29.1
- Storage: AWS EBS CSI Driver

**Control Plane**:
- **Elastic IP**: 35.174.232.81 (static - never changes)
- Private IP: 172.31.94.146 (current, changes on rebuild)
- Hostname: ip-172-31-94-146 (AWS default)

**Workers**:
- worker-1: 13.222.207.54 (public), 172.31.84.108 (private)
- worker-2: 3.235.242.134 (public), 172.31.87.98 (private)
- worker-3: 3.238.123.143 (public), 172.31.91.254 (private)

**Cost**:
- Running 24/7: ~$30/month
- Stopped (EIP retained): ~$0.50/month
- EBS volumes (when deployed): ~$3/month

---

## Important: Rebuild Strategy

⚠️ **DO NOT USE AMI BACKUPS FOR CLUSTER RECOVERY** ⚠️

**Why?** Kubernetes stores internal IP addresses in many places (etcd configs, certificates, /etc/hosts). When you restore from AMIs, AWS assigns new IPs, breaking everything. Fixing this is painful and error-prone.

**Instead**: Rebuild from scratch (~30 mins). It's faster, cleaner, and more reliable.

**When to rebuild**:
- After major experiments/testing
- To reset for recording demos
- If cluster gets into a bad state
- To upgrade/downgrade Kubernetes versions

---

## Complete Cluster Build (From Scratch)

This section contains EVERY command needed to build the cluster from zero. Tested Dec 3, 2025.

---

### 🚨 CRITICAL CHECKLIST - Read Before Starting! 🚨

When rebuilding, AWS assigns **NEW private IPs**. You MUST update these in the commands below:

**Private IP Replacement Checklist:**
- [ ] **Step 1**: Note your NEW control plane private IP after instances launch
- [ ] **Step 3**: Replace `172.31.XX.XX` in API server cert config with NEW IP
- [ ] **Step 5**: Replace `172.31.XX.XX` in worker /etc/hosts (3× - once per worker)

⚠️ **Using the wrong IP = setup failure!**

The document shows `172.31.XX.XX` as a placeholder - this is **intentionally wrong** to force you to update it!

---

### Prerequisites

**On your local machine**:
- AWS CLI configured
- kubectl installed (v1.34.2+)
- Helm 3 installed
- SSH key: `keypair/k8s-cluster-key.pem` (chmod 400)

**In AWS**:
- Elastic IP allocated: 35.174.232.81
- Security Group created: `k8s-cluster-sg` (see section below)
- IAM setup for EBS (policy, role, instance profile) - see aws-storage-setup.md

---

### Step 1: Launch EC2 Instances

**Launch 4× t3.medium instances via AWS Console**:

1. Go to EC2 → Launch Instance
2. **Name**: k8s-control-plane-1, k8s-worker-1, k8s-worker-2, k8s-worker-3
3. **AMI**: Ubuntu 24.04 LTS (ami-0e2c8caa4b6378d8c or latest)
4. **Instance type**: t3.medium
5. **Key pair**: k8s-cluster-key
6. **Network settings**:
   - VPC: Default
   - Subnet: Any in us-east-1
   - Auto-assign public IP: Enable
   - Security group: Select `k8s-cluster-sg`
7. **Storage**: 20GB gp3
8. **Advanced** → IAM instance profile: K8sNodeProfile (for EBS driver)
9. Launch instance

**Associate Elastic IP to control plane**:
1. EC2 → Elastic IPs
2. Select 35.174.232.81
3. Actions → Associate
4. Select k8s-control-plane-1
5. Associate

---

**🚨 CRITICAL: Document the NEW Control Plane Private IP 🚨**

After instances launch, go to EC2 Console and **write down the control plane's private IP address**. You'll need this in:
- **Step 3**: API server certificate configuration
- **Step 5**: Worker node /etc/hosts configuration

**Example**: If your new control plane private IP is `172.31.XX.XX`, write it down now!

```
NEW CONTROL PLANE PRIVATE IP: ___________________ (FILL THIS IN!)
```

⚠️ **Do NOT use the old IP from this document (172.31.94.146) - AWS will assign a NEW IP!**

---

### Step 2: Prepare All Nodes

**SSH to each node and run these commands**.

#### On ALL nodes (control plane + workers):

```bash
# Disable swap (required for kubelet)
sudo swapoff -a
sudo sed -i '/ swap / s/^/#/' /etc/fstab

# Load kernel modules
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

# Configure sysctl
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sudo sysctl --system

# Install containerd
sudo apt-get update
sudo apt-get install -y containerd
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl restart containerd
sudo systemctl enable containerd

# Install Kubernetes packages
sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates curl gpg
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.33/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.33/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update
sudo apt-get install -y kubelet=1.33.6-1.1 kubeadm=1.33.6-1.1 kubectl=1.33.6-1.1
sudo apt-mark hold kubelet kubeadm kubectl

# Verify installation
kubelet --version  # Should show: Kubernetes v1.33.6
```

---

### Step 3: Initialize Control Plane

**SSH to control plane** (ubuntu@35.174.232.81):

#### Add hostname for API endpoint:

```bash
# This allows control plane to reach itself via k8s-api.local
echo "127.0.0.1 k8s-api.local" | sudo tee -a /etc/hosts
```

#### Initialize cluster:

```bash
sudo kubeadm init \
  --control-plane-endpoint=k8s-api.local:6443 \
  --pod-network-cidr=192.168.0.0/16 \
  --upload-certs
```

**Save the join command output** - you'll need it for workers!

#### Configure kubectl:

```bash
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

#### Add Elastic IP to API server certificate:

**Critical step** - allows external access via Elastic IP:

**🚨 STOP: You need your NEW control plane private IP from Step 1! 🚨**

```bash
# Create kubeadm config patch
# ⚠️ REPLACE 172.31.XX.XX BELOW WITH YOUR NEW CONTROL PLANE PRIVATE IP FROM STEP 1!
cat > /tmp/kubeadm-config-patch.yaml <<EOF
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
apiServer:
  certSANs:
  - "35.174.232.81"
  - "k8s-api.local"
  - "172.31.XX.XX"  # ⚠️ REPLACE THIS WITH YOUR NEW CONTROL PLANE PRIVATE IP!
EOF

# Regenerate API server cert with Elastic IP
sudo rm /etc/kubernetes/pki/apiserver.crt /etc/kubernetes/pki/apiserver.key
sudo kubeadm init phase certs apiserver --config /tmp/kubeadm-config-patch.yaml

# Restart API server (it will pick up new cert automatically)
sudo crictl stopp $(sudo crictl pods --name kube-apiserver -q)

# Wait 30 seconds for API server to restart
sleep 30
```

---

### Step 4: Install Calico CNI

**On control plane**:

```bash
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.29.1/manifests/calico.yaml

# Wait for Calico pods to start
kubectl get pods -n kube-system -w
# Press Ctrl+C when calico-node is Running

# ⚠️ CRITICAL: Restart kubelet and containerd to initialize CNI properly
sudo systemctl restart containerd
sudo systemctl restart kubelet

# Wait 20 seconds
sleep 20

# Verify node is Ready
kubectl get nodes
# Should show: ip-172-31-XX-XXX   Ready   control-plane
```

---

### Step 5: Join Worker Nodes

**For each worker**, SSH in and:

#### Add control plane hostname:

**🚨 STOP: Use your NEW control plane private IP from Step 1! 🚨**

```bash
# ⚠️ REPLACE 172.31.XX.XX BELOW WITH YOUR NEW CONTROL PLANE PRIVATE IP FROM STEP 1!
echo "172.31.XX.XX k8s-api.local" | sudo tee -a /etc/hosts
```

**Verify it worked:**
```bash
grep k8s-api.local /etc/hosts
# Should show: 172.31.XX.XX k8s-api.local (with YOUR new IP)
```

#### Reset any previous cluster state:

```bash
sudo kubeadm reset -f
sudo rm -rf /etc/cni/net.d
sudo iptables -F && sudo iptables -t nat -F && sudo iptables -t mangle -F && sudo iptables -X
```

#### Join the cluster:

Use the `kubeadm join` command from Step 3 output. It looks like:

```bash
sudo kubeadm join k8s-api.local:6443 --token XXXXXX \
        --discovery-token-ca-cert-hash sha256:YYYYYY
```

#### Restart services (critical for CNI):

```bash
sudo systemctl restart containerd
sudo systemctl restart kubelet
```

**Repeat for all 3 workers**.

---

### Step 6: Verify Cluster on Control Plane

**SSH to control plane**:

```bash
kubectl get nodes
# Should show all 4 nodes Ready (may take 1-2 minutes)

kubectl get pods -n kube-system
# All pods should be Running

kubectl get pods -n kube-system -o wide
# Verify pods are distributed across nodes
```

---

### Step 7: Configure Local kubectl Access

**On your local machine**:

```bash
# Get kubeconfig from control plane
ssh -i keypair/k8s-cluster-key.pem ubuntu@35.174.232.81 'cat ~/.kube/config' > aws-kubeconfig

# Edit aws-kubeconfig: Change server from k8s-api.local to 35.174.232.81
# Line 5: server: https://k8s-api.local:6443  →  server: https://35.174.232.81:6443

# Test connection
kubectl --kubeconfig=aws-kubeconfig get nodes
# Should show all 4 nodes Ready
```

**Set KUBECONFIG environment variable** (add to ~/.zshrc or ~/.bashrc):

```bash
export KUBECONFIG=/full/path/to/playground/aws-kubeconfig
```

Reload shell, then test:

```bash
kubectl get nodes  # Should work without --kubeconfig flag
```

---

### Step 8: Install EBS CSI Driver

**On your local machine** (with kubectl configured):

```bash
# Add Helm repo
helm repo add aws-ebs-csi-driver https://kubernetes-sigs.github.io/aws-ebs-csi-driver
helm repo update

# Install driver
helm install aws-ebs-csi-driver aws-ebs-csi-driver/aws-ebs-csi-driver \
  --namespace kube-system

# Verify driver pods are running
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-ebs-csi-driver
# Should show: 2 controller pods (5/5), 4 node pods (3/3)
```

#### Create StorageClass:

```bash
cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ebs-sc
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  encrypted: "true"
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
reclaimPolicy: Delete
EOF

# Verify
kubectl get storageclass
# Should show: ebs-sc (default)
```

#### Test EBS provisioning:

```bash
# Create test PVC and pod
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-ebs-claim
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
  storageClassName: ebs-sc
---
apiVersion: v1
kind: Pod
metadata:
  name: test-ebs-pod
spec:
  containers:
  - name: app
    image: nginx
    volumeMounts:
    - name: data
      mountPath: /data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: test-ebs-claim
EOF

# Wait for PVC to bind and pod to run
kubectl get pvc test-ebs-claim
kubectl get pod test-ebs-pod

# Clean up test resources
kubectl delete pod test-ebs-pod
kubectl delete pvc test-ebs-claim
```

---

### Step 9: Cluster Complete!

Your cluster is now ready. Verify:

```bash
kubectl get nodes
# All 4 nodes Ready

kubectl get pods -n kube-system
# All pods Running

kubectl get storageclass
# ebs-sc (default)

kubectl cluster-info
# Should show API server at https://35.174.232.81:6443
```

**Total time**: ~30 minutes
**Status**: Ready for application deployments and demos!

---

## Security Group Configuration

**Name**: `k8s-cluster-sg`

**Inbound Rules**:

| Type | Protocol | Port Range | Source | Description |
|------|----------|------------|--------|-------------|
| SSH | TCP | 22 | Your IP | SSH access |
| Custom TCP | TCP | 6443 | Your IP | Kubernetes API (external) |
| Custom TCP | TCP | 6443 | k8s-cluster-sg | Kubernetes API (internal) |
| Custom TCP | TCP | 2379-2380 | k8s-cluster-sg | etcd server client API |
| Custom TCP | TCP | 10250 | k8s-cluster-sg | kubelet API |
| Custom TCP | TCP | 10257 | k8s-cluster-sg | kube-controller-manager |
| Custom TCP | TCP | 10259 | k8s-cluster-sg | kube-scheduler |
| Custom TCP | TCP | 179 | k8s-cluster-sg | Calico BGP |
| Custom UDP | UDP | 4789 | k8s-cluster-sg | Calico VXLAN |
| All traffic | All | All | k8s-cluster-sg | Node-to-node communication |

**Outbound Rules**: All traffic (default)

---

## Common Issues & Solutions

### Issue: Nodes show NotReady after CNI installation

**Cause**: kubelet hasn't initialized CNI plugin yet

**Solution**:
```bash
# On each NotReady node:
sudo systemctl restart containerd
sudo systemctl restart kubelet
```

Wait 20-30 seconds, then check: `kubectl get nodes`

---

### Issue: Can't connect with kubectl from local machine

**Cause**: Certificate doesn't include Elastic IP, or wrong server in kubeconfig

**Solution**:
1. Verify Elastic IP is in cert (on control plane):
   ```bash
   openssl x509 -in /etc/kubernetes/pki/apiserver.crt -text -noout | grep -A1 "Subject Alternative Name"
   # Should include: IP Address:35.174.232.81
   ```

2. Verify local kubeconfig uses Elastic IP:
   ```bash
   grep server: aws-kubeconfig
   # Should show: server: https://35.174.232.81:6443
   ```

3. If Elastic IP missing from cert, follow Step 3 cert regeneration commands

---

### Issue: Worker can't join - "connection refused" or timeouts

**Cause**: Worker's /etc/hosts doesn't point k8s-api.local to control plane

**Solution**:
```bash
# On worker, verify /etc/hosts:
grep k8s-api.local /etc/hosts
# Should show: 172.31.XX.XX k8s-api.local (with YOUR control plane private IP)

# If missing or wrong, add/fix it:
echo "172.31.XX.XX k8s-api.local" | sudo tee -a /etc/hosts  # ⚠️ Use YOUR control plane IP!

# Then retry join
```

---

### Issue: EBS volumes fail to provision

**Cause**: IAM instance profile not attached or wrong permissions

**Solution**:
1. Verify instance profile attached:
   ```bash
   aws ec2 describe-instances --instance-ids i-XXXXX --query 'Reservations[].Instances[].IamInstanceProfile'
   ```

2. Attach if missing:
   ```bash
   aws ec2 associate-iam-instance-profile --instance-id i-XXXXX --iam-instance-profile Name=K8sNodeProfile
   ```

3. Check EBS CSI driver logs:
   ```bash
   kubectl logs -n kube-system -l app=ebs-csi-controller -c csi-provisioner
   ```

---

## Stopping and Starting the Cluster

**To stop (save costs)**:

```bash
# Stop all 4 instances in AWS Console
# Elastic IP remains associated (small monthly fee ~$0.50)
```

**To start again**:

```bash
# Start all 4 instances in AWS Console
# Wait 2-3 minutes
# Test: kubectl get nodes
# Worker public IPs will change, but cluster works fine
```

**Note**: Private IPs and Elastic IP remain the same, so cluster continues working immediately. No configuration changes needed!

---

## When to Rebuild vs. Restart

**Just restart instances** if:
- You stopped them to save costs
- Minor testing/experimenting
- Need to bounce nodes

**Rebuild from scratch** if:
- Upgrading/downgrading Kubernetes
- Cluster is in a bad state after experiments
- Recording demos (want clean baseline)
- Internal IPs changed (instance termination/recreation)
- Major CNI or networking changes

Rebuilding is only ~30 mins and guarantees a clean, working state.

---

## Next Steps

With the cluster built, you can now:

1. **Deploy applications**: Use Helm charts from `demo-app/`
2. **Set up monitoring**: Prometheus, Grafana, Loki (see Module 2 docs)
3. **Practice upgrades**: Upgrade to K8s 1.34.x (Module 1 demo)
4. **Test troubleshooting**: Use scenarios from `scenarios/` (Module 3)

The cluster is production-ready and suitable for all course demonstrations!
