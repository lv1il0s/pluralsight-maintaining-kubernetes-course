# AWS Kubernetes Cluster Setup Guide

**Purpose**: Build a production-like kubeadm cluster for hands-on practice
**Time Required**: ~30-40 minutes
**AWS Region**: Any region (examples use us-east-1)
**Kubernetes Version**: 1.33.6

**Estimated Monthly Cost**:
- **Running 24/7**: ~$30-35/month
  - EC2 instances (4× t3.medium): ~$24/month
  - EBS root volumes (80GB): ~$6.40/month
  - EBS persistent volumes (varies by apps): ~$3-5/month
  - Elastic IP: ~$0.50/month

- **Stopped (instances off, volumes kept)**: ~$10-12/month
  - EC2 instances: $0 (stopped)
  - EBS root volumes: ~$6.40/month (still charged!)
  - EBS persistent volumes: ~$3-5/month (still charged!)
  - Elastic IP: ~$0.50/month

⚠️ **Important**: EBS volumes continue costing money even when instances are stopped. To minimize costs, delete unnecessary persistent volumes (see "Managing Your Cluster" section below).

---

## What You'll Build

- **4 EC2 instances**: 1 control plane + 3 worker nodes
- **Instance type**: t3.medium (2 vCPU, 4GB RAM)
- **Operating System**: Ubuntu 24.04 LTS
- **Container Runtime**: containerd 1.7.28
- **Kubernetes**: 1.33.6
- **CNI Plugin**: Calico v3.29.1
- **Persistent Storage**: AWS EBS CSI Driver

---

## Prerequisites

### On Your Local Machine:
- AWS account with admin access
- AWS CLI installed and configured
- kubectl installed (v1.33+)
- Helm 3 installed
- SSH client

### In AWS (you'll create these):
- Elastic IP (for stable control plane access)
- Security Group (with Kubernetes ports)
- EC2 Key Pair (for SSH access)
- IAM Role for EBS storage (optional, but recommended)

---

## Step 1: Create AWS Resources

### 1.1: Create EC2 Key Pair

1. Go to **EC2 Console** → **Key Pairs**
2. Click **Create key pair**
3. Name: `k8s-cluster-key`
4. Type: RSA
5. Format: .pem
6. Download and save to safe location
7. Set permissions: `chmod 400 k8s-cluster-key.pem`

### 1.2: Allocate Elastic IP

1. Go to **EC2 Console** → **Elastic IPs**
2. Click **Allocate Elastic IP address**
3. Click **Allocate**
4. **Note the IP address** - you'll use this throughout the setup

```
YOUR ELASTIC IP: ___________________ (write this down!)
```

### 1.3: Create Security Group

1. Go to **EC2 Console** → **Security Groups**
2. Click **Create security group**
3. Name: `k8s-cluster-sg`
4. Description: Kubernetes cluster security group
5. VPC: Default VPC

**Add Inbound Rules:**

| Type | Protocol | Port Range | Source | Description |
|------|----------|------------|--------|-------------|
| SSH | TCP | 22 | Your IP | SSH access |
| Custom TCP | TCP | 6443 | Your IP | Kubernetes API (external) |
| All traffic | All | All | k8s-cluster-sg | Internal cluster communication |

6. Click **Create security group**

### 1.4: Create IAM Role for EBS (Required for Persistent Storage)

**Skip this section if you don't need persistent storage** (Redis, Prometheus, databases, etc.). Otherwise, follow these steps to allow Kubernetes to create EBS volumes dynamically.

#### Create IAM Policy:

