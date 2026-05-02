#Requires -Version 5.1
<#
.SYNOPSIS
    Provisions and bootstraps the AWS Kubernetes cluster end-to-end (Option 2).

.DESCRIPTION
    Wraps the manual Quick Start in README.md:
      1. terraform init + apply (auto-detects your public IP)
      2. ssh/scp the playbook + key onto the jump box
      3. runs ansible-playbook site.yml on the jump box
      4. pulls the kubeconfig back to the repo root

    Re-runnable: terraform is idempotent, and the bootstrap steps overwrite
    the previous copies on the jump box.

.PARAMETER MyIp
    Your public IP. Auto-detected via ifconfig.me if omitted.

.PARAMETER InstanceType
    EC2 instance type for cluster nodes. Default: t3.small.

.PARAMETER SkipTerraform
    Skip step 1 (assume infra already exists; just bootstrap).

.PARAMETER SkipBootstrap
    Run terraform but stop before ssh/ansible.

.EXAMPLE
    .\deploy-cluster.ps1
    .\deploy-cluster.ps1 -InstanceType t3.medium
    .\deploy-cluster.ps1 -SkipTerraform
#>
[CmdletBinding()]
param(
    [string]$MyIp,
    [string]$InstanceType = "t3.small",
    [switch]$SkipTerraform,
    [switch]$SkipBootstrap
)

$ErrorActionPreference = "Stop"

$repoRoot       = $PSScriptRoot
$tfDir          = Join-Path $repoRoot "terraform"
$ansDir         = Join-Path $repoRoot "ansible"
$keyName        = "k8s-cluster-key"
$keyPath        = Join-Path $tfDir "$keyName.pem"
$kubeconfigPath = Join-Path $repoRoot "k8s-kubeconfig"

function Assert-Exit($what) {
    if ($LASTEXITCODE -ne 0) { throw "$what failed (exit $LASTEXITCODE)" }
}

# --- Preflight ---------------------------------------------------------------
foreach ($cmd in 'terraform','ssh','scp','aws') {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        throw "$cmd not found on PATH. Install it before running this script."
    }
}

# Verify AWS credentials resolve before terraform spends 30s discovering they don't.
& aws sts get-caller-identity 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "AWS credentials not configured or invalid. Run 'aws configure' (or export AWS_* env vars) first."
}

# --- Step 1: Terraform -------------------------------------------------------
if (-not $SkipTerraform) {
    if (-not $MyIp) {
        Write-Host "==> Detecting public IP via ifconfig.me..." -ForegroundColor Cyan
        $MyIp = (Invoke-RestMethod -Uri "https://ifconfig.me/ip" -TimeoutSec 10).ToString().Trim()
    }
    Write-Host "==> my_ip_cidr=$MyIp  instance_type=$InstanceType" -ForegroundColor Cyan

    Push-Location $tfDir
    try {
        & terraform init
        Assert-Exit "terraform init"

        & terraform apply -auto-approve `
            -var "my_ip_cidr=$MyIp" `
            -var "instance_type=$InstanceType"
        Assert-Exit "terraform apply"
    } finally {
        Pop-Location
    }
}

# --- Read terraform outputs --------------------------------------------------
Push-Location $tfDir
try {
    $outputJson = & terraform output -json
    Assert-Exit "terraform output"
    $outputs = $outputJson | ConvertFrom-Json
} finally {
    Pop-Location
}

$jumpIp     = $outputs.jump_box_public_ip.value
$controlEip = $outputs.elastic_ip.value
$workerIps  = @($outputs.worker_public_ips.value)
Write-Host "==> jump box: $jumpIp  |  control plane EIP: $controlEip  |  workers: $($workerIps -join ', ')" -ForegroundColor Cyan

if (-not (Test-Path $keyPath)) {
    throw "SSH key not found at $keyPath. Run terraform first (drop -SkipTerraform)."
}

if ($SkipBootstrap) {
    Write-Host "==> Skipping bootstrap. Done." -ForegroundColor Green
    return
}

# --- Steps 2 & 3: Bootstrap via the jump box ---------------------------------
# UserKnownHostsFile=NUL avoids polluting known_hosts so re-runs after
# terraform destroy/apply (new jump box IP) work without manual cleanup.
$sshOpts = @(
    '-i', $keyPath,
    '-o', 'StrictHostKeyChecking=no',
    '-o', 'UserKnownHostsFile=NUL'
)
$jumpHost = "ubuntu@$jumpIp"

Write-Host "==> Creating remote dirs on jump box..." -ForegroundColor Cyan
& ssh @sshOpts $jumpHost "mkdir -p ~/cluster/terraform ~/cluster/ansible"
Assert-Exit "ssh mkdir"

Write-Host "==> Copying ansible playbook + SSH key to jump box..." -ForegroundColor Cyan
$ansFiles = @(Get-ChildItem -Path $ansDir | ForEach-Object { $_.FullName })
if ($ansFiles.Count -eq 0) { throw "No files found in $ansDir" }
& scp @sshOpts -r @ansFiles "${jumpHost}:~/cluster/ansible/"
Assert-Exit "scp ansible"

& scp @sshOpts $keyPath "${jumpHost}:~/cluster/terraform/$keyName.pem"
Assert-Exit "scp key"

& ssh @sshOpts $jumpHost "chmod 600 ~/cluster/terraform/$keyName.pem"
Assert-Exit "chmod key"

Write-Host "==> Waiting for cloud-init then running ansible-playbook (~5-10 min)..." -ForegroundColor Cyan
& ssh @sshOpts $jumpHost "cloud-init status --wait && cd ~/cluster/ansible && ansible-playbook site.yml"
Assert-Exit "ansible-playbook"

Write-Host "==> Pulling kubeconfig back to $kubeconfigPath..." -ForegroundColor Cyan
& scp @sshOpts "${jumpHost}:~/cluster/k8s-kubeconfig" $kubeconfigPath
Assert-Exit "scp kubeconfig"

Write-Host "==> Substituting demo IP placeholders with current values..." -ForegroundColor Cyan
& "$PSScriptRoot\Update-DemoIps.ps1"

Write-Host ""
Write-Host "==> Cluster ready." -ForegroundColor Green
Write-Host ""
Write-Host "    Set kubeconfig:" -ForegroundColor Gray
Write-Host "      `$env:KUBECONFIG = `"$kubeconfigPath`""
Write-Host "      kubectl get nodes"
Write-Host ""
Write-Host "    SSH to jump box:" -ForegroundColor Gray
Write-Host "      ssh -i `"$keyPath`" ubuntu@$jumpIp"
Write-Host "    SSH to control plane:" -ForegroundColor Gray
Write-Host "      ssh -i `"$keyPath`" ubuntu@$controlEip"
Write-Host "    SSH to workers:" -ForegroundColor Gray
for ($i = 0; $i -lt $workerIps.Count; $i++) {
    $n = $i + 1
    Write-Host "      ssh -i `"$keyPath`" ubuntu@$($workerIps[$i])    # worker-$n"
}
Write-Host ""
Write-Host "    Re-retrieve these later with:  cd terraform; terraform output" -ForegroundColor Gray
