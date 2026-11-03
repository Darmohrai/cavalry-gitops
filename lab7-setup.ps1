# Lab 7 one-time setup. Run in PowerShell (NOT from an IDE terminal that hides prompts):
#   powershell -ExecutionPolicy Bypass -File D:\uni\Java\cavalry-gitops\lab7-setup.ps1
# Does (LAB7.md, section 5):
#   1. app repo: push branch lab7-observability + tags v1.5.0 / v1.6.0 (GitHub Actions builds the images)
#   2. recreate minikube with 4 CPU / 8 GB (asks first), install Argo CD, create both Secrets (asks passwords)
#   3. push 1: "Add monitoring stack" only -> wait kps / loki / alloy Synced/Healthy
#   4. background traffic, pre-pull images 1.5.0 / 1.6.0
#   5. push 2: chart with ServiceMonitor, dashboard, AnalysisTemplate -> wait for the Rollout
# Log: lab7-setup.log (passwords are never printed)
$ErrorActionPreference = 'Continue'
$gitops = 'D:\uni\Java\cavalry-gitops'
$app    = 'D:\uni\Java\cavalry-lab7'          # git worktree of the app repo, branch lab7-observability
Start-Transcript -Path (Join-Path $gitops 'lab7-setup.log') -Force | Out-Null

function Step($m) { Write-Host "`n=== $m" -ForegroundColor Cyan }
function Fail($m) { Write-Host "FAILED: $m" -ForegroundColor Red; Stop-Transcript | Out-Null; exit 1 }
function Wait-Until($what, [int]$seconds, [scriptblock]$check) {
  $deadline = (Get-Date).AddSeconds($seconds)
  while ((Get-Date) -lt $deadline) {
    $r = & $check
    if ($r) { Write-Host "OK: $what"; return $true }
    Start-Sleep 10
  }
  Write-Host "TIMEOUT: $what" -ForegroundColor Yellow; return $false
}
function Read-Secret($prompt) {
  $s = Read-Host -AsSecureString $prompt
  [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s))
}
function App-Status($name) {
  kubectl -n argocd get application $name -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>$null
}

# ---------------------------------------------------------------- 1. images
Step '1/7 App repo: branch lab7-observability + tags v1.5.0 v1.6.0 (workflow "Release images")'
Set-Location $app
git push -u origin lab7-observability
if ($LASTEXITCODE -ne 0) { Fail 'git push lab7-observability' }
foreach ($v in '1.5.0', '1.6.0') {
  if (git tag -l "v$v") { Write-Host "tag v$v already exists locally" }
  else { git tag -a "v$v" -m "Release $v (Lab 7: metrics, JSON logs, FAIL_RATE)" HEAD }
  git push origin "v$v"
  if ($LASTEXITCODE -ne 0) { Fail "git push tag v$v" }
}
Write-Host 'Images build in GitHub Actions now (~5 min): https://github.com/Darmohrai/cavalry/actions'

# ---------------------------------------------------------------- 2. cluster
Step '2/7 minikube with 4 CPU / 8 GB'
$memMb = [int]((docker info --format '{{.MemTotal}}') / 1MB)
Write-Host "Docker Desktop memory: $memMb MB (minikube needs 8192 MB + overhead)"
if ($memMb -lt 9000) { Write-Host 'WARNING: give Docker Desktop at least 10 GB (Settings -> Resources or %UserProfile%\.wslconfig)' -ForegroundColor Yellow }
$ans = Read-Host 'Delete and recreate minikube now? All cluster state is rebuilt from Git (y/N)'
if ($ans -eq 'y') {
  minikube delete
  minikube start --cpus 4 --memory 8192
  if ($LASTEXITCODE -ne 0) { Fail 'minikube start (is Docker Desktop running and has enough memory?)' }
} else {
  Write-Host 'keeping the current cluster'
  kubectl cluster-info *> $null
  if ($LASTEXITCODE -ne 0) { minikube start; if ($LASTEXITCODE -ne 0) { Fail 'minikube start' } }
}

# ---------------------------------------------------------------- 3. Argo CD + secrets
Step '3/7 Argo CD and Secrets (passwords are NOT stored in Git)'
kubectl create namespace argocd 2>$null
kubectl apply -n argocd --server-side --force-conflicts -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml | Out-Null
if ($LASTEXITCODE -ne 0) { Fail 'Argo CD install' }
kubectl -n argocd wait --for=condition=Ready pods --all --timeout=600s