1. Go to **IAM Console** → **Policies**
2. Click **Create policy**
3. Click **JSON** tab
4. Paste this policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:CreateSnapshot",
        "ec2:AttachVolume",
        "ec2:DetachVolume",
        "ec2:ModifyVolume",
        "ec2:DescribeAvailabilityZones",
        "ec2:DescribeInstances",
        "ec2:DescribeSnapshots",
        "ec2:DescribeTags",
        "ec2:DescribeVolumes",
        "ec2:DescribeVolumesModifications"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "ec2:CreateTags"
      ],
      "Resource": [
        "arn:aws:ec2:*:*:volume/*",
        "arn:aws:ec2:*:*:snapshot/*"
      ],
      "Condition": {
        "StringEquals": {
          "ec2:CreateAction": [
            "CreateVolume",
            "CreateSnapshot"
          ]
        }
      }
    },
    {
      "Effect": "Allow",
      "Action": [
        "ec2:DeleteTags"
      ],
      "Resource": [
        "arn:aws:ec2:*:*:volume/*",
        "arn:aws:ec2:*:*:snapshot/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "ec2:CreateVolume"
      ],
      "Resource": "*",
      "Condition": {
        "StringLike": {
          "aws:RequestTag/ebs.csi.aws.com/cluster": "true"
        }
      }
    },
    {
      "Effect": "Allow",
      "Action": [
        "ec2:CreateVolume"
      ],
      "Resource": "*",
      "Condition": {
        "StringLike": {
          "aws:RequestTag/CSIVolumeName": "*"
        }
      }
    },
    {
      "Effect": "Allow",
      "Action": [
        "ec2:DeleteVolume"
      ],
      "Resource": "*",
      "Condition": {
        "StringLike": {
          "ec2:ResourceTag/ebs.csi.aws.com/cluster": "true"
        }
      }
    },
    {
      "Effect": "Allow",
      "Action": [
        "ec2:DeleteVolume"
      ],
      "Resource": "*",
      "Condition": {
        "StringLike": {
          "ec2:ResourceTag/CSIVolumeName": "*"
        }
      }
    },
    {
      "Effect": "Allow",
      "Action": [
        "ec2:DeleteVolume"
      ],
      "Resource": "*",
      "Condition": {
        "StringLike": {
          "ec2:ResourceTag/kubernetes.io/created-for/pvc/name": "*"
        }
      }
    },
    {
      "Effect": "Allow",
      "Action": [
        "ec2:DeleteSnapshot"
      ],
      "Resource": "*",
      "Condition": {
        "StringLike": {
          "ec2:ResourceTag/CSIVolumeSnapshotName": "*"
        }
      }
    },
    {
      "Effect": "Allow",
      "Action": [
        "ec2:DeleteSnapshot"
      ],
      "Resource": "*",
      "Condition": {
        "StringLike": {
          "ec2:ResourceTag/ebs.csi.aws.com/cluster": "true"
        }
      }
    }
  ]
}
```

5. Click **Next**
6. **Name**: `EBS-CSI-Driver-Policy`
7. Click **Create policy**

#### Create IAM Role:

1. Go to **IAM Console** → **Roles**
2. Click **Create role**
3. Select **AWS service** → **EC2**
4. Click **Next**
5. Search for and select: `EBS-CSI-Driver-Policy` (the policy you just created)
6. Click **Next**
7. **Role name**: `K8sNodeRole`
8. Click **Create role**

The role and instance profile are created automatically. You'll attach this to your EC2 instances in Step 2.

---

## Step 2: Launch EC2 Instances

Launch **4× t3.medium instances**:

1. Go to **EC2 Console** → **Launch Instance**
2. Click **Launch instance** 4 times (or use "Number of instances: 4")

**Configuration for each:**
- **Name tags**:
  - `k8s-control-plane`
  - `k8s-worker-1`
  - `k8s-worker-2`
  - `k8s-worker-3`
- **AMI**: Ubuntu 24.04 LTS (search "Ubuntu 24.04")
- **Instance type**: t3.medium
- **Key pair**: Select `k8s-cluster-key`
- **Network settings**:
  - VPC: Default
  - Auto-assign public IP: **Enable**
  - Security group: Select `k8s-cluster-sg`
- **Storage**: 20GB gp3
- **Advanced details** → IAM instance profile: Select `K8sNodeRole` (if created)

3. Click **Launch instance**

### Associate Elastic IP to Control Plane:

1. Go to **EC2 Console** → **Elastic IPs**
2. Select your Elastic IP
3. Click **Actions** → **Associate Elastic IP address**
4. Select the `k8s-control-plane` instance
5. Click **Associate**

### Document Instance Private IPs:

Go to **EC2 Console** → **Instances** and note the **Private IPv4 addresses**:

```
CONTROL PLANE PRIVATE IP: ___________________ (CRITICAL - you'll need this!)
WORKER-1 PRIVATE IP: ___________________
WORKER-2 PRIVATE IP: ___________________
WORKER-3 PRIVATE IP: ___________________
```

---

## Step 3: Prepare All Nodes

SSH into **each of the 4 nodes** and run these commands.

**SSH command format:**
```bash
# For control plane (use your Elastic IP):
ssh -i k8s-cluster-key.pem ubuntu@YOUR_ELASTIC_IP

# For workers (use their public IPs):
ssh -i k8s-cluster-key.pem ubuntu@WORKER_PUBLIC_IP
```

### On ALL 4 Nodes (Control Plane + Workers):

```bash
# Disable swap (required for kubelet)
sudo swapoff -a
sudo sed -i '/ swap / s/^/#/' /etc/fstab

# Load required kernel modules
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

# Configure network settings
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
kubelet --version
```

---

## Step 4: Initialize Control Plane

**SSH to control plane node only:**

### 4.1: Configure hostname resolution

```bash
# This allows the control plane to reach itself via hostname
echo "127.0.0.1 k8s-api.local" | sudo tee -a /etc/hosts
```

### 4.2: Initialize Kubernetes

```bash
sudo kubeadm init \
  --control-plane-endpoint=k8s-api.local:6443 \
  --pod-network-cidr=192.168.0.0/16 \
  --upload-certs
```

**⚠️ IMPORTANT: Save the join command from the output!** You'll need it for workers.

### 4.3: Configure kubectl on control plane

```bash
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

### 4.4: Add Elastic IP to API server certificate

**This allows external kubectl access via your Elastic IP.**

```bash
# Create certificate configuration
# ⚠️ REPLACE PLACEHOLDERS BELOW:
#   - YOUR_ELASTIC_IP: Your Elastic IP from Step 1.2
#   - YOUR_CONTROL_PLANE_PRIVATE_IP: Control plane private IP from Step 2

cat > /tmp/kubeadm-config-patch.yaml <<EOF
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
apiServer:
  certSANs:
  - "YOUR_ELASTIC_IP"
  - "k8s-api.local"
  - "YOUR_CONTROL_PLANE_PRIVATE_IP"
EOF

# Regenerate API server certificate
sudo rm /etc/kubernetes/pki/apiserver.crt /etc/kubernetes/pki/apiserver.key
sudo kubeadm init phase certs apiserver --config /tmp/kubeadm-config-patch.yaml

# Restart API server to use new certificate
sudo crictl stopp $(sudo crictl pods --name kube-apiserver -q)

# Wait for API server to restart
sleep 30

# Verify
kubectl get nodes
```

---

## Step 5: Install Calico CNI

**On control plane:**

```bash
# Install Calico
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.29.1/manifests/calico.yaml

# Wait for Calico pods to start (watch for Running status)
kubectl get pods -n kube-system -w
# Press Ctrl+C when you see calico-node pods Running

# CRITICAL: Restart services to initialize CNI properly
sudo systemctl restart containerd
sudo systemctl restart kubelet

# Wait 30 seconds
sleep 30

# Verify control plane is Ready
kubectl get nodes
```

---

## Step 6: Join Worker Nodes

**For each worker node**, SSH in and run these commands:

### 6.1: Configure hostname resolution

```bash
# ⚠️ REPLACE YOUR_CONTROL_PLANE_PRIVATE_IP with the private IP from Step 2
echo "YOUR_CONTROL_PLANE_PRIVATE_IP k8s-api.local" | sudo tee -a /etc/hosts

# Verify it was added correctly
grep k8s-api.local /etc/hosts
```

### 6.2: Clean any previous state

```bash
sudo kubeadm reset -f
sudo rm -rf /etc/cni/net.d
sudo iptables -F && sudo iptables -t nat -F && sudo iptables -t mangle -F && sudo iptables -X
```

### 6.3: Join the cluster

Use the `kubeadm join` command you saved from Step 4.2. It looks like:

```bash
sudo kubeadm join k8s-api.local:6443 --token XXXXXX \
    --discovery-token-ca-cert-hash sha256:YYYYYY
```

### 6.4: Restart services (critical for CNI)

```bash
sudo systemctl restart containerd
sudo systemctl restart kubelet
```

**Repeat Steps 6.1-6.4 for all 3 worker nodes.**

---

## Step 7: Verify Cluster

**On control plane:**

```bash
# Check all nodes are Ready (may take 1-2 minutes)
kubectl get nodes

# Check all system pods are Running
kubectl get pods -n kube-system

# Verify pods are distributed across nodes
kubectl get pods -n kube-system -o wide
```

You should see:
- 4 nodes in Ready state
- All kube-system pods Running
- Pods distributed across different nodes

---

## Step 8: Configure Local kubectl Access

**On your local machine:**

### 8.1: Download kubeconfig from control plane

```bash
# ⚠️ REPLACE YOUR_ELASTIC_IP with your Elastic IP
ssh -i k8s-cluster-key.pem ubuntu@YOUR_ELASTIC_IP 'cat ~/.kube/config' > k8s-kubeconfig

# Edit k8s-kubeconfig file
# Change line 5: server: https://k8s-api.local:6443
# To:             server: https://YOUR_ELASTIC_IP:6443
```

### 8.2: Test connection

```bash
kubectl --kubeconfig=k8s-kubeconfig get nodes
# Should show all 4 nodes Ready
```

### 8.3: Set as default kubeconfig (optional)

```bash
# Option 1: Set environment variable (temporary)
export KUBECONFIG=/full/path/to/k8s-kubeconfig

# Option 2: Replace default config (permanent)
cp k8s-kubeconfig ~/.kube/config

# Test
kubectl get nodes
```

---

## Step 9: Install EBS CSI Driver (Optional)

**Skip this if you don't need persistent storage.**

**On your local machine (with kubectl configured):**

```bash
# Add Helm repository
helm repo add aws-ebs-csi-driver https://kubernetes-sigs.github.io/aws-ebs-csi-driver
helm repo update

# Install driver
helm install aws-ebs-csi-driver aws-ebs-csi-driver/aws-ebs-csi-driver \
  --namespace kube-system

# Verify driver pods are running
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-ebs-csi-driver
```

### Create default StorageClass:

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
```

### Test EBS provisioning:

```bash
# Create test PVC and pod
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-ebs-pvc
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
      claimName: test-ebs-pvc
EOF

# Wait for PVC to bind and pod to run
kubectl get pvc test-ebs-pvc
kubectl get pod test-ebs-pod

# Clean up
kubectl delete pod test-ebs-pod
kubectl delete pvc test-ebs-pvc
```

---

## Step 10: Cluster Ready!

**Verify everything:**

```bash
kubectl get nodes
# All 4 nodes Ready

kubectl get pods -n kube-system
# All pods Running

kubectl cluster-info
# Should show API server accessible
```

**Your cluster is now ready for deploying applications!**

---

## Troubleshooting

### Issue: Nodes show NotReady after Calico installation

**Solution:**
```bash
# On each NotReady node:
sudo systemctl restart containerd
sudo systemctl restart kubelet

# Wait 30 seconds, then check
kubectl get nodes
```

---

### Issue: Can't connect with kubectl from local machine

**Check 1 - Verify kubeconfig server address:**
```bash
grep server: k8s-kubeconfig
# Should show: server: https://YOUR_ELASTIC_IP:6443
```

**Check 2 - Verify certificate includes Elastic IP:**
```bash
# On control plane:
openssl x509 -in /etc/kubernetes/pki/apiserver.crt -text -noout | grep -A1 "Subject Alternative Name"
# Should include: IP Address:YOUR_ELASTIC_IP
```

If Elastic IP is missing, repeat Step 4.4.

---

### Issue: Worker can't join cluster

**Check 1 - Verify /etc/hosts on worker:**
```bash
grep k8s-api.local /etc/hosts
# Should show: YOUR_CONTROL_PLANE_PRIVATE_IP k8s-api.local
```

**Check 2 - Verify connectivity:**
```bash
ping k8s-api.local
# Should reach control plane
```

---

### Issue: EBS volumes fail to provision

**Check IAM role is attached to instances:**
```bash
# On AWS Console:
# EC2 → Instances → Select instance → Actions → Security → Modify IAM role
# Should show K8sNodeRole attached
```

**Check CSI driver logs:**
```bash
kubectl logs -n kube-system -l app=ebs-csi-controller -c csi-provisioner
```

---

## Managing Your Cluster

### Stopping instances to save costs:
- Stop all 4 instances in AWS Console when not in use
- Your Elastic IP remains associated (small monthly fee ~$0.50)
- To restart: Just start all 4 instances - everything works immediately

### Managing EBS volumes to minimize costs:

⚠️ **Important**: EBS volumes continue costing money (~$0.08/GB/month) even when instances are stopped.

**Check your volumes:**
```bash
# List all volumes in your cluster
kubectl get pv

# Delete a specific PVC (also deletes the EBS volume)
kubectl delete pvc PVC-NAME -n NAMESPACE
```

**Clean up orphaned volumes in AWS Console:**
1. Go to **EC2** → **Volumes**
2. Look for volumes in "available" state (not attached to instances)
3. These are safe to delete if you don't need the data
4. Select volume → Actions → Delete volume

**Common orphaned volumes:**
- Redis data (1-5GB)
- Prometheus metrics (5-10GB)
- Loki logs (5-10GB)
- Grafana dashboards (1GB)

If you're not actively using the cluster, consider deleting application persistent volumes to save $3-5/month.

### Accessing your cluster:
- **From control plane**: SSH in and use `kubectl` directly
- **From your local machine**: Use `kubectl --kubeconfig=k8s-kubeconfig`
- **Port-forwarding services**: `kubectl port-forward svc/SERVICE-NAME LOCAL_PORT:SERVICE_PORT`

---

## Next Steps

With your cluster running, you can:

1. **Deploy applications**: Practice with Helm charts and Kubernetes manifests
2. **Install monitoring**: Deploy Prometheus, Grafana, and Loki for observability
3. **Practice upgrades**: Upgrade Kubernetes versions using kubeadm
4. **Learn troubleshooting**: Simulate common issues and practice resolution

Congratulations on building your production-like Kubernetes cluster! 🎉
