#Requires -Version 5.1
<#
.SYNOPSIS
    Substitutes <CONTROL_PLANE_IP> and <WORKER_N_IP> placeholders in the
    course demo markdown files with the real IPs from terraform output.

.DESCRIPTION
    Demo files use placeholders like <CONTROL_PLANE_IP> and <WORKER_1_IP>.
    This script replaces them (or the previously-rendered IPs from
    .demo-ip-state.json) with the current values from `terraform output`.

    Re-runnable: tracks last-rendered values so re-runs after a destroy +
    re-apply cycle find the stale IPs and rewrite them to the new ones.

    To revert demo files back to their committed placeholder form:
        git checkout -- 01/ 02/ 03/
#>
[CmdletBinding()] param()

$ErrorActionPreference = "Stop"

$repoRoot  = $PSScriptRoot
$tfDir     = Join-Path $repoRoot "terraform"
$stateFile = Join-Path $repoRoot ".demo-ip-state.json"
$demoDirs  = @("01", "02", "03") | ForEach-Object { Join-Path $repoRoot $_ }

# --- Read current IPs from terraform -----------------------------------------
Push-Location $tfDir
try {
    $outputJson = & terraform output -json
    if ($LASTEXITCODE -ne 0) { throw "terraform output failed (cluster not deployed?)" }
    $outputs = $outputJson | ConvertFrom-Json
} finally {
    Pop-Location
}

$current = [ordered]@{
    "CONTROL_PLANE_IP" = $outputs.elastic_ip.value
}
$workerIps = @($outputs.worker_public_ips.value)
for ($i = 0; $i -lt $workerIps.Count; $i++) {
    $current["WORKER_$($i + 1)_IP"] = $workerIps[$i]
}

# --- Read previous state (what was last written into the demo files) ---------
$previous = @{}
if (Test-Path $stateFile) {
    $obj = Get-Content $stateFile -Raw | ConvertFrom-Json
    foreach ($p in $obj.PSObject.Properties) { $previous[$p.Name] = $p.Value }
}

# --- Walk demo files and substitute ------------------------------------------
$mdFiles = $demoDirs | Where-Object { Test-Path $_ } |
    ForEach-Object { Get-ChildItem -Path $_ -Recurse -Filter "*.md" -File }

$changedCount = 0
foreach ($file in $mdFiles) {
    $content  = Get-Content -Path $file.FullName -Raw
    $original = $content

    foreach ($key in $current.Keys) {
        $placeholder = "<$key>"
        $newValue    = $current[$key]
        $oldValue    = $previous[$key]

        # Replace placeholder OR previously-rendered IP with current IP
        $content = $content.Replace($placeholder, $newValue)
        if ($oldValue -and $oldValue -ne $newValue) {
            $content = $content.Replace($oldValue, $newValue)
        }
    }

    if ($content -ne $original) {
        Set-Content -Path $file.FullName -Value $content -NoNewline
        $rel = $file.FullName.Substring($repoRoot.Length + 1)
        Write-Host "  updated: $rel" -ForegroundColor Cyan
        $changedCount++
    }
}

# --- Persist current state ---------------------------------------------------
$current | ConvertTo-Json | Set-Content -Path $stateFile -NoNewline

if ($changedCount -gt 0) {
    Write-Host "==> Updated $changedCount demo file(s) with current IPs." -ForegroundColor Green
} else {
    Write-Host "==> No demo files needed updating." -ForegroundColor Green
}
