# Helper functions for the Lab 7 defense. Load into the CURRENT PowerShell window with:
#   . .\lab7-functions.ps1      (dot, space, path)
$global:Lab7Values = Join-Path $PSScriptRoot 'charts\cavalry\values-minikube.yaml'

# New release: change the backend image tag in values-minikube.yaml
function global:Set-BackendTag([string]$Tag) {
  $t = [IO.File]::ReadAllText($global:Lab7Values)
  $t = $t -replace '(cavalry-backend\r?\n\s+tag: )"[^"]*"', ('${1}"' + $Tag + '"')
  [IO.File]::WriteAllText($global:Lab7Values, $t)
}

# Bad release: share of requests answered with HTTP 500 (0..1)
function global:Set-FailRate([string]$Rate) {
  $t = [IO.File]::ReadAllText($global:Lab7Values)
  $t = $t -replace '(name: FAIL_RATE\r?\n\s+value: )"[^"]*"', ('${1}"' + $Rate + '"')
  [IO.File]::WriteAllText($global:Lab7Values, $t)
}

# Ask Argo CD to re-read Git now instead of waiting up to 3 minutes
function global:Sync-Now {
  kubectl -n argocd annotate application cavalry argocd.argoproj.io/refresh=normal --overwrite | Out-Null
}

Write-Host 'Loaded: Set-BackendTag, Set-FailRate, Sync-Now' -ForegroundColor Green
