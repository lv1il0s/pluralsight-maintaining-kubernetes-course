# Maintaining, Monitoring and Troubleshooting Kubernetes

Supporting materials for the Pluralsight course [Maintaining, Monitoring and Troubleshooting Kubernetes](http://www.pluralsight.com/courses/maintaining-monitoring-troubleshoot-kubernetes)

---

## Contents

- **Demo code** (`01/`, `02/`, `03/`) — hands-on examples from course modules
- **Course slides** — PDF versions of presentation slides
- **AWS cluster setup** — two paths to a working practice cluster: a manual walkthrough or fully-automated IaC

---

## Cluster setup

You have two options for getting a Kubernetes cluster to follow along with the course. Both end up with the same cluster shape: 1 control plane + 3 workers running kubeadm 1.33.6, Calico CNI, and the AWS EBS CSI driver.

### Option 1 — Manual walkthrough (recommended for learning)

Step-by-step kubeadm commands. Best if you want to learn the mechanics and see every moving part.

[**docs/student-aws-cluster-setup-guide.md**](docs/student-aws-cluster-setup-guide.md)

### Option 2 — Automated provisioning (Terraform + Ansible)

For students who already understand kubeadm and just want a working cluster fast (~5 min). Provisions the AWS infrastructure with Terraform, then bootstraps the cluster with Ansible from a small jump box inside the VPC.

```
terraform/   AWS infra: VPC, security group, IAM, 4x EC2 nodes, jump box, EBS CSI policy
ansible/     kubeadm init -> Calico CNI -> worker join -> EBS CSI driver helm install
```

#### Prerequisites
- Terraform >= 1.5
- AWS CLI configured (`aws configure`) with permissions to create EC2, VPC, and IAM resources — [Pluralsight AWS sandbox](https://help.pluralsight.com/hc/en-us/articles/24425443133076-AWS-cloud-sandbox) credentials already have the required scope; for a personal AWS account, use `AdministratorAccess` or equivalent.
- An SSH client (Windows OpenSSH, WSL, or macOS/Linux)

#### Quick start

**Windows (PowerShell)** — use the wrapper script at the repo root:

```powershell
.\deploy-cluster.ps1
# or:  .\deploy-cluster.ps1 -InstanceType t3.medium
```

It runs all three phases below (terraform → bootstrap via jump box → pull kubeconfig) and writes `k8s-kubeconfig` to the repo root. Re-runnable; pass `-SkipTerraform` to re-bootstrap an existing cluster, or `-SkipBootstrap` to stop after `terraform apply`. Run `Get-Help .\deploy-cluster.ps1 -Full` for all parameters.

**macOS / Linux / WSL** — run the steps manually:

```bash
# 1) Provision AWS infrastructure
cd terraform
terraform init
terraform apply -var="my_ip_cidr=$(curl -s ifconfig.me)"
# Outputs: elastic_ip, jump_box_public_ip, ssh_jump_box, ...
# Side effects:
#   - terraform/k8s-cluster-key.pem  (chmod 0400, your SSH key)
#   - ansible/inventory.yml          (auto-generated with private IPs)

# 2) Copy the playbook + key onto the jump box and run Ansible
JUMP=$(terraform output -raw jump_box_public_ip)
KEY=k8s-cluster-key.pem

ssh -i $KEY -o StrictHostKeyChecking=no ubuntu@$JUMP \
  "mkdir -p ~/cluster/terraform ~/cluster/ansible"
scp -i $KEY -r ../ansible/*    ubuntu@$JUMP:~/cluster/ansible/
scp -i $KEY    $KEY            ubuntu@$JUMP:~/cluster/terraform/k8s-cluster-key.pem
ssh -i $KEY ubuntu@$JUMP "chmod 600 ~/cluster/terraform/k8s-cluster-key.pem"

ssh -i $KEY ubuntu@$JUMP \
  "cloud-init status --wait && cd ~/cluster/ansible && ansible-playbook site.yml"

# 3) Pull the kubeconfig back to your laptop
scp -i $KEY ubuntu@$JUMP:~/cluster/k8s-kubeconfig ../k8s-kubeconfig
kubectl --kubeconfig=../k8s-kubeconfig get nodes
```

#### Connecting to the nodes

The PowerShell script prints ready-to-run SSH commands when it finishes. To retrieve them later (or to grab any other infra detail — worker IPs, EIP, etc.), run:

```powershell
cd terraform
terraform output                        # all outputs, with descriptions
terraform output -raw ssh_jump_box      # just the jump box SSH command
terraform output -raw ssh_control_plane # just the control plane SSH command
terraform output worker_public_ips      # list of worker public IPs
```

The private key lives at `terraform/k8s-cluster-key.pem`. From the `terraform/` directory you can SSH directly:

```powershell
ssh -i k8s-cluster-key.pem ubuntu@(terraform output -raw elastic_ip)         # control plane
ssh -i k8s-cluster-key.pem ubuntu@(terraform output -raw jump_box_public_ip) # jump box

# Workers (pick an index 0..N-1 from the list)
$workers = terraform output -json worker_public_ips | ConvertFrom-Json
ssh -i k8s-cluster-key.pem ubuntu@$($workers[0])                             # worker-1
```

#### Demo IP placeholders

Some demos (e.g. [01/demos/maintaining-k8s-m1/demo3/upgrading-k8s-cluster.md](01/demos/maintaining-k8s-m1/demo3/upgrading-k8s-cluster.md)) ship with placeholders like `<CONTROL_PLANE_IP>` and `<WORKER_1_IP>` instead of real IPs. `deploy-cluster.ps1` substitutes them automatically at the end of a run; you can also re-run the substitution standalone:

```powershell
.\Update-DemoIps.ps1
```

The script tracks last-rendered values in `.demo-ip-state.json` (gitignored), so it correctly rewrites stale IPs after a `terraform destroy` + re-deploy. To revert demos to their committed placeholder form: `git checkout -- 01/ 02/ 03/`.

#### Why a jump box?

Ansible needs to SSH the cluster nodes. Running it from a Linux VM inside the VPC sidesteps two Windows-specific headaches: NTFS not honoring `chmod 0400` on the SSH key, and Ansible not running natively on Windows. The jump box also gets free intra-cluster SSH thanks to the security group's self-reference rule, so Ansible can use the nodes' private IPs.

If you'd rather run Ansible from your own machine (WSL on Windows, native on macOS/Linux), regenerate the inventory with public IPs and skip the jump box.

#### Pluralsight AWS sandbox compatibility

The Terraform is sized to fit inside the [Pluralsight AWS cloud sandbox](https://help.pluralsight.com/hc/en-us/articles/24425443133076-AWS-cloud-sandbox):
- Region pinned to `us-east-1` or `us-west-2` (validated)
- Instance type defaults to `t3.small` (smallest size that passes kubeadm preflight)
- Subnet auto-filtered to AZs that actually offer the chosen instance type
- 5 EC2 instances total (4 cluster + 1 jump box) — well under the 9-instance ceiling
- Sandbox tears down after ~8 hours; treat the cluster as ephemeral

#### Cleanup

```bash
cd terraform
terraform destroy
```

---

## Deploying the demo charts

Each module under `01/`, `02/`, `03/` ships Helm charts you'll install against the cluster. The automated setup installs Helm on the control plane only — for `helm` from your laptop, install it locally.

### One-time setup

```powershell
# Install Helm (pick whichever package manager you have)
winget install Helm.Helm
# or:  choco install kubernetes-helm
# or:  scoop install helm

# Point kubectl + helm at the cluster's kubeconfig
$env:KUBECONFIG = "$PWD\k8s-kubeconfig"

# Sanity check
kubectl get nodes
helm version
```

Persist `KUBECONFIG` across sessions:
```powershell
[Environment]::SetEnvironmentVariable("KUBECONFIG", $env:KUBECONFIG, "User")
```

### The pattern for any chart

```powershell
helm install   <release-name> <chart-path>                       # first time
helm upgrade   <release-name> <chart-path>                       # apply changes
helm upgrade   <release-name> <chart-path> --set key=value       # override values
helm uninstall <release-name>                                    # tear down
helm list                                                        # what's deployed
helm history   <release-name>                                    # release history
helm rollback  <release-name> <revision>                         # roll back
```

Render manifests without touching the cluster (good for inspection):
```powershell
helm template <release-name> <chart-path>
```

### Example: guestbook

```powershell
cd 01\demos\maintaining-k8s-m1\demo1
helm install guestbook .\guestbook
kubectl get pods -w                          # wait for Running
kubectl port-forward svc/frontend 8080:80    # open http://localhost:8080
```

Redis declares a 1 Gi PVC, which triggers the EBS CSI driver to provision a real EBS volume on first install (~30 sec to bind — `kubectl get pvc -w`).

### Resource budget

Default `t3.small` workers give ~6 GiB total cluster capacity (3 × 2 GiB). The guestbook chart fits comfortably (~1 GiB of requests). Heavier stacks like Prometheus + Grafana + Loki will OOM on this footprint — re-apply Terraform with bigger workers for that session:

```powershell
cd terraform
terraform apply -var="instance_type=t3.medium"
```

---

## Prerequisites (for following along)

- Basic Kubernetes knowledge
- AWS account (if building the cluster)
- kubectl installed locally
- Helm 3 installed (only if using the manual walkthrough; automated path installs Helm on the control plane)

---

## Questions or Issues?

If you encounter any issues with the course materials, please open an issue in this repository.
