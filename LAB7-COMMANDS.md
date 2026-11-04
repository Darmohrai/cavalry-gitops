# ЛР-7: команди для здачі (коротко)

Усе в **PowerShell**, з теки `D:\uni\Java\cavalry-gitops`. Детально (що казати) — [LAB7-DEFENSE.md](LAB7-DEFENSE.md).

Паролі (лише локальний minikube): Grafana `admin` / `admin12345`; Postgres і Keycloak у `cavalry-secret` — `admin12345`.

---

## 1. Запуск перед здачею

```powershell
cd D:\uni\Java\cavalry-gitops
minikube start                                                            # підняти кластер
kubectl -n monitoring wait --for=condition=Ready pods --all --timeout=600s  # чекати, поки моніторинг готовий
kubectl -n argocd get applications                                        # усе має бути Synced / Healthy
kubectl get deploy load                                                   # фоновий трафік 1/1 (без нього аналіз падає)
kubectl argo rollouts get rollout cavalry-backend -n cavalry               # реліз Healthy, 5/5
```

Пароль Argo CD (логін `admin`):
```powershell
$p = kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}'; [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($p))
```

## 2. Вікна (кожне — окремий PowerShell)

| Вікно | Команда | Навіщо |
|---|---|---|
| Т1 | `while ($true) { kubectl -n argocd port-forward svc/argocd-server 8080:443; Start-Sleep 1 }` | Argo CD → https://localhost:8080 |
| Т2 | `while ($true) { kubectl -n monitoring port-forward svc/kps-grafana 3000:80; Start-Sleep 1 }` | Grafana → http://localhost:3000 |
| Т3 | `while ($true) { kubectl -n monitoring port-forward svc/kps-prometheus 9090:9090; Start-Sleep 1 }` | Prometheus → http://localhost:9090 |
| Т3b | `while ($true) { kubectl -n monitoring port-forward svc/kps-alertmanager 9093:9093; Start-Sleep 1 }` | Alertmanager (для алерту, необов'язково) |
| Т4 | `kubectl argo rollouts get rollout cavalry-backend -n cavalry --watch` | крок canary наживо |
| Т5 | `kubectl -n cavalry get analysisrun -w` | AnalysisRun-и наживо |
| Т6 | робоче вікно, див. нижче | git і команди |

У **Т6** спочатку вставити функції (один раз):
```powershell
cd D:\uni\Java\cavalry-gitops; git pull
function Set-BackendTag([string]$Tag) { $f='charts\cavalry\values-minikube.yaml'; $t=[IO.File]::ReadAllText((Resolve-Path $f)); $t=$t -replace '(cavalry-backend\r?\n\s+tag: )"[^"]*"', ('${1}"'+$Tag+'"'); [IO.File]::WriteAllText((Resolve-Path $f),$t) }
function Set-FailRate([string]$Rate) { $f='charts\cavalry\values-minikube.yaml'; $t=[IO.File]::ReadAllText((Resolve-Path $f)); $t=$t -replace '(name: FAIL_RATE\r?\n\s+value: )"[^"]*"', ('${1}"'+$Rate+'"'); [IO.File]::WriteAllText((Resolve-Path $f),$t) }
function Sync-Now { kubectl -n argocd annotate application cavalry argocd.argoproj.io/refresh=normal --overwrite | Out-Null }
```
- `Set-BackendTag` — міняє тег образу бекенду у values (новий реліз).
- `Set-FailRate` — міняє `FAIL_RATE` (частка штучних 500-х).
- `Sync-Now` — Argo CD одразу перечитує Git, без очікування 3 хв.

## 3. Демонстрація по пунктах

**Пункт 1 — стек моніторингу з Git**
```powershell
Get-ChildItem argocd-apps            # Application-и kps, loki, alloy у Git
kubectl -n argocd get applications   # усі Synced / Healthy
kubectl -n monitoring get pods       # усі Running
```

**Пункт 2 — ціль UP і метрика.** Це **не PowerShell**, а браузер (потрібен запущений port-forward з вікна Т3):
1. Відкрити http://localhost:9090 → меню **Status → Target health** (або Targets) → знайти `cavalry-backend`: 5/5 UP.
2. Натиснути **Query** зверху, вставити в поле запит нижче → **Execute** → вкладка **Graph** (видно лінію `200`, ≈ 15–20 req/s):
```promql
sum by (status) (rate(http_server_requests_seconds_count{namespace="cavalry",service="cavalry-backend"}[1m]))
```
3. А це — у PowerShell (вікно Т6), показати файл:
```powershell
Get-Content charts\cavalry\templates\servicemonitor.yaml   # як Prometheus знаходить бекенд
```

> Так само всі запити ` ```promql ` вставляються в Prometheus (Query) або Grafana → Explore → Prometheus, а ` ```logql ` — у Grafana → Explore → джерело **Loki** (режим **Code**). У PowerShell — лише блоки ` ```powershell `.

**Хороший реліз (запустити рано, йде ~6 хв фоном)**
```powershell
Set-BackendTag '1.6.0'            # якщо вже 1.6.0 — то '1.5.0'
git diff                          # показати зміну тегу
git commit -am "Release cavalry 1.6.0 (canary + analysis)"
git push
Sync-Now
```

**Пункт 3 — логи в Loki** (Grafana → Explore → Loki):
```logql
{namespace="cavalry", component="backend"}
{namespace="cavalry", component="backend"} | json | status >= 500
```

**Пункт 4 — дашборд з Git** (Grafana → Dashboards → Cavalry backend):
```powershell
Get-Content charts\cavalry\templates\dashboard.yaml              # ConfigMap з JSON дашборда
kubectl -n cavalry get configmap cavalry-dashboard --show-labels  # мітка grafana_dashboard=1
```

**Пункт 5 — навантаження і ще одна зміна**
```powershell
kubectl run hey --rm -it --restart=Never --image=williamyeh/hey -- -z 3m -c 20 http://cavalry-backend.cavalry.svc:8082/version   # RPS, CPU, p95 ростуть
kubectl run slow --rm -it --restart=Never --image=williamyeh/hey -- -z 2m -c 10 http://cavalry-backend.cavalry.svc:8082/slow     # p95 ≈ 1 с
kubectl -n cavalry get pods -l app.kubernetes.io/component=backend
kubectl -n cavalry delete pod <назва>                                                                                              # под зникає і відновлюється
```

**Хороший реліз завершився**
```powershell
kubectl -n cavalry get analysisrun                    # Successful
kubectl -n cavalry describe analysisrun <name>        # 4 виміри ≈ 1 (100 % успішних)
```

**Пункт 6 — поганий реліз сам відкочується (головне)**
```powershell
Get-Content charts\cavalry\templates\analysistemplate.yaml   # поріг 95 % успішних
Set-FailRate '0.5'                                           # canary-под віддає 50 % помилок
git commit -am "Release cavalry with FAIL_RATE=0.5 (bad release)"
git push
Sync-Now
```
Через ~3 хв: Т5 — AnalysisRun `Failed`, Т4 — `Degraded / RolloutAborted`, на дашборді — сплеск 5xx.
```powershell
kubectl -n cavalry describe analysisrun <name-Failed>        # чому провалився: значення ~0.9 < 0.95
```
У Loki — помилки лише з нового пода:
```logql
sum by (pod) (count_over_time({namespace="cavalry", component="backend"} | json | status >= 500 [1m]))
```
Повернути Git до робочого стану:
```powershell
git revert --no-edit HEAD    # скасувати поганий коміт
git push
Sync-Now                     # Rollout знову Healthy
```

**Алерт (за бажанням):** під час поганого релізу Prometheus → Alerts: `CavalryHighErrorRate` → `FIRING`.

## 4. Якщо щось не так

| Проблема | Команда |
|---|---|
| Аналіз `Failed` з `NaN` (немає трафіку) | `kubectl apply -f demo/load.yaml`, потім `kubectl argo rollouts retry rollout cavalry-backend -n cavalry` |
| Rollout застряг `Degraded`, Git уже правильний | `kubectl argo rollouts retry rollout cavalry-backend -n cavalry` |
| Поганий реліз не відкотився сам | `kubectl argo rollouts abort cavalry-backend -n cavalry` + `git revert` |
| Argo CD не бачить коміт | `Sync-Now` |
| Grafana/Prometheus не відкривається | почекати — цикл у Т2/Т3 перезапустить port-forward, F5 |
| Под `Pending` (мало пам'яті) | `kubectl -n cavalry describe pod <назва>` |

Шпаргалка PromQL/LogQL на прохання викладача — [LAB7-DEFENSE.md](LAB7-DEFENSE.md), розділ 5.

## 5. Після здачі

```powershell
kubectl delete -f demo/load.yaml   # прибрати фоновий трафік
minikube stop                      # зупинити кластер (стан зберігається)
```