kubectl get namespace cavalry *> $null
if ($LASTEXITCODE -ne 0) { kubectl create namespace cavalry | Out-Null }
kubectl -n cavalry get secret cavalry-secret *> $null
if ($LASTEXITCODE -ne 0) {
  $pg = Read-Secret 'PostgreSQL password for cavalry-secret'
  $kc = Read-Secret 'Keycloak admin password for cavalry-secret'
  kubectl -n cavalry create secret generic cavalry-secret `
    --from-literal=POSTGRES_DB=ev_charge_db --from-literal=POSTGRES_USER=root `
    --from-literal=POSTGRES_PASSWORD=$pg --from-literal=KEYCLOAK_ADMIN=admin `
    --from-literal=KEYCLOAK_ADMIN_PASSWORD=$kc | Out-Null
  if ($LASTEXITCODE -ne 0) { Fail 'cavalry-secret' }
} else { Write-Host 'cavalry-secret already exists' }

kubectl get namespace monitoring *> $null
if ($LASTEXITCODE -ne 0) { kubectl create namespace monitoring | Out-Null }
kubectl -n monitoring get secret grafana-admin *> $null
if ($LASTEXITCODE -ne 0) {
  $gp = Read-Secret 'Grafana admin password (login: admin)'
  kubectl -n monitoring create secret generic grafana-admin `
    --from-literal=admin-user=admin --from-literal=admin-password=$gp | Out-Null
  if ($LASTEXITCODE -ne 0) { Fail 'grafana-admin' }
} else { Write-Host 'grafana-admin already exists' }

# ---------------------------------------------------------------- 4. push 1
Step '4/7 Push 1: monitoring stack only, then root'
Set-Location $gitops
git fetch origin
$c1 = git log --format=%H -n 1 --grep '^Add monitoring stack$'
if (-not $c1) { Fail 'commit "Add monitoring stack" not found' }
git push origin "${c1}:main"
if ($LASTEXITCODE -ne 0) { Fail 'git push (monitoring stack)' }
kubectl apply -f bootstrap/root.yaml
kubectl -n argocd annotate application root argocd.argoproj.io/refresh=normal --overwrite 2>$null | Out-Null
foreach ($a in 'kps', 'loki', 'alloy', 'argo-rollouts') {
  Wait-Until "Application $a Synced/Healthy" 900 { (App-Status $a) -eq 'Synced/Healthy' } | Out-Null
}
kubectl -n monitoring get pods
kubectl get crd servicemonitors.monitoring.coreos.com
if ($LASTEXITCODE -ne 0) { Fail 'CRD servicemonitors.monitoring.coreos.com is missing' }
Wait-Until 'Application cavalry Healthy (old chart, first start ~5 min)' 900 { (App-Status 'cavalry') -eq 'Synced/Healthy' } | Out-Null

# ---------------------------------------------------------------- 5. traffic + images
Step '5/7 Background traffic and pre-pulled images'
kubectl apply -f demo/load.yaml
foreach ($v in '1.5.0', '1.6.0') {
  $img = "ghcr.io/darmohrai/cavalry/cavalry-backend:$v"
  Wait-Until "image $img" 1200 { minikube image pull $img *> $null; $LASTEXITCODE -eq 0 } | Out-Null
}

# ---------------------------------------------------------------- 6. push 2
Step '6/7 Push 2: ServiceMonitor, dashboard, AnalysisTemplate, image 1.5.0'
git push origin main
if ($LASTEXITCODE -ne 0) { Fail 'git push (chart)' }
kubectl -n argocd annotate application root argocd.argoproj.io/refresh=normal --overwrite | Out-Null
kubectl -n argocd annotate application cavalry argocd.argoproj.io/refresh=normal --overwrite | Out-Null
Wait-Until 'AnalysisTemplate cavalry-success-rate exists' 300 {
  kubectl -n cavalry get analysistemplate cavalry-success-rate *> $null; $LASTEXITCODE -eq 0
} | Out-Null
kubectl argo rollouts status cavalry-backend -n cavalry --timeout 20m
kubectl argo rollouts get rollout cavalry-backend -n cavalry
kubectl -n cavalry get analysisrun

# ---------------------------------------------------------------- 7. summary
Step '7/7 State'
kubectl -n argocd get applications
kubectl -n cavalry get servicemonitor,prometheusrule,configmap -l app.kubernetes.io/instance=cavalry
git status -sb
git log --oneline -4
Write-Host "`nDONE. Next: LAB7.md section 6 (terminals) and LAB7-DEFENSE.md (demo script)." -ForegroundColor Green
Stop-Transcript | Out-Null
