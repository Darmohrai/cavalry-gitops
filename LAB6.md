# Лабораторна робота №6. Progressive delivery: canary з Argo Rollouts

**Дисципліна:** Технології DevOps
**Проєкт:** Cavalry, мережа зарядних станцій для електромобілів (`cavalry-backend`, `notification-service`, PostgreSQL, RabbitMQ, Keycloak)
**Вихідні дані:** репозиторій конфігурації `cavalry-gitops` під керуванням Argo CD з ЛР-5 ([LAB5.md](LAB5.md))
**Середовище:** Windows 10, Docker Desktop, minikube (4 CPU, 6 ГБ), Argo CD v3.5, Argo Rollouts v1.10 (чарт `argo-rollouts` 2.43.8), PowerShell

Обрана стратегія: **canary** (варіант **a**). Чому саме вона, див. [розділ 8](#8-чому-canary-а-не-blue-green-відповідь-на-захисті).

Усі команди написані для **PowerShell** (не Git Bash і не cmd). Назви з методички відповідають так:

| У методичці | У цьому проєкті |
|---|---|
| `myapp-gitops` | `cavalry-gitops` (`D:\uni\Java\cavalry-gitops`) |
| Application `myapp`, namespace `myapp` | Application `cavalry`, namespace `cavalry` |
| Rollout / Service `myapp` | Rollout / Service `cavalry-backend` (порт **8082**) |
| `values-minikube.yaml` → `rollout:` | `values-minikube.yaml` → `backend.rollout:` (у чарті кілька сервісів, Rollout отримує лише бекенд) |
| `replicaCount` | `backend.replicas` |

---

## Зміст

1. [Що зроблено: відповідність пунктам завдання](#1-що-зроблено-відповідність-пунктам-завдання)
2. [Як усе влаштовано](#2-як-усе-влаштовано)
3. [Пункт 1. Контролер Argo Rollouts через Argo CD](#3-пункт-1-контролер-argo-rollouts-через-argo-cd)
4. [Пункти 2–3. Rollout у Helm-чарті, стратегія canary](#4-пункти-23-rollout-у-helm-чарті-стратегія-canary)
5. [Одноразова підготовка (до захисту)](#5-одноразова-підготовка-до-захисту)
6. [Перед захистом: запуск і термінали](#6-перед-захистом-запуск-і-термінали)
7. [Сценарій захисту: пункти 4–5 наживо](#7-сценарій-захисту-пункти-45-наживо)
8. [Чому canary, а не blue-green (відповідь на захисті)](#8-чому-canary-а-не-blue-green-відповідь-на-захисті)
9. [Повернення у стартовий стан (щоб показати ще раз)](#9-повернення-у-стартовий-стан-щоб-показати-ще-раз)
10. [Типові проблеми та їх рішення](#10-типові-проблеми-та-їх-рішення)
11. [Теорія: відповіді на ймовірні питання](#11-теорія-відповіді-на-ймовірні-питання)

---

## 1. Що зроблено: відповідність пунктам завдання

| Пункт | Що зроблено | Де |
|---|---|---|
| 1a | Application для Helm-чарту `argo-rollouts` з `https://argoproj.github.io/argo-helm`, версія `2.43.8`, `sync-wave: "-1"`, автосинхронізація. Root (App of Apps) підхоплює його сам, вручну нічого не застосовується | `argocd-apps/argo-rollouts.yaml` |
| 1a | У `cavalry` додано `retry` і `SkipDryRunOnMissingResource=true`: якщо застосунок синхронізується раніше, ніж з'явилися CRD, Argo CD повторює спробу, а не зупиняється на `SyncFailed` | `argocd-apps/cavalry.yaml` |
| 1b | Плагін `kubectl argo rollouts` (Windows, `kubectl-argo-rollouts.exe` у PATH) | розділ 5.2 |
| 2 | Шаблон `Rollout`, який вмикається параметром `backend.rollout.enabled` і замінює Deployment (Deployment обгорнуто в `if not`). Шаблон пода винесено в спільний хелпер, тому Deployment і Rollout запускають **однакові** поди. Реплік **5** (≥ 4). Версія чарту `0.3.0 → 0.4.0` | `charts/cavalry/templates/backend-rollout.yaml`, `backend-deployment.yaml`, `_backend-pod.tpl` |
| 3a | Canary: три кроки `setWeight` (20 → 60 → 80), ручна пауза `pause: {}` і дві паузи з таймером `30s` | `charts/cavalry/values-minikube.yaml` |
| 3 | Усне пояснення вибору стратегії | розділ 8 |
| 4a | Реліз зміною тегу в Git `1.1.0 → 1.2.0`: проміжне співвідношення подів (1 нова : 4 старі), відповіді обох версій з циклу запитів **усередині кластера**, `promote` на ручній паузі | розділ 7.2, `demo/traffic.yaml` |
| 5 | Реліз `1.3.0` → `abort` на першій паузі → повернення на stable `1.2.0`, Argo CD `Synced / Degraded`, пояснення, завершення через `git revert` | розділ 7.3 |
| 6 | Повний сценарій лайв-демонстрації, повернення у стартовий стан для повтору | розділи 6, 7, 9 |

Додатково (не обов'язково, але готово): у чарті є шаблон preview-сервісу для blue-green, тож стратегію можна переключити однією зміною `values-minikube.yaml` (розділ 8).

**Генеральна репетиція 28.10.2026** (весь сценарій розділу 7 на живому кластері, коміти лишились в історії `main`):

| Коміт | Що перевірено | Результат |
|---|---|---|
| `e0e6987` Release cavalry 1.2.0 | реліз комітом → ручна пауза | пауза `Step 1/6` через ≈ 70 с; поди 1 : 4; Argo CD `Synced / Suspended`; у циклі запитів 15 з 80 відповідей `1.2.0` (≈ 19 %) |
| | `promote` | 60 % → пауза 30 с → 80 % → пауза 30 с → 100 %, `Healthy` через ≈ 4,5 хв; Argo CD `Synced / Healthy`; лише `1.2.0` |
| `a8b07c3` Release cavalry 1.3.0 | реліз → `abort` на першій паузі | трафік одразу лише `1.2.0`; Rollout `Degraded` (`RolloutAborted`); Argo CD `Synced / Degraded` |
| `b0d5c2e` Revert "Release cavalry 1.3.0" | відкат через Git | за ≈ 5 с `Synced / Healthy`, нових подів не створено |
| `Reset cavalry to 1.1.0 ...` | повернення у стартовий стан (розділ 9) | `promote --full`, стартовий стан `1.1.0` |

---

## 2. Як усе влаштовано

```
 Git: cavalry-gitops                                 minikube
 ┌──────────────────────────────┐        ┌───────────────────────────────────────────┐
 │ bootstrap/root.yaml          │        │ ns argocd:        Argo CD                 │
 │ argocd-apps/                 │ Argo CD│                                           │
 │   argo-rollouts.yaml  (-1) ──┼───────►│ ns argo-rollouts: контролер Argo Rollouts │
 │   cavalry.yaml        ( 0) ──┼───────►│                   + CRD Rollout, ...      │
 │ charts/cavalry/              │        │                        │ керує            │
 │   values-minikube.yaml       │        │ ns cavalry:            ▼                  │
 │     backend.image.tag ◄─ реліз│       │   Rollout cavalry-backend                 │
 │     backend.rollout.strategy │        │     ├─ ReplicaSet stable  (1.1.0) 4 поди  │
 └──────────────────────────────┘        │     └─ ReplicaSet canary  (1.2.0) 1 под   │
                                         │   Service cavalry-backend → усі 5 подів   │
                                         └───────────────────────────────────────────┘
```

Розподіл обов'язків:

- **Argo CD** відповідає за те, щоб у кластері був саме той маніфест `Rollout`, що в Git (Sync).
- **Контролер Argo Rollouts** відповідає за те, *як* перейти від старого шаблону пода до нового: створює новий ReplicaSet, крок за кроком змінює кількість подів, зупиняється на паузах, вміє скасувати реліз.
- Argo CD має вбудовану перевірку стану (health check) для `Rollout`: `Progressing`, `Suspended` (пауза), `Healthy`, `Degraded`. Також у меню об'єкта Rollout є дії **Resume, Promote-Full, Abort, Retry, Restart**.

Без service mesh чи ingress-контролера з traffic routing вага canary дорівнює **частці подів**: Service `cavalry-backend` вибирає поди обох ReplicaSet-ів за спільними мітками, і kube-proxy розподіляє з'єднання між усіма подами порівну. При 5 репліках: `setWeight: 20` = 1 новий под, `60` = 3, `80` = 4.

---

## 3. Пункт 1. Контролер Argo Rollouts через Argo CD

### 3.1. `argocd-apps/argo-rollouts.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: argo-rollouts
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-1"     # created by root before the cavalry Application
spec:
  project: default
  source:
    repoURL: https://argoproj.github.io/argo-helm
    chart: argo-rollouts
    targetRevision: 2.43.8                 # helm search repo argo/argo-rollouts
  destination:
    server: https://kubernetes.default.svc
    namespace: argo-rollouts
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

- `repoURL` + `chart`: джерелом є Helm-репозиторій, а не Git. Argo CD сам завантажує чарт потрібної версії. У Git зберігається лише **посилання з точною версією**, тож оновлення контролера теж робиться комітом.
- `targetRevision: 2.43.8`: версія **чарту** (не застосунку). Їй відповідає Argo Rollouts `v1.10.1`. Перевірити актуальну:

```powershell
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
helm search repo argo/argo-rollouts
```

- `sync-wave: "-1"`: root застосовує Application-и хвилями, від меншої до більшої. `argo-rollouts` (-1) створюється раніше за `cavalry` (0, за замовчуванням).
- Чарт сам встановлює CRD: `rollouts.argoproj.io`, `analysistemplates`, `analysisruns`, `clusteranalysistemplates`, `experiments`.
- Окремий `kubectl apply` не потрібен: root стежить за каталогом `argocd-apps/` і створює новий Application, щойно файл з'являється в `main`.

### 3.2. Зміни в `argocd-apps/cavalry.yaml`

```yaml
  syncPolicy:
    automated:
      prune: true
      selfHeal: false
    retry:
      limit: 5
      backoff:
        duration: 10s
        factor: 2
        maxDuration: 3m
    syncOptions:
      - CreateNamespace=true
      - SkipDryRunOnMissingResource=true
  ignoreDifferences:
    - group: ""
      kind: Service
      jsonPointers:
        - /spec/selector/rollouts-pod-template-hash
```

- `retry`: якщо синхронізація впала (наприклад `no matches for kind "Rollout"`, бо CRD ще не встановлені), Argo CD повторює її через 10, 20, 40, 80, 160 с. Так застосунок сам доходить до кінця.
- `SkipDryRunOnMissingResource=true`: Argo CD перед застосуванням робить dry run усіх маніфестів. Для типу, CRD якого ще немає, dry run падає і зупиняє **всю** синхронізацію. З цією опцією такі ресурси пропускаються на етапі dry run.
- `ignoreDifferences`: потрібне лише для blue-green. Контролер дописує мітку `rollouts-pod-template-hash` у селектор Service, і Argo CD не повинен вважати це розходженням з Git. Для canary без traffic routing контролер Service не змінює, тож правило нічого не ламає.
- `selfHeal: false` лишається як після ЛР-5. Rollouts працює і з `selfHeal: true`: `promote`/`abort` змінюють `status` Rollout-а, а Argo CD порівнює лише `spec`.

### 3.3. Перевірка (пункт 1 на захисті)

```powershell
argocd app list                                   # argo-rollouts, cavalry, root
argocd app get argo-rollouts                      # Synced / Healthy
kubectl -n argo-rollouts get pods                 # argo-rollouts-...  1/1 Running
kubectl get crd | Select-String argoproj          # rollouts.argoproj.io, analysistemplates..., applications...
kubectl argo rollouts version                     # плагін
```

---

## 4. Пункти 2–3. Rollout у Helm-чарті, стратегія canary

### 4.1. Файли чарту

| Файл | Що робить |
|---|---|
| `templates/_backend-pod.tpl` | **Новий.** Хелпер `cavalry.backend.podTemplate`: шаблон пода бекенда (init-контейнери очікування Postgres і Keycloak, контейнер, змінні, проби). Перенесено з `backend-deployment.yaml` без змін |
| `templates/backend-deployment.yaml` | Обгорнуто в `{{- if not .Values.backend.rollout.enabled }}`. Блок `template:` тепер `include "cavalry.backend.podTemplate"` |
| `templates/backend-rollout.yaml` | **Новий.** `kind: Rollout`, рендериться лише при `backend.rollout.enabled: true` |
| `templates/backend-service-preview.yaml` | **Новий.** Сервіс `cavalry-backend-preview`, лише для blue-green (для canary не рендериться) |
| `values.yaml` | `backend.rollout: {enabled: false, revisionHistoryLimit: 3, strategy: {}}`: за замовчуванням чарт працює як у ЛР-4/5, зі звичайним Deployment |
| `values-minikube.yaml` | `replicas: 5`, `rollout.enabled: true`, стратегія canary, `progressDeadlineSeconds: 300`, запит пам'яті 384Mi |
| `Chart.yaml` | `version: 0.3.0 → 0.4.0` (змінилась структура чарту) |

Чому шаблон пода винесено в хелпер, а не скопійовано: методичка вимагає «той самий шаблон пода, що в deployment.yaml». Хелпер гарантує це: при `rollout.enabled: false` чарт рендерить **побайтово той самий** Deployment, що й у ЛР-5, а `spec.template` і `spec.selector` у Rollout і Deployment ідентичні (перевірено порівнянням відрендерених маніфестів).

### 4.2. `templates/backend-rollout.yaml`

```yaml
{{- if .Values.backend.rollout.enabled }}
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: {{ include "cavalry.fullname" . }}-backend
  labels:
    {{- include "cavalry.labels" . | nindent 4 }}
    app.kubernetes.io/component: backend
spec:
  replicas: {{ .Values.backend.replicas }}
  revisionHistoryLimit: {{ .Values.backend.rollout.revisionHistoryLimit }}
  progressDeadlineSeconds: {{ .Values.backend.progressDeadlineSeconds }}
  selector:
    matchLabels:
      {{- include "cavalry.selectorLabels" . | nindent 6 }}
      app.kubernetes.io/component: backend
  template:
    {{- include "cavalry.backend.podTemplate" . | nindent 4 }}
  strategy:
    {{- toYaml .Values.backend.rollout.strategy | nindent 4 }}
{{- end }}
```

- `apiVersion: argoproj.io/v1alpha1`, `kind: Rollout`: ресурс з CRD Argo Rollouts. Поля `replicas`, `selector`, `template` такі самі, як у Deployment. Відрізняється лише `strategy`.
- `revisionHistoryLimit: 3`: скільки старих ReplicaSet-ів зберігати (для швидкого відкату).
- `progressDeadlineSeconds`: якщо за цей час реліз не просунувся (новий под не став Ready), Rollout переходить у `Degraded`.
- `strategy`: копіюється з values як є (`toYaml`), тому стратегію змінюють у values, не чіпаючи шаблон.

### 4.3. Стратегія у `values-minikube.yaml`

```yaml
backend:
  image:
    repository: ghcr.io/darmohrai/cavalry/cavalry-backend
    tag: "1.1.0"                       # ← цей рядок міняємо під час релізу
  replicas: 5
  progressDeadlineSeconds: 300
  rollout:
    enabled: true
    strategy:
      canary:
        steps:
          - setWeight: 20
          - pause: {}                  # ручна пауза: чекати promote
          - setWeight: 60
          - pause: {duration: 30s}
          - setWeight: 80
          - pause: {duration: 30s}
  resources:
    requests:
      memory: 384Mi
```

Як проходить реліз (6 кроків, у CLI видно `Step: N/6`):

| Крок | Що відбувається | Поди нова : стара | Статус Rollout | Health в Argo CD |
|---|---|---|---|---|
| 0 | новий тег у Git → новий ReplicaSet (canary) | 0 : 5 | Progressing | Progressing |
| 1 `setWeight: 20` | 1 canary-под, stable зменшується до 4 | 1 : 4 | Progressing | Progressing |
| 2 `pause: {}` | **стоїть, поки не буде promote** | 1 : 4 | Paused (`CanaryPauseStep`) | **Suspended** |
| 3 `setWeight: 60` | | 3 : 2 | Progressing | Progressing |
| 4 `pause: 30s` | чекає 30 с сам | 3 : 2 | Paused | Suspended |
| 5 `setWeight: 80` | | 4 : 1 | Progressing | Progressing |
| 6 `pause: 30s` | чекає 30 с сам | 4 : 1 | Paused | Suspended |
| кінець | 100%: canary стає stable, старий ReplicaSet → 0 | 5 : 0 | **Healthy** | **Healthy** |

Чому змінено інші значення:

- `replicas: 5`: завдання вимагає ≥ 4. З 5 подами кроки 20/60/80 % дають цілі числа подів (1/3/4), співвідношення видно одразу.
- `progressDeadlineSeconds: 300` (було 120 у ЛР-5): Spring Boot стартує близько хвилини (`initialDelaySeconds` проби готовності 60 с). Коли кілька подів стартують одночасно на 4 CPU, 120 с могло не вистачити, і Rollout помилково ставав би `Degraded` посеред релізу.
- Запит пам'яті `384Mi` (було 512Mi): під час релізу одночасно існує до 7 подів бекенда (5 + `maxSurge` 25 %). 7 × 512Mi не вміщувалося б разом з Keycloak, Argo CD і рештою у 6 ГБ minikube. Ліміт `768Mi` не змінено, тож реальне споживання JVM не обмежено сильніше.

### 4.4. Перший перехід Deployment → Rollout

При першій синхронізації нового чарту Argo CD створює `Rollout cavalry-backend` і видаляє (`prune`) `Deployment cavalry-backend`. Перший Rollout не має попередньої стабільної версії, тому кроки canary **не виконуються**: одразу піднімаються 5 подів поточної версії (1.1.0). Короткий простій на цьому кроці очікуваний (так і в методичці). Далі кожна зміна шаблону пода проходить через кроки canary.

---

## 5. Одноразова підготовка (до захисту)

### 5.1. Образи трьох версій

Потрібні щонайменше три нові версії: для релізу (`1.2.0`), для abort (`1.3.0`) і запасна (`1.4.0`). Код змінювати не треба: workflow `Release images` вшиває в образ версію з git-тегу (`--build-arg APP_VERSION`), і `/version` показує різні версії.

```powershell
cd D:\uni\Java\cavalry
git fetch origin
git tag -a v1.2.0 -m "Release 1.2.0" origin/main
git push origin v1.2.0
git tag -a v1.3.0 -m "Release 1.3.0" origin/main
git push origin v1.3.0
git tag -a v1.4.0 -m "Release 1.4.0" origin/main
git push origin v1.4.0
```

- `origin/main`: тег ставиться на останній опублікований коміт, а не на локальні незакомічені зміни.
- Кожен `git push` тегу запускає окремий запуск workflow у вкладці **Actions** (≈ 3–5 хв). Теги пушаться по одному, щоб кожен гарантовано запустив workflow.

Перевірити, що образи публічні й доступні:

```powershell
docker pull ghcr.io/darmohrai/cavalry/cavalry-backend:1.2.0
docker pull ghcr.io/darmohrai/cavalry/cavalry-backend:1.3.0
docker pull ghcr.io/darmohrai/cavalry/cavalry-backend:1.4.0
```

Щоб на захисті не чекати завантаження образів, можна заздалегідь підтягнути їх у minikube:

```powershell
minikube image pull ghcr.io/darmohrai/cavalry/cavalry-backend:1.2.0
minikube image pull ghcr.io/darmohrai/cavalry/cavalry-backend:1.3.0
minikube image pull ghcr.io/darmohrai/cavalry/cavalry-backend:1.4.0
```

(`pullPolicy: IfNotPresent`, тож kubelet візьме вже наявний образ.)

### 5.2. Плагін `kubectl argo rollouts` (Windows)

Каталог `C:\Users\Admin_\bin` уже в PATH (там `argocd.exe` з ЛР-5):

```powershell
curl.exe -sSL -o "$env:USERPROFILE\bin\kubectl-argo-rollouts.exe" https://github.com/argoproj/argo-rollouts/releases/download/v1.10.1/kubectl-argo-rollouts-windows-amd64
kubectl argo rollouts version
```

- `kubectl` шукає в PATH виконувані файли `kubectl-<назва>` і робить їх підкомандами. Тому `kubectl-argo-rollouts.exe` стає `kubectl argo rollouts`.
- Версія плагіна `v1.10.1` збігається з версією контролера з чарту 2.43.8.

### 5.3. Перше розгортання Rollouts (двома push-ами)

Зміни вже закомічені локально двома комітами (`git log --oneline -3`):

```
xxxxxxx Switch cavalry backend to an Argo Rollouts canary
yyyyyyy Add Argo Rollouts controller
1f46100 Revert "Enable selfHeal for cavalry"
```

Як радить методичка, контролер додається **окремим** комітом, і лише після `Healthy` пушиться Rollout. Кластер має бути запущений (розділ 6.1), `argocd login` виконаний.

**Push 1: тільки контролер.**

```powershell
cd D:\uni\Java\cavalry-gitops
git push origin HEAD~1:main
argocd app get root --refresh
argocd app wait argo-rollouts --sync --health --timeout 300
kubectl -n argo-rollouts get pods
kubectl get crd | Select-String argoproj
```

- `git push origin HEAD~1:main`: відправити в `main` усе до передостаннього коміту включно, тобто лише `Add Argo Rollouts controller`.
- `argocd app wait`: чекає, поки `argo-rollouts` стане Synced і Healthy.

**Push 2: Rollout у чарті.**

```powershell
git push
argocd app get cavalry --refresh
kubectl argo rollouts get rollout cavalry-backend -n cavalry --watch     # Ctrl+C, коли Healthy
argocd app get cavalry                                                  # Synced / Healthy
kubectl -n cavalry get deploy,rollout,rs,pods -l app.kubernetes.io/component=backend
```

Очікувано: Deployment `cavalry-backend` зник, є Rollout `cavalry-backend`, один ReplicaSet і 5 подів `1.1.0`. Перший запуск 5 подів Spring Boot займає 2–4 хв.

Якщо push-и зробити одним махом, теж спрацює: `retry` і `SkipDryRunOnMissingResource` дочекаються CRD.

---

## 6. Перед захистом: запуск і термінали

### 6.1. Кластер

1. Docker Desktop → «Engine running», зайві контейнери зупинити (`docker ps`, `docker stop ...`).
2. Запуск і очікування:

```powershell
minikube start
kubectl -n argocd wait --for=condition=Ready pods --all --timeout=600s
kubectl -n argo-rollouts wait --for=condition=Ready pods --all --timeout=300s
kubectl -n cavalry get pods -w            # усі 1/1 Running; Ctrl+C
```

### 6.2. Термінали

Відкрийте **п'ять** вікон PowerShell (нові, щоб підхопився PATH).

**Т1: Argo CD** (UI на https://localhost:8080, `admin` / `cavalry-argo-2026`):

```powershell
while ($true) { kubectl -n argocd port-forward svc/argocd-server 8080:443; Start-Sleep 1 }
```

**Т2: дашборд Argo Rollouts** (http://localhost:3100):

```powershell
kubectl argo rollouts dashboard
```

Дашборд працює локально через плагін і показує Rollout-и з поточного kubeconfig. У браузері вгорі виберіть namespace `cavalry`.

**Т3: стан релізу в CLI:**

```powershell
kubectl argo rollouts get rollout cavalry-backend -n cavalry --watch
```

**Т4: цикл запитів усередині кластера:**

```powershell
cd D:\uni\Java\cavalry-gitops
kubectl apply -f demo/traffic.yaml
kubectl -n cavalry logs -f traffic
```

Кожен рядок містить 10 запитів до Service `cavalry-backend`, по одній версії на запит:

```
14:02:11  1.1.0 1.1.0 1.1.0 1.1.0 1.1.0 1.1.0 1.1.0 1.1.0 1.1.0 1.1.0
```

Варіант з методички (одна відповідь на рядок), якщо треба показати саме його:

```powershell
kubectl -n cavalry run curl --rm -it --image=curlimages/curl --restart=Never -- sh -c "while true; do curl -s http://cavalry-backend:8082/version; echo; sleep 0.5; done"
```

> Чому не `port-forward`: `kubectl port-forward svc/...` з'єднується лише з **одним** подом, обраним при старті, і розподілу між версіями не покаже. Под `traffic` ходить через Service, як справжній клієнт.

**Т5: робочий:**

```powershell
cd D:\uni\Java\cavalry-gitops
git pull
argocd login localhost:8080 --username admin --password cavalry-argo-2026 --insecure --grpc-web
```

Функція зміни тегу (з ЛР-5), оголосити один раз у Т5:

```powershell
function Set-BackendTag([string]$Tag) {
  $f = Join-Path (Get-Location) 'charts\cavalry\values-minikube.yaml'
  $text = [IO.File]::ReadAllText($f)
  $text = $text -replace '(cavalry-backend\n\s+tag: )"[^"]*"', ('${1}"' + $Tag + '"')
  [IO.File]::WriteAllText($f, $text)
}
```

### 6.3. Стартовий стан

```powershell
argocd app list
kubectl argo rollouts get rollout cavalry-backend -n cavalry
```

Очікувано: `argo-rollouts`, `cavalry`, `root` усі `Synced / Healthy`; Rollout `✔ Healthy`, `Images: ...cavalry-backend:1.1.0 (stable)`, `Desired: 5, Ready: 5`; у Т4 тільки `1.1.0`.

---

## 7. Сценарій захисту: пункти 4–5 наживо

Порядок: **реліз комітом → пауза (Suspended) → promote → Healthy; новий реліз → abort → Synced + Degraded → git revert.**

### 7.1. Показати конфігурацію (пункти 1–3, 1 хв)

```powershell
Get-Content argocd-apps\argo-rollouts.yaml
Get-Content charts\cavalry\templates\backend-rollout.yaml
Select-String -Path charts\cavalry\values-minikube.yaml -Pattern 'replicas|rollout|canary|setWeight|pause'
argocd app get argo-rollouts
```

В Argo CD UI: `cavalry` → дерево: **Rollout** `cavalry-backend` → ReplicaSet → 5 подів (замість Deployment).

### 7.2. Пункт 4: реліз 1.1.0 → 1.2.0 через Git

**Крок 1. Коміт.**

```powershell
Set-BackendTag 1.2.0
git diff                                  # змінився лише тег
git commit -am "Release cavalry 1.2.0 (canary)"
git push
argocd app get cavalry --refresh
```

Або в UI кнопка **Refresh**. Argo CD синхронізує новий шаблон пода в Rollout, далі працює контролер Rollouts.

**Крок 2. Проміжний стан на ручній паузі** (≈ 1–1,5 хв, поки canary-под стартує).

Т3 (`get rollout --watch`), очікувано:

```
Name:            cavalry-backend
Namespace:       cavalry
Status:          ॥ Paused
Message:         CanaryPauseStep
Strategy:        Canary
  Step:          1/6
  SetWeight:     20
  ActualWeight:  20
Images:          ghcr.io/darmohrai/cavalry/cavalry-backend:1.1.0 (stable)
                 ghcr.io/darmohrai/cavalry/cavalry-backend:1.2.0 (canary)
Replicas:
  Desired:       5
  Current:       5
  Updated:       1
  Ready:         5
  Available:     5

NAME                                         KIND        STATUS     AGE
⟳ cavalry-backend                            Rollout     ॥ Paused
├──# revision:2
│  └──⧉ cavalry-backend-xxxxxxxxxx           ReplicaSet  ✔ Healthy  canary
│     └──□ cavalry-backend-xxxxxxxxxx-aaaaa  Pod         ✔ Running  ready:1/1
└──# revision:1
   └──⧉ cavalry-backend-yyyyyyyyyy           ReplicaSet  ✔ Healthy  stable
      ├──□ ... 4 поди                        Pod         ✔ Running  ready:1/1
```

Т4 (цикл запитів): приблизно кожна п'ята відповідь від нової версії:

```
14:05:41  1.1.0 1.1.0 1.2.0 1.1.0 1.1.0 1.1.0 1.1.0 1.2.0 1.1.0 1.1.0
```

Т5:

```powershell
argocd app get cavalry                    # Sync Status: Synced, Health Status: Suspended
kubectl -n cavalry get rs -l app.kubernetes.io/component=backend    # два ReplicaSet-и: 4 і 1
```

- Розповісти: реліз **зупинився** на `pause: {}`. Нова версія отримує ~20 % запитів реальних клієнтів, і її можна перевірити (логи, метрики, помилки), поки 80 % трафіку обслуговує стабільна версія.
- В Argo CD UI: Health **Suspended** (жовта пауза), у дереві два ReplicaSet-и. Дашборд Т2: Rollout на кроці 1, кнопки Promote / Abort.

**Крок 3. Promote.**

```powershell
kubectl argo rollouts promote cavalry-backend -n cavalry
```

Те саме в UI Argo CD: Rollout → меню **⋮** → **Resume** (знімає поточну паузу; **Promote-Full** пропустив би всі кроки й одразу 100 %). Або кнопка **Promote** у дашборді.

Далі без участі людини (≈ 4–5 хв): `setWeight: 60` (3 : 2) → пауза 30 с → `setWeight: 80` (4 : 1) → пауза 30 с → 100 %. У Т4 частка `1.2.0` поступово росте до 10 з 10. Під час пауз з таймером Argo CD знову показує `Suspended`, але знімається пауза сама.

**Крок 4. Кінець релізу.**

```powershell
kubectl argo rollouts get rollout cavalry-backend -n cavalry   # ✔ Healthy, 1.2.0 (stable), 5/5
argocd app get cavalry                                          # Synced / Healthy
```

Т4: тільки `1.2.0`. Старий ReplicaSet лишився з 0 подів (історія для відкату, `revisionHistoryLimit: 3`).

### 7.3. Пункт 5: скасування релізу 1.3.0

**Крок 1. Новий реліз.**

```powershell
Set-BackendTag 1.3.0
git commit -am "Release cavalry 1.3.0 (canary)"
git push
argocd app get cavalry --refresh
```

Дочекатися першої паузи: Т3 `॥ Paused`, `Step: 1/6`, `1.2.0 (stable)`, `1.3.0 (canary)`; у Т4 з'являється `1.3.0`.

**Крок 2. Abort.** «Під час перевірки знайшли проблему в 1.3.0»:

```powershell
kubectl argo rollouts abort cavalry-backend -n cavalry
```

(UI Argo CD: Rollout → **⋮** → **Abort**; або кнопка Abort у дашборді.)

Контролер одразу масштабує canary-ReplicaSet до 0 і повертає stable до 5 подів. Кілька секунд після abort може бути `Ready: 4` (п'ятий stable-под ще стартує), трафік при цьому вже повністю йде на stable.

```powershell
kubectl argo rollouts get rollout cavalry-backend -n cavalry
argocd app get cavalry
```

Очікувано:

```
Status:          ✖ Degraded
Message:         RolloutAborted: Rollout aborted update to revision 3
Images:          ghcr.io/darmohrai/cavalry/cavalry-backend:1.2.0 (stable)
Replicas:        Desired: 5  Current: 5  Updated: 0  Ready: 5

Sync Status:     Synced to main (<коміт 1.3.0>)
Health Status:   Degraded
```

Т4: знову тільки `1.2.0`. Клієнти обслуговуються стабільною версією, простою немає.

**Пояснення комбінації Synced / Degraded:**

- **Synced**: маніфест Rollout у кластері **збігається з Git**. У Git тег `1.3.0`, і в `spec.template` Rollout-а теж `1.3.0`. `abort` не змінює `spec`, він лише ставить `status.abort: true`, тому Argo CD не бачить розходження.
- **Degraded**: бажаний стан (`1.3.0`) **не досягнуто**: реліз скасовано, працює стара версія `1.2.0`. Health-перевірка Argo CD для Rollout бачить `RolloutAborted` і повідомляє Degraded.
- Тобто кластер «узгоджений з Git, але не здоровий». Так і має бути: Git досі просить 1.3.0, і цю розбіжність між наміром і фактом треба закрити **в Git**.

**Крок 3. Завершення відкату через Git.**

```powershell
git log --oneline -3
git revert --no-edit HEAD                 # скасовує коміт "Release cavalry 1.3.0 (canary)"
git push
argocd app get cavalry --refresh
kubectl argo rollouts get rollout cavalry-backend -n cavalry
argocd app get cavalry
```

Очікувано за кілька секунд: Rollout `✔ Healthy`, `1.2.0 (stable)`; Argo CD `Synced / Healthy`. Нові поди **не** створюються: у Git знову шаблон stable-версії, і контролер просто знімає стан abort.

```powershell
git log --oneline -4
argocd app history cavalry
```

У `git log` видно і реліз 1.3.0, і його revert; у `argocd app history` кожна синхронізація прив'язана до коміту.

Альтернатива з методички: якщо проблему виправлено **поза образом** (наприклад, у БД чи конфігурації іншого сервісу), той самий реліз можна повторити без коміту:

```powershell
kubectl argo rollouts retry rollout cavalry-backend -n cavalry
```

Тоді Rollout знову проходить кроки canary з образом 1.3.0.

### 7.4. Запасний сценарій

Якщо викладач попросить показати ще раз або щось пішло не так: `Set-BackendTag 1.4.0` і повторити 7.2 (реліз) або 7.3 (abort). Для abort можна також не чекати паузи, а перервати на будь-якому кроці.

---

## 8. Чому canary, а не blue-green (відповідь на захисті)

1. **Ресурси minikube.** Blue-green піднімає **повну** другу копію: при 4 репліках це 8 подів Spring Boot (≈ 400 МБ кожен) одночасно. На вузлі 6 ГБ разом з Keycloak, Postgres, RabbitMQ і Argo CD це не вміщується. Canary в кожен момент тримає ≈ 5–7 подів, лише трохи більше за звичайну кількість.
2. **Реальні користувачі як перевірка.** Бекенд stateless, будь-який под обслуговує будь-який запит. Canary дає новій версії спершу 20 % реального трафіку: якщо щось не так, постраждає лише частина запитів, і `abort` миттєво повертає все на stable. У blue-green до перемикання нова версія отримує лише тестові запити через preview-сервіс, а після promote одразу 100 % трафіку.
3. **Не потрібен другий Service і зміна клієнтів.** Canary працює через наявний Service `cavalry-backend`. Blue-green вимагає `cavalry-backend-preview` і переписування селекторів контролером.
4. **Сумісність версій.** Canary означає, що дві версії працюють **одночасно** з однією БД і чергою RabbitMQ. Для Cavalry це безпечно: між 1.1.0–1.4.0 схема БД і формат повідомлень не змінюються. Якби реліз містив несумісну міграцію БД, краще підійшов би blue-green (одна версія обслуговує трафік у кожен момент) або окремі кроки міграції.

Недолік canary без traffic routing: вага грубо прив'язана до кількості подів (крок 20 % можливий лише з 5+ репліками), і точно направити, наприклад, 1 % трафіку не можна. Для цього потрібен service mesh (Istio, Linkerd) або ingress з traffic splitting (NGINX, Traefik), які Argo Rollouts підтримує через `trafficRouting`.

**Перемикання на blue-green (якщо попросять):** у `values-minikube.yaml` замінити блок `canary:` на закоментований `blueGreen:` нижче нього (`activeService: cavalry-backend`, `previewService: cavalry-backend-preview`, `autoPromotionEnabled: false`, `scaleDownDelaySeconds: 30`). Чарт сам відрендерить preview-сервіс. Перевірка: `kubectl -n cavalry port-forward svc/cavalry-backend-preview 8082:8082`, `curl.exe -s localhost:8082/version` (нова), `promote`, `kubectl -n cavalry get svc cavalry-backend -o jsonpath='{.spec.selector}'` (новий `rollouts-pod-template-hash`). Зміна лише стратегії **не** запускає реліз (шаблон пода той самий), для перевірки треба ще змінити тег.

---

## 9. Повернення у стартовий стан (щоб показати ще раз)

Стартовий стан для демонстрації: Rollout `Healthy` зі stable `1.1.0`, у Т4 тільки `1.1.0`.

```powershell
cd D:\uni\Java\cavalry-gitops
Set-BackendTag 1.1.0
git commit -am "Reset cavalry to 1.1.0 before the Lab 6 demo"
git push
argocd app get cavalry --refresh
```

Це теж реліз canary, тому він зупиниться на ручній паузі. Щоб не чекати кроків, одразу:

```powershell
kubectl argo rollouts promote cavalry-backend -n cavalry --full
kubectl argo rollouts get rollout cavalry-backend -n cavalry --watch     # ✔ Healthy; Ctrl+C
```

- `promote --full`: пропустити всі кроки й паузи, одразу 100 %.

Після захисту под з циклом запитів можна видалити: `kubectl -n cavalry delete pod traffic`.

Повний відкат до ЛР-5 (звичайний Deployment), якщо раптом знадобиться: у `values-minikube.yaml` поставити `backend.rollout.enabled: false`, commit, push. Argo CD видалить Rollout і створить Deployment.

---

## 10. Типові проблеми та їх рішення

| Симптом | Причина | Рішення |
|---|---|---|
| `no matches for kind "Rollout"`, `SyncFailed` | `cavalry` синхронізувався раніше, ніж з'явилися CRD | Дочекатися `argo-rollouts` Healthy; `retry` повторить сам, або UI → **Sync** |
| `argo-rollouts`: `ComparisonError ... chart not found` | Неправильна версія в `targetRevision` | `helm search repo argo/argo-rollouts`, вписати існуючу версію, commit, push |
| Одночасно Deployment і Rollout `cavalry-backend` | Немає умови `if not .Values.backend.rollout.enabled` | Умова вже є в `backend-deployment.yaml`; перевірити, що `prune: true` |
| Цикл запитів показує тільки одну версію | Запити через `port-forward` (один под) | Цикл у поді всередині кластера (`demo/traffic.yaml`) |
| Реліз не стартує після зміни values | Rollout стартує лише при зміні **шаблону пода** (образ, змінні, мітки), а не `replicas` чи `strategy` | Змінити тег образу або `extraEnv` |
| Canary-под `Pending` | Не вистачає пам'яті/CPU на вузлі | `kubectl -n cavalry describe pod <под>`; зупинити зайві контейнери Docker; зменшити `replicas` до 4 |
| Canary-под довго `0/1`, Rollout `Degraded: ProgressDeadlineExceeded` | Spring Boot не встиг стартувати за 300 с (мало CPU) або образ не тягнеться | `kubectl -n cavalry describe pod`; образ заздалегідь `minikube image pull ...`; `kubectl argo rollouts retry rollout cavalry-backend -n cavalry` |
| `kubectl: unknown command "argo"` | Плагін не в PATH | Розділ 5.2; новий термінал |
| `ImagePullBackOff` на 1.2.0/1.3.0 | Образ ще не зібраний (workflow не завершився) | GitHub → Actions → `Release images`; `docker pull ...` |
| Після abort Argo CD `Synced / Degraded` | Так і має бути: Git просить 1.3.0, а працює 1.2.0 | `git revert` коміту з 1.3.0, push (розділ 7.3) |
| Blue-green: вічний `OutOfSync` на Service | Контролер дописує мітку в селектор | `ignoreDifferences` уже додано в `argocd-apps/cavalry.yaml` |
| Дашборд `localhost:3100` порожній | Вибрано інший namespace | Вгорі дашборду вибрати `cavalry` |
| `docker version` висить, `minikube status` → `unknown state` | Docker Desktop завис (часто після сну/гібернації ПК) | Закрити Docker Desktop (трей → Quit, або завершити процеси `Docker Desktop` і `com.docker.backend`), `wsl --terminate docker-desktop`, запустити знову, далі `minikube start` |
| Після `minikube start` поди бекенда `Unknown` / `0/1` | Поди відновлюються після рестарту вузла, Spring Boot стартує ≈ 1–2 хв | `kubectl argo rollouts status cavalry-backend -n cavalry --timeout 10m` |
| `argocd login`: `Invalid username or password` | Пароль `admin` змінювали не на `cavalry-argo-2026` | Скинути пароль (нижче) |
| `git revert` не створив коміт | Зайвий прапорець (наприклад `-q`, якого в `git revert` немає) | Рівно `git revert --no-edit HEAD`, потім `git log --oneline -3` |

Скидання пароля `admin` в Argo CD на `cavalry-argo-2026` (PowerShell):

```powershell
$hash = argocd account bcrypt --password cavalry-argo-2026
$now  = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
@{ stringData = @{ 'admin.password' = $hash; 'admin.passwordMtime' = $now } } | ConvertTo-Json -Compress | Set-Content -Encoding ascii "$env:TEMP\argocd-pass.json"
kubectl -n argocd patch secret argocd-secret --patch-file "$env:TEMP\argocd-pass.json"
kubectl -n argocd rollout restart deployment argocd-server
```

Поки пароля немає, усе з розділу 7 можна показати без `argocd` CLI: стан застосунку `kubectl -n argocd get application cavalry` (колонки SYNC STATUS / HEALTH STATUS), Refresh `kubectl -n argocd annotate application cavalry argocd.argoproj.io/refresh=normal --overwrite`.

---

## 11. Теорія: відповіді на ймовірні питання

**Що таке progressive delivery?** Розвиток continuous delivery: нова версія викатується **поступово** з контрольними точками, і на кожній можна зупинитись, перевірити й скасувати реліз. Мета — зменшити «радіус ураження» поганого релізу.

**Чим Rollout відрізняється від Deployment?** Той самий `selector`/`template`/`replicas`, але `strategy` інша. Deployment знає лише `RollingUpdate` (без пауз і швидкого скасування) і `Recreate`. Rollout підтримує `canary` (кроки `setWeight`, `pause`, аналіз метрик) і `blueGreen` (preview/active сервіси, ручне перемикання), а також `abort`, `retry`, `promote`. Керує ним окремий контролер Argo Rollouts, а не kube-controller-manager.

**Rolling update теж поступовий. Навіщо canary?** Rolling update не зупиняється: щойно новий под Ready (порт відкрився), старий видаляється, і за хвилину вся система на новій версії. Готовність пода не означає, що версія без помилок. Canary тримає нову версію на частці трафіку стільки, скільки потрібно, і дає змогу миттєво повернути все назад.

**Canary vs blue-green.** Canary: нова версія отримує поступово зростаючу частку реального трафіку, дві версії працюють одночасно, ресурсів мало. Blue-green: нова версія піднімається повністю поруч, перевіряється через preview-сервіс, потім трафік перемикається **одразу весь**; потрібно вдвічі більше ресурсів, але в кожен момент користувачів обслуговує одна версія, а відкат = перемикання селектора назад.

**Як працює вага без service mesh?** Через кількість подів. Обидва ReplicaSet-и мають спільні мітки, Service вибирає всі поди, kube-proxy розподіляє з'єднання рівномірно. 1 под з 5 ≈ 20 % запитів. Точна вага (наприклад 5 % на 2 подах) потребує `trafficRouting` (Istio, NGINX, SMI тощо).

**Що робить `pause: {}` і `pause: {duration: 30s}`?** Без тривалості пауза нескінченна: реліз чекає `promote` (ручна контрольна точка). З тривалістю контролер сам продовжує через 30 с (час на автоматичні перевірки, спостереження за метриками).

**`promote` vs `promote --full`, Resume vs Promote-Full.** `promote` (Resume в UI) знімає поточну паузу, і реліз іде далі за кроками. `--full` (Promote-Full) пропускає всі кроки, що лишилися, і одразу робить 100 %.

**Що робить `abort`?** Ставить `status.abort: true`: canary-ReplicaSet масштабується до 0, stable повертається до повної кількості. `spec` Rollout-а (і отже Git) не змінюється, тому стан Synced / Degraded. Відкат завершується через Git (`git revert`), або реліз повторюється `retry`.

**Чому відкат через `git revert`, а не `kubectl argo rollouts undo`?** `undo` змінює `spec.template` у кластері на попередню ревізію. Тоді кластер розійдеться з Git (`OutOfSync`), а автосинхронізація Argo CD одразу поверне 1.3.0 з Git. Джерело правди — Git, тому відкат опису робиться комітом.

**Як Argo CD і Argo Rollouts ділять обов'язки?** Argo CD доставляє маніфест Rollout з Git у кластер і показує його стан (вбудований health check для `argoproj.io/Rollout`, дії Resume/Abort/Promote-Full/Retry/Restart в UI). Контролер Rollouts виконує саму стратегію. Argo CD не втручається в ReplicaSet-и, якими керує Rollout.

**Чому контролер встановлено через Argo CD, а не `kubectl apply`/`helm install`?** Щоб і кластерні компоненти описувались у Git: версія контролера зафіксована в `argocd-apps/argo-rollouts.yaml`, оновлення — це коміт, а кластер відтворюється з Git (App of Apps).

**Навіщо `sync-wave: "-1"`?** Root застосовує ресурси хвилями. Application контролера з хвилею -1 створюється раніше за `cavalry` (0), тож CRD зазвичай уже є, коли синхронізується Rollout. Гарантії здоров'я хвиля не дає (root не чекає, поки дочірній Application стане Healthy), тому в `cavalry` додано `retry` і `SkipDryRunOnMissingResource`.

**Що таке AnalysisTemplate?** CRD Argo Rollouts для автоматичної перевірки на кроці canary: запит до Prometheus, вебхук, Job. Якщо метрика погана, Rollout сам робить abort. У цій роботі перевірка ручна (`pause: {}`), автоматичний аналіз — наступний крок разом з моніторингом.

**Чому відповіді двох версій безпечні для БД?** Обидві версії працюють з тією самою схемою PostgreSQL і тими самими чергами RabbitMQ, а 1.2.0–1.4.0 відрізняються лише вшитим номером версії. У реальному проєкті міграції БД при canary роблять зворотно сумісними (expand → migrate → contract).



https://claude.ai/artifact/3iFwMEkUXFB39u3B3o8hrQ#3b0237d1-7261.mjp6mwkaff8.8975