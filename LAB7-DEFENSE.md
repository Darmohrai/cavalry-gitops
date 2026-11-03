# ЛР-7: як здавати (детальний сценарій захисту)

Пояснення, **що** і **чому** зроблено, — у [LAB7.md](LAB7.md). Тут — **порядок дій**: що підготувати, які вікна відкрити, які команди вводити, що має з'явитися на екрані і що сказати викладачу.

Усі команди — **PowerShell**, з теки `D:\uni\Java\cavalry-gitops`.

> Виводи нижче розрахункові (на кластері сценарій ще не проганявся). Пройдіть його повністю **на репетиції** напередодні й поправте час/цифри під свій ноутбук.

---

## Зміст

0. [Що викладач хоче побачити (чек-лист)](#0-що-викладач-хоче-побачити-чек-лист)
1. [Один раз заздалегідь: lab7-setup.ps1](#1-один-раз-заздалегідь-lab7-setupps1)
2. [За 15 хвилин до захисту: запуск](#2-за-15-хвилин-до-захисту-запуск)
3. [Вікна й термінали](#3-вікна-й-термінали)
4. [Сценарій захисту крок за кроком](#4-сценарій-захисту-крок-за-кроком)
5. [Довільні запити PromQL / LogQL (шпаргалка)](#5-довільні-запити-promql--logql-шпаргалка)
6. [Алерт (пункт 6d*, за бажанням)](#6-алерт-пункт-6d-за-бажанням)
7. [Повернення у стартовий стан](#7-повернення-у-стартовий-стан)
8. [Якщо щось пішло не так під час захисту](#8-якщо-щось-пішло-не-так-під-час-захисту)
9. [Короткі відповіді «одним реченням»](#9-короткі-відповіді-одним-реченням)

---

## 0. Що викладач хоче побачити (чек-лист)

З методички, розділ 7 «Захист: лайв-демонстрація»:

- [ ] Argo CD: `kps`, `loki`, `alloy` (і решта) `Synced / Healthy`; усі поди в `monitoring` `Running`; Grafana відкривається
- [ ] **Prometheus → Status → Targets**: ціль `cavalry-backend` у стані **UP**; запит до своєї метрики
- [ ] **Дашборд під навантаженням**: зростають RPS, p95 і CPU
- [ ] Ще одна зміна на вибір (у нас: повільний ендпоінт `/slow` і/або `kubectl delete pod`)
- [ ] **Логи в Loki** (Grafana Explore) і фільтр по 5xx запитом LogQL
- [ ] **Поганий реліз, який сам відкочується**: коміт з `FAIL_RATE` → AnalysisRun `Failed` → abort → stable; сплеск помилок на дашборді; помилки в Loki лише з нового пода; `git revert`
- [ ] Написати довільний запит PromQL або LogQL на прохання викладача
- [ ] (бажано) дашборд у Git як ConfigMap; (за бажанням) алерт у стані `Firing`

---

## 1. Один раз заздалегідь: lab7-setup.ps1

Зробити **за день до захисту** (займає 30–60 хв, більшу частину — очікування).

1. Docker Desktop → Settings → Resources: пам'ять **≥ 10 ГБ** (або в `%UserProfile%\.wslconfig`:
   ```ini
   [wsl2]
   memory=12GB
   processors=6
   ```
   потім `wsl --shutdown` і перезапуск Docker Desktop).
2. Запустити скрипт у звичайному вікні PowerShell:
   ```powershell
   powershell -ExecutionPolicy Bypass -File D:\uni\Java\cavalry-gitops\lab7-setup.ps1
   ```
   Він спитає:
   - `Delete and recreate minikube now?` → `y` (кластер відновиться з Git, як і має бути в GitOps);
   - паролі PostgreSQL і Keycloak для `cavalry-secret` (ті самі, що в ЛР-5, або нові — БД все одно порожня після `minikube delete`);
   - пароль Grafana (логін `admin`). **Запишіть його.**
3. Наприкінці має бути `DONE.` і:
   ```
   NAME            SYNC STATUS   HEALTH STATUS
   alloy           Synced        Healthy
   argo-rollouts   Synced        Healthy
   cavalry         Synced        Healthy
   kps             Synced        Healthy
   loki            Synced        Healthy
   root            Synced        Healthy
   ```
   Якщо щось не так — `lab7-setup.log` і розділ 11 у [LAB7.md](LAB7.md).
4. **Перевірка дашборда з Git** (вимога пункту 4 методички): відкрийте Grafana (розділ 3, Т2) → Dashboards → **Cavalry backend**. Він має бути позначений як provisioned. Якщо робили ще й ручну копію в UI — видаліть її; той, що з Git, лишається.
5. **Генеральна репетиція**: пройдіть розділ 4 повністю, потім розділ 7.

---

## 2. За 15 хвилин до захисту: запуск

### 2.1. Кластер

```powershell
cd D:\uni\Java\cavalry-gitops
minikube start
kubectl -n argocd wait --for=condition=Ready pods --all --timeout=600s
kubectl -n monitoring wait --for=condition=Ready pods --all --timeout=600s
kubectl -n cavalry get pods                  # усі Running, 5 подів cavalry-backend-...
kubectl -n argocd get applications           # усі Synced / Healthy
kubectl get deploy load                      # фоновий трафік: 1/1
```

Якщо `load` немає: `kubectl apply -f demo/load.yaml`. **Без трафіку аналіз завжди провалюється** (0/0 = NaN).

### 2.2. Пароль Argo CD

Після `minikube delete` пароль скинувся на початковий:

```powershell
$p = kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}'
[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($p))
```

(Можна повернути старий: після `argocd login` → `argocd account update-password`.)

### 2.3. Стартовий стан

```powershell
kubectl argo rollouts get rollout cavalry-backend -n cavalry
```

Очікувано: `Status: ✔ Healthy`, `Images: ghcr.io/darmohrai/cavalry/cavalry-backend:1.5.0 (stable)` (або `1.6.0`, якщо вже робили хороший реліз), `Desired 5, Ready 5`. У `values-minikube.yaml`: `FAIL_RATE` = `"0"`.

---

## 3. Вікна й термінали

Відкрийте **шість** вікон PowerShell. Port-forward-и загорнуті в цикл, бо вони обриваються при рестарті пода.

**Т1: Argo CD UI** → https://localhost:8080 (`admin` / пароль з 2.2):
```powershell
while ($true) { kubectl -n argocd port-forward svc/argocd-server 8080:443; Start-Sleep 1 }
```

**Т2: Grafana** → http://localhost:3000 (`admin` / пароль Grafana):
```powershell
while ($true) { kubectl -n monitoring port-forward svc/kps-grafana 3000:80; Start-Sleep 1 }
```

**Т3: Prometheus** → http://localhost:9090, **і Alertmanager** → http://localhost:9093:
```powershell
Start-Job { while ($true) { kubectl -n monitoring port-forward svc/kps-alertmanager 9093:9093; Start-Sleep 1 } } | Out-Null
while ($true) { kubectl -n monitoring port-forward svc/kps-prometheus 9090:9090; Start-Sleep 1 }
```

**Т4: стан релізу:**
```powershell
kubectl argo rollouts get rollout cavalry-backend -n cavalry --watch
```

**Т5: AnalysisRun-и:**
```powershell
kubectl -n cavalry get analysisrun -w
```

**Т6: робочий** (Git, навантаження, команди). Оголосити функції один раз:
```powershell
cd D:\uni\Java\cavalry-gitops
git pull
function Set-BackendTag([string]$Tag) {
  $f = Join-Path (Get-Location) 'charts\cavalry\values-minikube.yaml'
  $text = [IO.File]::ReadAllText($f)
  $text = $text -replace '(cavalry-backend\r?\n\s+tag: )"[^"]*"', ('${1}"' + $Tag + '"')
  [IO.File]::WriteAllText($f, $text)
}
function Set-FailRate([string]$Rate) {
  $f = Join-Path (Get-Location) 'charts\cavalry\values-minikube.yaml'
  $text = [IO.File]::ReadAllText($f)
  $text = $text -replace '(name: FAIL_RATE\r?\n\s+value: )"[^"]*"', ('${1}"' + $Rate + '"')
  [IO.File]::WriteAllText($f, $text)
}
function Sync-Now { kubectl -n argocd annotate application cavalry argocd.argoproj.io/refresh=normal --overwrite | Out-Null }
```

`Sync-Now` просить Argo CD перечитати Git одразу, а не чекати до 3 хв опитування.

**Браузер, вкладки заздалегідь:**
1. Argo CD → застосунок `cavalry` (дерево).
2. Grafana → Dashboards → **Cavalry backend** (Last 15 minutes, refresh 10s — вже збережено в JSON).
3. Grafana → Explore → джерело **Loki**.
4. Prometheus → Status → Targets.
5. Prometheus → Alerts.

---

## 4. Сценарій захисту крок за кроком

Загалом ≈ 20–25 хв. Хороший реліз (крок 4.3) йде ≈ 6 хв сам по собі — запускаємо його рано і показуємо інші пункти, поки він іде.

### 4.1. Пункт 1: стек моніторингу з Git (2 хв)

Т6:
```powershell
Get-ChildItem argocd-apps
kubectl -n argocd get applications
kubectl -n monitoring get pods
```

Очікувано в `monitoring` (усі `Running`):
```
alertmanager-kps-alertmanager-0                 2/2   Running
alloy-...                                       2/2   Running
kps-grafana-...                                 3/3   Running
kps-kube-state-metrics-...                      1/1   Running
kps-operator-...                                1/1   Running
kps-prometheus-node-exporter-...                1/1   Running
loki-0                                          2/2   Running
loki-gateway-...                                1/1   Running
prometheus-kps-prometheus-0                     2/2   Running
```

**Сказати:** «Стек описано трьома Application у `argocd-apps/` — по одному на чарт, версії зафіксовані. Root (App of Apps) підхопив їх сам. `kps` — це Prometheus Operator, Prometheus, Alertmanager і Grafana; Loki в режимі одного процесу з файловим сховищем; Alloy читає логи всіх подів через Kubernetes API і пушить у Loki. Пароль Grafana — в Secret, створеному вручну, бо в Git паролі не кладемо, а чарт при кожному рендері Argo CD генерував би новий. Для kps обов'язковий ServerSideApply — CRD завеликі для звичайного apply.»

Показати Grafana (вкладка 2) — відкривається, залогінені.

### 4.2. Пункт 2: ціль UP і запит до метрики (2 хв)

Вкладка **Prometheus → Status → Targets** (у Prometheus 3 — меню *Status → Target health*). Знайти `serviceMonitor/cavalry/cavalry-backend/0`: **5/5 up**.

**Сказати:** «ServiceMonitor лежить у чарті застосунку. Він вибирає Service бекенду за мітками і порт за ім'ям `http`. Оператор перетворює його на конфіг Prometheus, Prometheus скрейпить кожен под окремо на `/actuator/prometheus` кожні 15 секунд.»

Вкладка **Query** (Graph):
```promql
sum by (status) (rate(http_server_requests_seconds_count{namespace="cavalry",service="cavalry-backend"}[1m]))
```
Очікувано: лінія `200` ≈ 15–20 req/s (фоновий `load`).

**Сказати про метрику:** «Метрику пише Spring Boot Actuator через Micrometer: лічильник `_count` і гістограма `_bucket` з мітками method, uri, status. `uri` — шаблон маршруту, не реальний URL, тому кардинальність мала.»

Показати сирі метрики одного пода (за бажанням):
```powershell
kubectl -n cavalry run m --rm -it --restart=Never --image=curlimages/curl -- curl -s http://cavalry-backend:8082/actuator/prometheus | Select-String 'http_server_requests_seconds_count'
```

Показати файл:
```powershell
Get-Content charts\cavalry\templates\servicemonitor.yaml
```

### 4.3. Старт хорошого релізу 1.5.0 → 1.6.0 (1 хв + фоном)

Т6:
```powershell
Set-BackendTag '1.6.0'
git diff
git commit -am "Release cavalry 1.6.0 (canary + analysis)"
git push
Sync-Now
```

(Якщо зараз уже `1.6.0` — випускайте `'1.5.0'`, код однаковий.)

**Сказати:** «Ручної паузи з ЛР-6 більше немає. Після 20 % і хвилини накопичення метрик Rollout запускає крок analysis: AnalysisRun 4 рази з інтервалом 30 с питає Prometheus про частку успішних запитів. Поріг 95 %.»

Т4 за ≈ 1–2 хв: `Step: 1/7`, `SetWeight: 20`, 1 под нового ReplicaSet → `Step 2/7` (пауза 60 с) → `Step 3/7`, у Т5 з'являється `cavalry-backend-...-3` `Running`.

Поки йде — переходимо до 4.4–4.6, повертаємось до релізу в 4.7.

### 4.4. Пункт 3: логи в Loki (3 хв)

Вкладка **Explore → Loki**, режим *Code*:

```logql
{namespace="cavalry", component="backend"}
```
Розгорнути рядок: видно JSON з `@timestamp`, `level`, `message`, `method`, `route`, `status`, `duration_ms`, `version`.

```logql
{namespace="cavalry", component="backend"} | json | status >= 500
```
Зараз порожньо (помилок немає) — це нормально, повторимо під час поганого релізу.

```logql
{namespace="cavalry", component="backend"} | json | route="/version" | line_format "{{.pod}} {{.status}} {{.duration_ms}}ms"
```

**Сказати:** «Логи — JSON у stdout, по об'єкту на рядок: це вбудований structured logging Spring Boot 3.4+, формат logstash, увімкнений у профілі prod. Окремий фільтр пише рядок на кожен запит, поля кладе в MDC. Alloy забирає логи всіх подів через API і ставить мітки namespace, pod, app, component. Loki індексує лише мітки, а поля JSON розбирає `| json` під час запиту — тому status і route не мітки, а поля.»

### 4.5. Пункт 4: дашборд з Git (2 хв)

Вкладка **Cavalry backend**. Пройтися по панелях: RPS, частка 5xx (лінія порогу 5 %), p95/p50, 5xx по подах, RPS по ReplicaSet (зараз видно **два** хеші — stable і canary з кроку 4.3), CPU, пам'ять, логи помилок.

Т6:
```powershell
Get-Content charts\cavalry\templates\dashboard.yaml
kubectl -n cavalry get configmap cavalry-dashboard --show-labels
```

**Сказати:** «Дашборд зберігається в Git як JSON у чарті. Шаблон кладе його в ConfigMap з міткою `grafana_dashboard: "1"`, sidecar Grafana шукає такі ConfigMap-и в усіх namespace і завантажує. Змінити його в UI не можна — лише експорт і коміт, як і все інше.»

За бажанням довести, що він з Git:
```powershell
kubectl -n cavalry delete configmap cavalry-dashboard
# у Grafana через ~10-30 с дашборд зникає зі списку
argocd app sync cavalry        # або Argo CD UI → cavalry → Sync
# з'являється знову
```
(selfHeal для `cavalry` вимкнений з ЛР-5, тому повертаємо синхронізацією.)

### 4.6. Пункт 5: навантаження і «інша зміна» (4 хв)

Т6, короткий потужний тест (20 клієнтів, 3 хв):
```powershell
kubectl run hey --rm -it --restart=Never --image=williamyeh/hey -- -z 3m -c 20 http://cavalry-backend.cavalry.svc:8082/version
```

На дашборді за 20–40 с: **RPS** зростає з ≈ 20 до сотень req/s, **CPU** подів росте, **p95** трохи піднімається. Після 3 хв `hey` друкує зведення (Requests/sec, гістограму затримок) — теж можна показати.

**Інша зміна, варіант A — повільний ендпоінт** (наочніше для p95):
```powershell
kubectl run slow --rm -it --restart=Never --image=williamyeh/hey -- -z 2m -c 10 http://cavalry-backend.cavalry.svc:8082/slow
```
На панелях «p95» і «p95 по маршрутах»: `/slow` ≈ 0,9–1 с, `/version` лишається на мілісекундах.

**Сказати:** «`/slow` спить випадково 0–1 с. Середнє було б ≈ 0,5 с, а p95 — ≈ 0,95 с: 5 % запитів повільніші за цю межу. Через це для SLO дивляться на перцентилі, а не на середнє. p95 рахується з бакетів гістограми функцією histogram_quantile.»

**Варіант B — вимкнення пода:**
```powershell
kubectl -n cavalry get pods -l app.kubernetes.io/component=backend
kubectl -n cavalry delete pod <одна з назв>
```
На CPU/пам'яті лінія пода обривається, з'являється новий под (≈ 1–2 хв старт Spring Boot); у Targets на час старту 4/5 up. RPS не падає — Service розподіляє трафік на решту.

### 4.7. Хороший реліз завершився (1 хв)

Т5:
```
NAME                       STATUS       AGE
cavalry-backend-xxxxx-3    Successful   ...
```
Т4: `Status: ✔ Healthy`, `Images: ...:1.6.0 (stable)`.

```powershell
kubectl -n cavalry describe analysisrun <name> | Select-String -Pattern 'Phase|Value|Successful|Count'
```
Видно 4 виміри зі значенням ≈ `1` (100 % успішних).

### 4.8. Пункт 6: поганий реліз, який сам відкочується (6–7 хв) — **головне**

Переконайтеся: дашборд відкритий, Т4 і Т5 видно, `load` працює.

Т6:
```powershell
Get-Content charts\cavalry\templates\analysistemplate.yaml
Set-FailRate '0.5'
git diff                     # value: "0" -> "0.5"
git commit -am "Release cavalry with FAIL_RATE=0.5 (bad release)"
git push
Sync-Now
```

**Сказати, поки чекаємо:** «FAIL_RATE змінює шаблон пода, тож Rollout сприймає це як новий реліз. Один canary-под з п'яти відповідає 500 на половину своїх запитів — по всьому сервісу це ≈ 10 % помилок, успішних 90 %, а поріг 95 %. Ніхто нічого не натискатиме — рішення прийме аналіз.»

Що відбувається (≈ час від push):

| Час | Т4 / Т5 | Дашборд |
|---|---|---|
| 0:30–1:30 | `Step 1/7`, новий ReplicaSet, 1 под стартує | — |
| ~1:30 | под Ready, `Step 2/7` (пауза 60 с) | «Частка 5xx» ≈ 10 %, «5xx по подах» — **одна** лінія (canary-под) |
| ~2:30 | `Step 3/7`, у Т5 новий AnalysisRun `Running` | лінія 5xx вище порогу 5 % |
| ~2:30 | 1-й вимір ≈ 0.90 → Failed (1 ≤ failureLimit) | |
| ~3:00 | 2-й вимір ≈ 0.90 → **AnalysisRun `Failed`** | |
| ~3:00 | Т4: `Status: ✖ Degraded`, `Message: RolloutAborted: Rollout aborted update to revision N: Metric "success-rate" assessed Failed ...`, canary ReplicaSet `ScaledDown` | 5xx падає до 0 протягом ~1 хв (вікно `rate [1m]`) |

Показати:
```powershell
kubectl -n cavalry get analysisrun
kubectl -n cavalry describe analysisrun <name-з-Failed>
```
У `describe`: `Phase: Failed`, `Message: Metric "success-rate" assessed Failed due to failed (2) > failureLimit (1)`, у `Measurements` — значення `[0.89...]`, `[0.90...]` з `Phase: Failed`.

**Argo CD UI**: `cavalry` — `Synced / Degraded`.
**Сказати:** «Synced, бо кластер відповідає Git: у Git справді FAIL_RATE 0.5. Degraded, бо Rollout перервав реліз і працює на stable. Тобто Git зараз описує версію, яку автоматика відкинула, — це треба виправити в Git.»

**Логи помилок лише з нового пода** — Explore → Loki:
```logql
{namespace="cavalry", component="backend"} | json | status >= 500
```
```logql
sum by (pod) (count_over_time({namespace="cavalry", component="backend"} | json | status >= 500 [1m]))
```
Друга дає **одну** лінію — под з хешем нового ReplicaSet (порівняйте з Т4: `cavalry-backend-<hash>-...`). Поле `version` тут однакове (образ той самий, змінилась лише змінна), розрізняємо **за подом / ReplicaSet**.

Те саме на дашборді: панель «Логи помилок бекенду» — рядки лише одного пода; «RPS по ReplicaSet» — хеш canary зник після abort.

**Завершити відкат через Git**, Т6:
```powershell
git log --oneline -3
git revert --no-edit HEAD
git push
Sync-Now
```
За ≈ 10–30 с: Т4 `✔ Healthy` (нових подів не створюється — шаблон знову дорівнює stable), Argo CD `Synced / Healthy`.

**Сказати:** «Revert повертає Git до стану, що відповідає stable. Rollout бачить, що бажаний шаблон пода збігається зі stable ReplicaSet, і просто знімає Degraded. Історія в Git показує і поганий реліз, і відкат — це аудит.»

---

## 5. Довільні запити PromQL / LogQL (шпаргалка)

Викладач може попросити написати запит. Скорочення: `C = http_server_requests_seconds_count`, `S = namespace="cavalry",service="cavalry-backend"`.

### PromQL

| Питання | Запит |
|---|---|
| RPS усього сервісу | `sum(rate(http_server_requests_seconds_count{namespace="cavalry",service="cavalry-backend"}[1m]))` |
| RPS по маршрутах | `sum by (uri) (rate(http_server_requests_seconds_count{namespace="cavalry"}[1m]))` |
| RPS по подах | `sum by (pod) (rate(http_server_requests_seconds_count{namespace="cavalry"}[1m]))` |
| RPS по статусах | `sum by (status) (rate(http_server_requests_seconds_count{namespace="cavalry"}[1m]))` |
| Частка 5xx | `sum(rate(http_server_requests_seconds_count{namespace="cavalry",status=~"5.."}[1m])) / sum(rate(http_server_requests_seconds_count{namespace="cavalry"}[1m]))` |
| Частка успішних (як в аналізі) | те саме з `status!~"5.."` у чисельнику |
| Скільки запитів за 5 хв | `sum(increase(http_server_requests_seconds_count{namespace="cavalry"}[5m]))` |
| p95 / p99 | `histogram_quantile(0.95, sum by (le) (rate(http_server_requests_seconds_bucket{namespace="cavalry"}[1m])))` (0.99 для p99) |
| p95 по маршрутах | `histogram_quantile(0.95, sum by (le, uri) (rate(http_server_requests_seconds_bucket{namespace="cavalry"}[1m])))` |
| Середня затримка | `sum(rate(http_server_requests_seconds_sum{namespace="cavalry"}[1m])) / sum(rate(http_server_requests_seconds_count{namespace="cavalry"}[1m]))` |
| Максимальна затримка | `max(http_server_requests_seconds_max{namespace="cavalry"})` |
| Топ-3 маршрути за RPS | `topk(3, sum by (uri) (rate(http_server_requests_seconds_count{namespace="cavalry"}[5m])))` |
| Чи живі цілі | `up{namespace="cavalry"}` (1 = UP) / `sum(up{service="cavalry-backend"})` |
| CPU подів | `sum by (pod) (rate(container_cpu_usage_seconds_total{namespace="cavalry",container!=""}[1m]))` |
| Пам'ять подів | `sum by (pod) (container_memory_working_set_bytes{namespace="cavalry",container!=""})` |
| Рестарти контейнерів | `sum by (pod) (kube_pod_container_status_restarts_total{namespace="cavalry"})` |
| Скільки подів Ready | `sum(kube_pod_status_ready{namespace="cavalry",condition="true"})` |
| Пам'ять JVM (heap) | `sum by (pod) (jvm_memory_used_bytes{namespace="cavalry",area="heap"})` |
| Потоки JVM | `jvm_threads_live_threads{namespace="cavalry"}` |
| RPS stable vs canary | `sum by (rollouts_pod_template_hash) (rate(http_server_requests_seconds_count{namespace="cavalry"}[1m]))` |

Правила: для counter — завжди `rate`/`increase`, потім `sum`; `sum by (міта)` залишає лише цю мітку; `=~` — регулярка, `!~` — заперечення.

### LogQL

| Питання | Запит |
|---|---|
| Усі логи бекенду | `{namespace="cavalry", component="backend"}` |
| Логи одного пода | `{namespace="cavalry", pod="cavalry-backend-..."}` |
| Помилки | `{namespace="cavalry", component="backend"} \| json \| level="ERROR"` |
| 5xx | `{namespace="cavalry", component="backend"} \| json \| status >= 500` |
| 4xx | `... \| json \| status >= 400 \| status < 500` |
| Повільні > 200 мс | `... \| json \| duration_ms > 200` |
| Конкретний маршрут | `... \| json \| route="/slow"` |
| Пошук тексту | `{namespace="cavalry"} \|= "Exception"` (`!=` — без цього тексту, `\|~` — регулярка) |
| Красивий вивід | `... \| json \| line_format "{{.pod}} {{.method}} {{.route}} {{.status}} {{.duration_ms}}ms"` |
| Кількість 5xx за хвилину по подах | `sum by (pod) (count_over_time({namespace="cavalry", component="backend"} \| json \| status >= 500 [1m]))` |
| Рядків за секунду | `sum(rate({namespace="cavalry", component="backend"}[1m]))` |
| Кількість по статусах | `sum by (status) (count_over_time({namespace="cavalry", component="backend"} \| json \| __error__="" [5m]))` |
| p95 тривалості з логів | `quantile_over_time(0.95, {namespace="cavalry", component="backend"} \| json \| unwrap duration_ms [1m]) by (route)` |
| Логи Keycloak / Postgres | `{namespace="cavalry", component="keycloak"}` / `component="postgres"` |
| Логи Argo Rollouts | `{namespace="argo-rollouts"}` |

Правило: спочатку селектор міток у `{}` (обов'язковий, по ньому працює індекс), далі конвеєр `|`.

---

## 6. Алерт (пункт 6d*, за бажанням)

Правило `CavalryHighErrorRate` (> 5 % 5xx, `for: 30s`) у `templates/prometheusrule.yaml`.

Під час кроку 4.8 відкрийте **Prometheus → Alerts**: `CavalryHighErrorRate` через ≈ 30–60 с після появи помилок стає `PENDING`, ще через 30 с — **`FIRING`**. Те саме — Alertmanager http://localhost:9093. Після abort і revert алерт гасне за 1–2 хв.

**Чому `for: 30s`, а не `1m` з методички:** canary перериваються через ≈ 90 с після перших помилок; з `1m` алерт часто ще `Pending`, коли помилки вже зникли. Методичка про це попереджає.

Якщо все одно не встиг — показати окремо, вимкнувши аналіз (поганий реліз пройде повністю, тому лише в кінці захисту):

```powershell
# прибрати крок analysis і вимкнути шаблон: values-minikube.yaml ->
#   analysis.enabled: false і видалити 3 рядки "- analysis: / templates: / - templateName"
Set-FailRate '0.5'; git commit -am "Alert demo: bad release without analysis"; git push; Sync-Now
# через ~4-5 хв (canary пройде всі кроки) частка 5xx = 50 % -> FIRING
git revert --no-edit HEAD; git push; Sync-Now
```

---

## 7. Повернення у стартовий стан

Після сценарію: stable — `1.6.0` (або `1.5.0`), `FAIL_RATE="0"`, `Healthy`. Повторити можна одразу: хороший реліз — `Set-BackendTag` на інший з двох тегів, поганий — знову `Set-FailRate '0.5'`.

Перевірка:
```powershell
Select-String -Path charts\cavalry\values-minikube.yaml -Pattern 'tag: "1\.[56]|value: "'
kubectl argo rollouts get rollout cavalry-backend -n cavalry
kubectl -n argocd get applications
```

Якщо Rollout застряг у `Degraded`, а Git уже правильний:
```powershell
kubectl argo rollouts retry rollout cavalry-backend -n cavalry   # або
kubectl argo rollouts promote cavalry-backend -n cavalry --full
```

Прибрати навантаження після захисту: `kubectl delete -f demo/load.yaml`. Зупинити кластер: `minikube stop` (стан зберігається).

---

## 8. Якщо щось пішло не так під час захисту

| Що бачите | Що робити |
|---|---|
| Хороший реліз: AnalysisRun `Failed` зі значенням `NaN` | трафіку немає: `kubectl get deploy load` → `kubectl apply -f demo/load.yaml`; потім `kubectl argo rollouts retry rollout cavalry-backend -n cavalry` |
| AnalysisRun `Error` | `kubectl -n cavalry describe analysisrun <name>` → помилка запиту/адреси; перевірити запит вручну в Prometheus |
| Argo CD не бачить коміт | `Sync-Now` або Argo CD UI → `cavalry` → Refresh |
| Grafana / Prometheus не відкривається | port-forward упав: цикл у Т2/Т3 перезапустить його; F5 у браузері |
| У Targets ціль `DOWN` | под ще стартує (Spring Boot 1–2 хв) — почекати |
| Панелі порожні | діапазон часу Last 15 minutes; `rate [1m]` потребує ≥ 2 скрейпів (30 с) |
| Новий под `Pending` | бракує пам'яті: `kubectl describe pod` → `Insufficient memory`; `kubectl scale deploy load --replicas=1`, видалити `hey`/`slow` поди |
| Під'їхало довго, час іде | розповідати теорію з [LAB7.md](LAB7.md) розділ 12, показувати конфіги, поки йде реліз |

Запасний план для пункту 6, якщо поганий реліз не відкотився сам за 5 хв: показати `kubectl -n cavalry describe analysisrun`, пояснити, чому, і відкотити вручну `kubectl argo rollouts abort cavalry-backend -n cavalry` + `git revert`.

---

## 9. Короткі відповіді «одним реченням»

- **Чому метрики в Prometheus, а не в логах?** Метрики — дешеві агрегати для графіків і алертів; логи — дорогі деталі окремих подій.
- **Що таке ServiceMonitor?** CRD, через який чарт застосунку каже Prometheus Operator, що скрейпити.
- **Звідки CPU і пам'ять подів?** cAdvisor у kubelet, Prometheus скрейпить його через ServiceMonitor kps.
- **Чому `uri`, а не реальний шлях?** Кардинальність: кожен id дав би новий часовий ряд.
- **Чому гістограма, а не summary?** Бакети гістограми можна складати між подами і рахувати p95 по всьому сервісу.
- **Чому Loki не індексує текст?** Індекс лише міток — дешево; текст фільтрується під час запиту.
- **Чому `status` не мітка Loki?** Мітки мають малу кардинальність і визначають потоки; поля розбираються `| json`.
- **Що буде, якщо Prometheus впаде під час релізу?** Виміри стануть `Error`; після 4 поспіль — AnalysisRun `Error` і abort (безпечна сторона).
- **Чому без трафіку аналіз провалюється?** `0/0 = NaN`, а `NaN >= 0.95` хибне — відсутність даних не доказ якості.
- **Що робить failureLimit: 1?** Один невдалий вимір прощається (випадковий сплеск), другий — провал.
- **Чому Argo CD `Synced`, але `Degraded`?** Кластер відповідає Git, але Rollout сам відмовився від нової ревізії.
- **Навіщо `git revert`, якщо Rollout уже на stable?** Щоб Git знову описував те, що реально працює, і наступна синхронізація не почала поганий реліз знову.
- **Canary vs blue-green для аналізу?** Canary — аналіз на частині реального трафіку; blue-green — `prePromotionAnalysis` на preview-сервісі з окремим трафіком, користувачі погану версію не бачать зовсім.
