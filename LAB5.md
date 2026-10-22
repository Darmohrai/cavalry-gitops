# Лабораторна робота №5. GitOps: розгортання проєкту через Argo CD

**Дисципліна:** Технології DevOps
**Проєкт:** Cavalry, мережа зарядних станцій для електромобілів (`cavalry-backend`, `notification-service`, PostgreSQL, RabbitMQ, Keycloak)
**Середовище:** Windows 10, Docker Desktop, minikube v1.39 (Kubernetes v1.37), Helm 4, Argo CD v3.5, PowerShell

Усі команди нижче перевірено на живому кластері. Вони написані для **PowerShell** (не для Git Bash і не для cmd).

---

## Зміст

1. [Що зроблено: відповідність пунктам завдання](#1-що-зроблено-відповідність-пунктам-завдання)
2. [Як усе влаштовано](#2-як-усе-влаштовано)
3. [Пункт 1. Репозиторій конфігурації](#3-пункт-1-репозиторій-конфігурації)
4. [Пункт 2. Образ застосунку в реєстрі](#4-пункт-2-образ-застосунку-в-реєстрі)
5. [Підготовка перед захистом (обов'язково)](#5-підготовка-перед-захистом-обовязково)
6. [Сценарій захисту: пункти 3–6 наживо](#6-сценарій-захисту-пункти-36-наживо)
7. [Прохання викладача: змінити будь-яке значення](#7-прохання-викладача-змінити-будь-яке-значення)
8. [Повернення у стартовий стан (щоб показати ще раз)](#8-повернення-у-стартовий-стан-щоб-показати-ще-раз)
9. [Встановлення з нуля (якщо кластер видалено)](#9-встановлення-з-нуля-якщо-кластер-видалено)
10. [Типові проблеми та їх рішення](#10-типові-проблеми-та-їх-рішення)
11. [Теорія: відповіді на ймовірні питання](#11-теорія-відповіді-на-ймовірні-питання)

---

## 1. Що зроблено: відповідність пунктам завдання

| Пункт | Що зроблено | Де |
|---|---|---|
| 1 | Окремий репозиторій конфігурації `cavalry-gitops` (варіант **а**, рекомендований). Чарт з ЛР-4 перенесено в `charts/cavalry`, файл значень для minikube `values-minikube.yaml`. Паролів у Git немає: параметр `existingSecret`, Secret створюється вручну | https://github.com/Darmohrai/cavalry-gitops |
| 2a | Образи публікуються в GHCR з конкретними тегами `1.0.0`, `1.1.0` (не `latest`) workflow-ом `Release images` за git-тегом `vX.Y.Z`. Пакети публічні, кластер тягне їх сам, без `minikube image load` | `cavalry/.github/workflows/release.yml` |
| 2b | Ендпоінт `GET /version` повертає версію, яка вшивається в образ під час збірки (`--build-arg APP_VERSION`) | `cavalry-backend/.../VersionController.java` |
| 3 | Argo CD у namespace `argocd`, CLI `argocd.exe`, пароль `admin` змінено, початковий секрет видалено. Репозиторій публічний, тому `argocd repo add` не потрібен | розділи 5, 9 |
| 4 | `argocd-apps/cavalry.yaml` (Application з автосинхронізацією) підключено через кореневий `bootstrap/root.yaml` (App of Apps). Вручну застосовується лише `root` | розділ 6.2 |
| 5 | Нова версія 1.1.0 з видимою зміною (поле `message` у `/version`), реліз зміною тегу в Git | розділ 6.3 |
| 6a | `kubectl scale` без selfHeal → OutOfSync, з `selfHeal: true` → Argo CD повертає значення з Git | розділ 6.4 |
| 6b | Неіснуючий тег `9.9.9` → Synced, але Degraded | розділ 6.5 |
| 6c | `git revert`, історія в `git log` і `argocd app history` | розділ 6.6 |
| 7 | Сценарій демонстрації та зміна довільного значення на прохання викладача | розділи 6, 7 |

---

## 2. Як усе влаштовано

```
 Репозиторій застосунку                    Репозиторій конфігурації
 github.com/Darmohrai/cavalry              github.com/Darmohrai/cavalry-gitops
 ┌───────────────────────────┐             ┌─────────────────────────────────┐
 │ код Java, Dockerfile      │             │ bootstrap/root.yaml             │
 │ .github/workflows/        │             │ argocd-apps/cavalry.yaml        │
 │   release.yml             │             │ charts/cavalry/ (чарт ЛР-4)     │
 └────────────┬──────────────┘             │   values-minikube.yaml  ◄── тег │
              │ git push tag v1.1.0        └───────────────┬─────────────────┘
              ▼                                            │ Argo CD читає Git
 ┌───────────────────────────┐                             │ (раз на 3 хв або Refresh)
 │ GitHub Actions            │                             ▼
 │ docker build + push       │             ┌─────────────────────────────────┐
 └────────────┬──────────────┘             │ minikube                        │
              ▼                            │  ns argocd:  Argo CD            │
 ┌───────────────────────────┐   pull      │  ns cavalry: backend, notif.,   │
 │ ghcr.io/darmohrai/cavalry │ ◄────────── │   postgres, rabbitmq, keycloak  │
 │   cavalry-backend:1.1.0   │             └─────────────────────────────────┘
 └───────────────────────────┘
```

Ключова ідея GitOps: **бажаний стан кластера описаний у Git**. Ніхто не виконує `helm upgrade` чи `kubectl apply` для застосунку. Argo CD у кластері порівнює Git з кластером і сам приводить кластер до описаного стану.

Ланцюжок App of Apps:

```
kubectl apply -f bootstrap/root.yaml   (єдиний ручний крок)
        │
        ▼
Application "root"  ── стежить за ──►  argocd-apps/  ──► створює Application "cavalry"
                                                                  │
                                                                  ▼
                                    charts/cavalry + values-minikube.yaml ──► Deployment, Service, PVC, ...
```

---

## 3. Пункт 1. Репозиторій конфігурації

Локально: `D:\uni\Java\cavalry-gitops`. На GitHub: https://github.com/Darmohrai/cavalry-gitops (публічний).

```
cavalry-gitops/
├── bootstrap/
│   └── root.yaml              # кореневий Application, застосовується вручну один раз
├── argocd-apps/               # Application-и, якими керує root
│   └── cavalry.yaml
├── charts/
│   └── cavalry/               # чарт з ЛР-4
│       ├── Chart.yaml         # version 0.3.0, appVersion 1.0.0
│       ├── values.yaml        # значення за замовчуванням
│       ├── values-minikube.yaml   # значення для minikube (без паролів)
│       ├── files/realm-export.json
│       └── templates/
├── README.md
└── LAB5.md                    # цей файл
```

### 3.1. `bootstrap/root.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/Darmohrai/cavalry-gitops.git
    targetRevision: main
    path: argocd-apps
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

- `path: argocd-apps`: root бере з Git усі маніфести з каталогу `argocd-apps/`. Там лежать інші Application-и, тому root «породжує» їх.
- `destination.namespace: argocd`: дочірні Application-и мають жити в namespace `argocd`, інакше Argo CD їх не бачить.
- `prune: true`: якщо файл з `argocd-apps/` видалити, відповідний Application теж видалиться.
- `selfHeal: true`: якщо хтось вручну змінить Application `cavalry` у кластері, root поверне його до версії з Git. Тому, щоб увімкнути selfHeal для `cavalry`, ми змінюємо файл у Git, а не кластер.

### 3.2. `argocd-apps/cavalry.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cavalry
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/Darmohrai/cavalry-gitops.git
    targetRevision: main
    path: charts/cavalry
    helm:
      valueFiles:
        - values-minikube.yaml   # relative to the chart directory (path)
  destination:
    server: https://kubernetes.default.svc
    namespace: cavalry
  syncPolicy:
    automated:
      prune: true
      selfHeal: false            # switched to true in step 6a
    syncOptions:
      - CreateNamespace=true
```

- `path: charts/cavalry`: Argo CD бачить там `Chart.yaml` і розуміє, що це Helm-чарт.
- `helm.valueFiles`: шлях **відносно каталогу чарту**, а не кореня репозиторію.
- Назва Application `cavalry` стає назвою Helm-релізу (`.Release.Name`), тому об'єкти називаються `cavalry-backend`, `cavalry-postgres` тощо, як у ЛР-4 при `helm install cavalry`.
- `automated`: автоматична синхронізація. Щойно в Git з'являється новий коміт, Argo CD застосовує його.
- `prune: true`: об'єкти, які зникли з Git, видаляються з кластера.
- `selfHeal: false`: на старті вимкнено, вмикаємо в пункті 6a.
- `CreateNamespace=true`: Argo CD сам створить namespace `cavalry`, якщо його немає.

### 3.3. Що змінено в чарті порівняно з ЛР-4

| Зміна | Навіщо |
|---|---|
| `existingSecret` + хелпер `cavalry.secretName` у `_helpers.tpl`; `templates/secret.yaml` обгорнуто в `{{- if not .Values.existingSecret }}` | Паролі не зберігаються в Git. Якщо `existingSecret` заданий, чарт не створює Secret, а всі поди беруть паролі із Secret, створеного вручну |
| `POSTGRES_DB` бекенд бере з того ж Secret, URL БД: `jdbc:postgresql://...:5432/$(POSTGRES_DB)` | Назва БД у бекенда й у Postgres гарантовано однакова |
| `backend.progressDeadlineSeconds` (у minikube 120 с) | Deployment зі зламаним образом стає `Degraded` через 2 хв, а не через 10 (стандартні 600 с). Потрібно для пункту 6b |
| `backend.extraEnv` | Можна додати змінну оточення через Git (наприклад `APP_MESSAGE`) на прохання викладача |
| `hooks.preUpgrade.enabled`, `tests.enabled` (у minikube обидва `false`) | Argo CD виконує Helm-хук `pre-upgrade` як PreSync **перед кожною** синхронізацією, зокрема першою, коли PostgreSQL ще немає. Хук упав би, і синхронізація зупинилась би |
| `replicas: 1` для postgres, rabbitmq, keycloak у `values.yaml` | У шаблонах було посилання на ці значення, а в `values.yaml` їх не було |
| CPU-ліміт Java-сервісів у minikube: `1` | Spring Boot при старті сильно навантажує CPU. З лімітом 300m notification-service не встигав стартувати до спрацювання liveness-проби |

### 3.4. `charts/cavalry/values-minikube.yaml`

```yaml
existingSecret: cavalry-secret

backend:
  image:
    repository: ghcr.io/darmohrai/cavalry/cavalry-backend
    tag: "1.0.0"                 # ← цей рядок міняємо під час релізу
    pullPolicy: IfNotPresent
  replicas: 1
  progressDeadlineSeconds: 120
  extraEnv: []
  resources: ...

notification:
  image:
    repository: ghcr.io/darmohrai/cavalry/notification-service
    tag: "1.0.0"
    pullPolicy: IfNotPresent

hooks:
  preUpgrade:
    enabled: false
tests:
  enabled: false
```

### 3.5. Секрети

Secret створюється **вручну** командою `kubectl` і в Git не потрапляє:

```powershell
kubectl create namespace cavalry
kubectl -n cavalry create secret generic cavalry-secret `
  --from-literal=POSTGRES_DB=ev_charge_db `
  --from-literal=POSTGRES_USER=root `
  --from-literal=POSTGRES_PASSWORD=rootpassword `
  --from-literal=KEYCLOAK_ADMIN=admin `
  --from-literal=KEYCLOAK_ADMIN_PASSWORD=admin
```

Argo CD не видаляє такий Secret навіть з `prune: true`, бо Secret не створений з Git і не має позначки Argo CD.
Повноцінні рішення (Sealed Secrets, SOPS, External Secrets) дозволяють тримати секрети в Git у зашифрованому вигляді, але це не обов'язково для цієї роботи.

---

## 4. Пункт 2. Образ застосунку в реєстрі

### 4.1. Відображення версії

У репозиторії застосунку `cavalry` додано `VersionController`:

```java
@GetMapping("/version")
public Map<String, String> version() {
    Map<String, String> body = new LinkedHashMap<>();
    body.put("service", "cavalry-backend");
    body.put("version", version);    // ${APP_VERSION:dev}
    body.put("message", message);    // ${APP_MESSAGE:Cavalry is up and charging}, з'явилось у 1.1.0
    return body;
}
```

`/version` дозволено без авторизації в `SecurityConfig`. Версія вшивається в образ під час збірки:

```dockerfile
FROM eclipse-temurin:21-jre-alpine
ARG APP_VERSION=dev
ENV APP_VERSION=${APP_VERSION}
```

Тому `/version` показує версію **образу, який реально працює**, а не значення з чарту.

| Версія | Відповідь `/version` |
|---|---|
| 1.0.0 | `{"service":"cavalry-backend","version":"1.0.0"}` |
| 1.1.0 | `{"service":"cavalry-backend","version":"1.1.0","message":"Cavalry is up and charging"}` |

### 4.2. Публікація образів (`.github/workflows/release.yml`)

Workflow запускається на push git-тегу виду `v*.*.*`, збирає обидва сервіси з `--build-arg APP_VERSION=<версія>` і публікує:

- `ghcr.io/darmohrai/cavalry/cavalry-backend:<версія>`
- `ghcr.io/darmohrai/cavalry/notification-service:<версія>`

Логін у GHCR робиться через вбудований `GITHUB_TOKEN`, тобто жодних паролів у репозиторії немає.

Як випущено версії 1.0.0 і 1.1.0 (уже зроблено, повторювати не треба):

```powershell
cd D:\uni\Java\cavalry
git tag -a v1.0.0 -m "Release 1.0.0"    # на коміті з /version
git push origin v1.0.0
# ...коміт із полем message...
git tag -a v1.1.0 -m "Release 1.1.0"
git push origin v1.1.0
```

- `git tag -a`: анотований тег на поточному коміті.
- `git push origin v1.1.0`: відправка тегу на GitHub запускає workflow `Release images`. Результат видно у вкладці **Actions** репозиторію.

Пакети в GHCR **публічні**: Packages → пакет → Package settings → Change visibility → Public. Інакше кластер отримав би `ImagePullBackOff`.

Перевірити, що образ доступний без логіну:

```powershell
docker pull ghcr.io/darmohrai/cavalry/cavalry-backend:1.1.0
```

> Workflow `CI/CD Pipeline` на гілці `main` падає на кроці Checkstyle ще з попередніх лабораторних. Для ЛР-5 він не використовується: образи збирає окремий `Release images`, і він проходить успішно.

---

## 5. Підготовка перед захистом (обов'язково)

Робіть це за 10–15 хвилин до захисту. Кластер і Argo CD уже встановлені, їх треба лише запустити.

### 5.1. Звільнити ресурси і запустити кластер

1. Запустіть Docker Desktop і дочекайтесь статусу «Engine running».
2. Зупиніть важкі контейнери інших проєктів (на кластер потрібні CPU й пам'ять):

```powershell
docker ps                       # подивитись, що запущено
docker stop shypshyna           # приклад: зупинити зайвий контейнер
```

3. Запустіть minikube:

```powershell
minikube start
```

`minikube start` піднімає наявний кластер з усім станом: Argo CD, Secret, застосунок. Параметри (4 CPU, 6 ГБ) запам'ятовуються з першого запуску.

4. Дочекайтесь, поки всі поди Argo CD і застосунку стануть Ready:

```powershell
kubectl -n argocd wait --for=condition=Ready pods --all --timeout=600s
kubectl -n cavalry get pods -w        # чекати 1/1 Running у всіх; вихід: Ctrl+C
```

- `kubectl wait --for=condition=Ready`: блокує термінал, поки умова не виконається (або тайм-аут).
- `-w` (watch): показує зміни в реальному часі.

### 5.2. Термінали

Відкрийте **три** вікна PowerShell (нові, щоб підхопився PATH з `argocd.exe`).

**Термінал 1: доступ до Argo CD.** Цикл потрібен, бо `kubectl port-forward` іноді обриває з'єднання, і цикл одразу його перезапускає:

```powershell
while ($true) { kubectl -n argocd port-forward svc/argocd-server 8080:443; Start-Sleep 1 }
```

**Термінал 2: доступ до застосунку.** Після кожного оновлення старий под зникає, port-forward завершується, і цикл переключається на новий под:

```powershell
while ($true) { kubectl -n cavalry port-forward svc/cavalry-backend 8081:8082; Start-Sleep 1 }
```

- `port-forward svc/...`: прокидає локальний порт до сервісу в кластері. `8080:443` означає `localhost:8080` → порт 443 сервісу `argocd-server`. Сервіс бекенда слухає порт 8082.

**Термінал 3: робочий.** Усі інші команди:

```powershell
cd D:\uni\Java\cavalry-gitops
git pull
argocd login localhost:8080 --username admin --password cavalry-argo-2026 --insecure --grpc-web
```

- `--insecure`: сертифікат Argo CD самопідписаний.
- `--grpc-web`: CLI ходить через HTTP/1.1 замість чистого gRPC. Так стабільніше через `kubectl port-forward`. Прапорець запам'ятовується в `~/.config/argocd/config`, далі його писати не треба.

### 5.3. Перевірка стартового стану

```powershell
argocd app list
curl.exe -s localhost:8081/version
```

Очікувано:

```
NAME            ...  STATUS  HEALTH   SYNCPOLICY  ...  PATH            TARGET
argocd/cavalry  ...  Synced  Healthy  Auto-Prune  ...  charts/cavalry  main
argocd/root     ...  Synced  Healthy  Auto-Prune  ...  argocd-apps     main

{"service":"cavalry-backend","version":"1.0.0"}
```

> У PowerShell 5.1 `curl` є псевдонімом `Invoke-WebRequest`. Пишіть саме **`curl.exe`**.

Відкрийте в браузері **https://localhost:8080**. Браузер попередить про сертифікат: «Додатково» → «Перейти». Логін `admin`, пароль `cavalry-argo-2026`.

---

## 6. Сценарій захисту: пункти 3–6 наживо

Усі команди виконуються в **терміналі 3** з каталогу `D:\uni\Java\cavalry-gitops`.

### 6.1. Пункт 3: Argo CD встановлено

```powershell
kubectl -n argocd get pods
argocd version
argocd account get-user-info
```

- `kubectl -n argocd get pods`: компоненти Argo CD: `argocd-server` (API та UI), `argocd-repo-server` (клонує Git і рендерить Helm), `argocd-application-controller` (порівнює Git з кластером і синхронізує), `redis` (кеш), `dex-server` (SSO), `applicationset-controller`, `notifications-controller`.
- `argocd version`: версії CLI та сервера, тобто CLI підключений до сервера.
- `argocd account get-user-info`: `Logged In: true`, `Username: admin`.

Розповісти: пароль `admin` змінено командою `argocd account update-password`, початковий секрет `argocd-initial-admin-secret` видалено. Репозиторій публічний, тому `argocd repo add` не потрібен.

```powershell
kubectl -n argocd get secret argocd-initial-admin-secret
```

Очікувано: `Error from server (NotFound)`, бо секрет видалено.

### 6.2. Пункт 4: App of Apps, Synced / Healthy

```powershell
Get-Content bootstrap\root.yaml
Get-Content argocd-apps\cavalry.yaml
argocd app list
argocd app get cavalry
kubectl -n cavalry get all
helm list -n cavalry
```

- `argocd app list`: два Application-и. `root` створено вручну, `cavalry` створив root з Git.
- `argocd app get cavalry`: деталі й дерево ресурсів. Очікувано:

```
Sync Policy:        Automated (Prune)
Sync Status:        Synced to main (68ef8c7)
Health Status:      Healthy

GROUP  KIND                   NAMESPACE  NAME                    STATUS  HEALTH
       ConfigMap              cavalry    cavalry-config          Synced
       ConfigMap              cavalry    cavalry-keycloak-realm  Synced
       PersistentVolumeClaim  cavalry    cavalry-postgres-pvc    Synced  Healthy
       Service                cavalry    cavalry-backend         Synced  Healthy
       ...
apps   Deployment             cavalry    cavalry-backend         Synced  Healthy
```

- `helm list -n cavalry`: **порожньо**. Argo CD не виконує `helm install`, а лише рендерить шаблони (`helm template`) і застосовує маніфести сам. Тому Helm-релізу в кластері немає.

**В інтерфейсі:** Applications → `root` (видно дочірній Application `cavalry`) → `cavalry` → дерево: Deployment → ReplicaSet → Pod, Service, PVC, ConfigMap. Зверху `Synced` (зелена галочка) і `Healthy` (зелене серце).

Як усе розгорталось уперше (для розповіді; повторно не виконувати):

```powershell
git add . ; git commit -m "Deploy cavalry via Argo CD" ; git push
kubectl apply -f bootstrap/root.yaml    # єдиний ручний apply
```

### 6.3. Пункт 5: оновлення через Git (1.0.0 → 1.1.0)

**Крок 1.** Змінити тег бекенда в `charts\cavalry\values-minikube.yaml`. Найпростіше відкрити файл в IDE і змінити рядок під `cavalry-backend`:

```yaml
    tag: "1.0.0"   →   tag: "1.1.0"
```

Або однією командою. Функцію достатньо оголосити один раз у терміналі. Вона змінює лише тег бекенда і зберігає LF-закінчення рядків:

```powershell
function Set-BackendTag([string]$Tag) {
  $f = Join-Path (Get-Location) 'charts\cavalry\values-minikube.yaml'
  $text = [IO.File]::ReadAllText($f)
  $text = $text -replace '(cavalry-backend\n\s+tag: )"[^"]*"', ('${1}"' + $Tag + '"')
  [IO.File]::WriteAllText($f, $text)
}
Set-BackendTag 1.1.0
```

**Крок 2.** Коміт і push:

```powershell
git diff                                   # показати: змінився лише тег
git commit -am "Release cavalry 1.1.0"
git push
```

- `git commit -am`: `-a` додає всі змінені відстежувані файли, `-m` задає повідомлення.

**Крок 3.** Не чекати опитування Git (до 3 хв), а одразу оновити:

```powershell
argocd app get cavalry --refresh
kubectl -n cavalry get pods -w            # новий под backend → 1/1 Running, старий зникає; Ctrl+C
```

- `--refresh`: Argo CD негайно перечитує Git. Одразу після refresh видно `OutOfSync from main (<новий коміт>)`, потім автосинхронізація.
- В інтерфейсі те саме: кнопка **Refresh** → `OutOfSync` → автоматичний Sync → новий ReplicaSet і под у дереві.

Розкатка займає близько 1–1,5 хв: старт Spring Boot і `initialDelaySeconds` проби готовності.

**Крок 4.** Перевірити нову версію:

```powershell
argocd app get cavalry                     # Synced / Healthy
curl.exe -s localhost:8081/version
```

Очікувано:

```
{"service":"cavalry-backend","version":"1.1.0","message":"Cavalry is up and charging"}
```

Видима зміна: інший номер версії і нове поле `message`.

> Якщо `curl.exe` нічого не повернув, повторіть через 2–3 с. Port-forward у терміналі 2 саме переключається на новий под.

У реальному проєкті коміт зі зміною тегу робить CI одразу після збірки образу. Людина лише мерджить PR у репозиторій конфігурації.

### 6.4. Пункт 6a: дрейф і selfHeal

**Без selfHeal.** Ручна зміна кластера в обхід Git:

```powershell
kubectl -n cavalry scale deployment cavalry-backend --replicas=3
argocd app get cavalry
kubectl -n cavalry get deploy cavalry-backend
argocd app diff cavalry
```

Очікувано:

```
Sync Status:        OutOfSync from main (...)
apps   Deployment   cavalry   cavalry-backend   OutOfSync ...

NAME              READY   UP-TO-DATE   AVAILABLE
cavalry-backend   1/3     3            1

===== apps/Deployment cavalry/cavalry-backend ======
<   replicas: 3          ← у кластері
---
>   replicas: 1          ← у Git
```

- `argocd app diff`: показує різницю між кластером і Git.
- Argo CD **бачить** розбіжність (OutOfSync), але нічого не виправляє: автосинхронізація реагує лише на нові коміти, а ручні зміни кластера повертає тільки `selfHeal`. Репліки лишаються 3.

> Беремо 3 репліки, а не 5: кожна репліка бекенда просить 512 МБ пам'яті, а minikube має 6 ГБ.

**Вмикаємо selfHeal через Git.** Змінити в `argocd-apps\cavalry.yaml`:

```yaml
      selfHeal: false            # switched to true in step 6a
```

на

```yaml
      selfHeal: true
```

Або командою:

```powershell
$f = Join-Path (Get-Location) 'argocd-apps\cavalry.yaml'
[IO.File]::WriteAllText($f, ([IO.File]::ReadAllText($f) -replace 'selfHeal: false', 'selfHeal: true'))
```

```powershell
git diff
git commit -am "Enable selfHeal for cavalry"
git push
argocd app get root --refresh
```

- Цей файл застосовує **root**, а не ми. `root --refresh` змушує root негайно прочитати Git і оновити Application `cavalry`.
- Щойно selfHeal увімкнеться, Argo CD **одразу** поверне репліки 3 → 1, бо дрейф уже є.

```powershell
kubectl -n argocd get application cavalry -o jsonpath='{.spec.syncPolicy.automated}'
kubectl -n cavalry get deploy cavalry-backend
```

Очікувано: `{"prune":true,"selfHeal":true}` і `1/1`.

**Повторюємо ручну зміну.** У другому вікні (або в терміналі 3) запустіть спостереження, потім scale:

```powershell
kubectl -n cavalry get deploy cavalry-backend -w
```

```powershell
kubectl -n cavalry scale deployment cavalry-backend --replicas=3
```

Через 1–2 секунди кількість реплік повертається до 1. В інтерфейсі в історії подій видно автоматичну синхронізацію (self-heal).

### 6.5. Пункт 6b: Synced, але Degraded

Вказати в Git неіснуючий тег:

```powershell
Set-BackendTag 9.9.9          # або вручну tag: "9.9.9" у values-minikube.yaml
git commit -am "Release cavalry 9.9.9"
git push
argocd app get cavalry --refresh
kubectl -n cavalry get pods
```

Одразу:

```
Sync Status:        Synced to main (...)
Health Status:      Progressing

NAME                               READY   STATUS         RESTARTS   AGE
cavalry-backend-67cd96957c-5fdg7   1/1     Running        0          4m
cavalry-backend-84b7cf4df8-rcmmn   0/1     ErrImagePull   0          29s
```

Приблизно через 2 хв (`progressDeadlineSeconds: 120`) знову:

```powershell
argocd app get cavalry
```

```
Sync Status:        Synced to main (...)
Health Status:      Degraded
apps   Deployment   cavalry   cavalry-backend   Synced  Degraded   ...
```

Пояснення:

- **Sync Status = Synced**: маніфест у кластері такий самий, як у Git. Argo CD виконав свою роботу: тег `9.9.9` застосовано.
- **Health Status = Degraded**: стан об'єктів поганий. Новий под не може завантажити образ (`ErrImagePull` / `ImagePullBackOff`), Deployment перевищив `progressDeadlineSeconds`.
- Synced і Healthy незалежні: перше означає «кластер = Git», друге означає «застосунок справді працює».
- Застосунок при цьому **досі відповідає** старою версією, бо rolling update не прибирає старий под, поки новий не готовий:

```powershell
curl.exe -s localhost:8081/version         # 1.1.0
kubectl -n cavalry describe pod -l app.kubernetes.io/component=backend | Select-String "Failed"
```

Остання команда показує причину: рядки `Failed to pull image "ghcr.io/darmohrai/cavalry/cavalry-backend:9.9.9"` і `ErrImagePull` / `ImagePullBackOff`.

### 6.6. Пункт 6c: відкат через git revert

Відкочуємо **опис** у Git, а не кластер:

```powershell
git log --oneline
git revert --no-edit HEAD
git push
argocd app get cavalry --refresh
```

- `git log --oneline`: історія комітів, зверху `Release cavalry 9.9.9`.
- `git revert --no-edit HEAD`: створює **новий** коміт, який скасовує зміни останнього коміту. Історія не переписується, тож видно і помилку, і виправлення. Якщо коміт з 9.9.9 не останній, замість `HEAD` вкажіть його хеш з `git log`.
- `--no-edit`: не відкривати редактор для повідомлення коміту.

Через кілька секунд:

```powershell
argocd app get cavalry                    # Synced / Healthy
kubectl -n cavalry get pods
curl.exe -s localhost:8081/version         # 1.1.0
git log --oneline
argocd app history cavalry
```

Очікувано (`argocd app history`):

```
SOURCE  https://github.com/Darmohrai/cavalry-gitops.git
ID      DATE                            REVISION
0       2026-10-22 02:36:28 +0300 EEST  main (1476174)
...
4       2026-10-22 03:04:07 +0300 EEST  main (9919737)     ← 9.9.9
5       2026-10-22 03:06:31 +0300 EEST  main (895316b)     ← revert
```

- Кожна синхронізація прив'язана до конкретного коміту. Хеші збігаються з `git log`.
- Відкат швидкий (секунди): Kubernetes повертає вже наявний ReplicaSet з образом 1.1.0, нові поди не потрібні.

Чому не `argocd app rollback`: він працює лише з **вимкненою** автосинхронізацією. Інакше Argo CD одразу поверне стан із Git, бо Git є джерелом правди. Тому в GitOps відкочуються комітом.

---

## 7. Прохання викладача: змінити будь-яке значення

Схема завжди та сама: **змінити файл → commit → push → refresh → перевірити**.

### Кількість реплік

У `charts\cavalry\values-minikube.yaml`, блок `backend:`: `replicas: 1` → `replicas: 2`.

```powershell
git commit -am "Scale backend to 2 replicas"
git push
argocd app get cavalry --refresh
kubectl -n cavalry get deploy cavalry-backend -w
```

### Змінна оточення (перевірено)

У `charts\cavalry\values-minikube.yaml`, блок `backend:`:

```yaml
  extraEnv: []
```

замінити на

```yaml
  extraEnv:
    - name: APP_MESSAGE
      value: "Hello from Git"
```

```powershell
git commit -am "Set APP_MESSAGE for cavalry backend"
git push
argocd app get cavalry --refresh
kubectl -n cavalry get pods -w            # дочекатись нового пода 1/1; Ctrl+C
curl.exe -s localhost:8081/version
```

Очікувано (перевірено):

```
{"service":"cavalry-backend","version":"1.1.0","message":"Hello from Git"}
```

Те саме для інших значень: ресурси, проби, тег notification-service тощо. Якщо викладач змінить щось **вручну** в кластері (`kubectl edit`, `kubectl scale`), то при `selfHeal: true` Argo CD це поверне.

---

## 8. Повернення у стартовий стан (щоб показати ще раз)

Стартовий стан: бекенд 1.0.0, `selfHeal: false`, без `APP_MESSAGE`.

```powershell
cd D:\uni\Java\cavalry-gitops
Set-BackendTag 1.0.0     # функцію спершу оголосити в цьому терміналі (розділ 6.3)
```

Далі вручну:
- у `argocd-apps\cavalry.yaml` поставити `selfHeal: false`;
- у `values-minikube.yaml` повернути `extraEnv: []` і `replicas: 1`.

```powershell
git diff
git commit -am "Reset to 1.0.0 without selfHeal before the demo"
git push
argocd app get root --refresh
argocd app get cavalry --refresh
argocd app wait cavalry --sync --health --timeout 300
curl.exe -s localhost:8081/version         # 1.0.0
```

- `argocd app wait`: чекає, поки застосунок стане Synced і Healthy.

Зараз репозиторій уже в стартовому стані (коміт `Reset to 1.0.0 without selfHeal before the demo`).

---

## 9. Встановлення з нуля (якщо кластер видалено)

Потрібно лише якщо виконувалось `minikube delete`. Після `minikube stop` / перезавантаження ПК достатньо розділу 5.

### 9.1. Кластер

```powershell
minikube start --driver=docker --cpus=4 --memory=6144
```

Якщо Docker Desktop має менше 7 ГБ пам'яті (Settings → Resources), використайте `--memory=5120`.

> minikube попереджає, що `kubectl` 1.32 старіший за Kubernetes 1.37. Усі команди з цього файлу працюють; за бажанням можна оновити kubectl.

### 9.2. Argo CD

```powershell
kubectl create namespace argocd
kubectl apply -n argocd --server-side --force-conflicts -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl -n argocd wait --for=condition=Ready pods --all --timeout=600s
kubectl -n argocd get pods
```

- `kubectl apply --server-side`: застосування на боці API-сервера. Маніфест Argo CD містить великі CRD, які не влазять в анотацію `last-applied-configuration` звичайного `apply`.
- `--force-conflicts`: перезаписати поля, якими раніше керував інший менеджер (важливо при повторному встановленні).

### 9.3. CLI `argocd`

Уже встановлено: `C:\Users\Admin_\bin\argocd.exe`, каталог додано в PATH користувача. На іншому ПК:

```powershell
New-Item -ItemType Directory -Force "$env:USERPROFILE\bin" | Out-Null
curl.exe -sSL -o "$env:USERPROFILE\bin\argocd.exe" https://github.com/argoproj/argo-cd/releases/latest/download/argocd-windows-amd64.exe
[Environment]::SetEnvironmentVariable('Path', [Environment]::GetEnvironmentVariable('Path','User') + ";$env:USERPROFILE\bin", 'User')
```

Після цього відкрийте **новий** термінал і виконайте `argocd version --client`.

### 9.4. Вхід і зміна пароля

Термінал 1 (port-forward у циклі, див. 5.2):

```powershell
while ($true) { kubectl -n argocd port-forward svc/argocd-server 8080:443; Start-Sleep 1 }
```

Термінал 3:

```powershell
argocd admin initial-password -n argocd
argocd login localhost:8080 --username admin --insecure --grpc-web
argocd account update-password
kubectl -n argocd delete secret argocd-initial-admin-secret
```

- `argocd admin initial-password`: читає початковий пароль із секрету `argocd-initial-admin-secret`.
- `argocd login`: запитає пароль, вставте початковий.
- `argocd account update-password`: запитає поточний і новий пароль (наприклад `cavalry-argo-2026`).
- `delete secret argocd-initial-admin-secret`: після зміни пароля початковий секрет не потрібен, і зберігати його небезпечно.

### 9.5. Secret застосунку і запуск через root

```powershell
kubectl create namespace cavalry
kubectl -n cavalry create secret generic cavalry-secret `
  --from-literal=POSTGRES_DB=ev_charge_db `
  --from-literal=POSTGRES_USER=root `
  --from-literal=POSTGRES_PASSWORD=rootpassword `
  --from-literal=KEYCLOAK_ADMIN=admin `
  --from-literal=KEYCLOAK_ADMIN_PASSWORD=admin

cd D:\uni\Java\cavalry-gitops
kubectl apply -f bootstrap/root.yaml
argocd app list
argocd app wait cavalry --sync --health --timeout 900
kubectl -n cavalry get pods
```

Перше розгортання займає 5–10 хв: завантажуються образи Keycloak, Postgres, RabbitMQ і Java-сервісів. Поки образи тягнуться, бекенд може на кілька хвилин показати `Degraded` (перевищено `progressDeadlineSeconds: 120`) і сам стане `Healthy`, щойно под запуститься. Якщо `argocd app wait` завершився з помилкою через цей перехід, просто запустіть його ще раз.

---

## 10. Типові проблеми та їх рішення

| Симптом | Причина | Рішення |
|---|---|---|
| `argocd ...`: `connection refused` / `lost connection to pod` | Обірвався `kubectl port-forward` | Port-forward у циклі (розділ 5.2); логін з `--grpc-web` |
| `curl.exe localhost:8081/version` нічого не повертає після оновлення | Port-forward був прив'язаний до старого пода | Цикл у терміналі 2 перепідключиться, повторіть через 2–3 с |
| `curl` у PowerShell виводить таблицю `StatusCode ...` | `curl` = `Invoke-WebRequest` у PowerShell 5.1 | Використовувати `curl.exe` |
| Поди довго в `Init`, notification у `CrashLoopBackOff`, Keycloak стартує хвилинами | Мало CPU: інші контейнери Docker забирають ресурси | `docker stats`, зупинити зайві контейнери, `kubectl -n cavalry delete pod -l app.kubernetes.io/component=notification` |
| minikube раптом `Stopped` | Перезапуск Docker Desktop зупиняє контейнер minikube | `minikube start` (стан збережено) |
| `ImagePullBackOff` на правильному тезі | Пакет у GHCR приватний | GitHub → Packages → Package settings → Public |
| `ErrImagePull ... no such host` | Тимчасовий збій DNS / мережі | Kubernetes сам повторить завантаження |
| Зміна не приїхала | Push не в `main` або ще не минув інтервал опитування | `git status`, `git push`, `argocd app get cavalry --refresh` |
| `values-minikube.yaml: no such file` | `valueFiles` шукаються відносно `path` чарту | Файл має лежати в `charts/cavalry/` |
| Після `kubectl edit application cavalry` зміна зникла | `root` має `selfHeal: true` і повертає Application з Git | Змінювати `argocd-apps/cavalry.yaml` у Git |
| `ComparisonError: repository not found` | Помилка в `repoURL` або репозиторій став приватним | Перевірити URL; для приватного: `argocd repo add ... --username ... --password <token>` |

---

## 11. Теорія: відповіді на ймовірні питання

**Що таке GitOps?** Підхід, де бажаний стан інфраструктури й застосунків описаний декларативно в Git, а агент у кластері (Argo CD) безперервно приводить кластер до цього стану. Чотири принципи OpenGitOps: декларативність, версіонованість і незмінність (Git), автоматичне отримання змін (pull), безперервна узгодженість (reconciliation).

**Pull vs push.** У класичному CI/CD пайплайн сам виконує `helm upgrade` у кластері (push), тож йому потрібні облікові дані до кластера. У GitOps агент у кластері сам тягне зміни з Git (pull). Доступ до кластера ззовні не потрібен, а Git є журналом аудиту.

**Навіщо App of Apps?** Вручну застосовується лише один `root`. Усі інші Application-и описані в Git, тому новий застосунок чи компонент кластера (Argo Rollouts, моніторинг у ЛР-6/7) додається одним файлом в `argocd-apps/`. Кластер можна повністю відтворити з Git однією командою.

**Synced vs Healthy.** Synced/OutOfSync показує, чи збігається кластер із Git. Healthy/Progressing/Degraded показує, чи працюють ресурси. Вони незалежні: у пункті 6b було Synced + Degraded, а в 6a Healthy + OutOfSync.

**prune vs selfHeal.** `automated` синхронізує при новому коміті. `prune` видаляє з кластера ресурси, яких більше немає в Git. `selfHeal` повертає ручні зміни кластера до стану з Git.

**Чому `helm list` порожній?** Argo CD рендерить чарт через `helm template` і застосовує маніфести сам. Helm-релізу (секрету `sh.helm.release.v1...`) не створюється, історію веде Argo CD (`argocd app history`).

**Чому Helm-хуки вимкнено?** Argo CD перетворює `pre-install`/`pre-upgrade` на PreSync-хук, який виконується перед **кожною** синхронізацією. На першій синхронізації PostgreSQL ще не існує, Job перевірки БД падає, і синхронізація зупиняється. Тест-хуки (`helm test`) Argo CD не підтримує, тому тестовий под теж вимкнено.

**Чому відкат через `git revert`, а не `argocd app rollback`?** Джерело правди — Git. Rollback змінив би кластер, але при увімкненій автосинхронізації Argo CD одразу повернув би стан із Git. `git revert` змінює сам опис і зберігає повну історію.

**Як часто Argo CD перевіряє Git?** За замовчуванням раз на 3 хвилини (`timeout.reconciliation`). Кнопка Refresh або `--refresh` перевіряє негайно. У продакшні ставлять webhook з GitHub.

**Де секрети?** Не в Git. Secret `cavalry-secret` створено вручну, чарт посилається на нього через `existingSecret`. Argo CD не видаляє його навіть з `prune`, бо він не з Git. Повноцінні варіанти: Sealed Secrets, SOPS, External Secrets Operator.

**Чому образи з тегами, а не `latest`?** Тег у Git однозначно визначає, яка версія працює. Зміна тегу є комітом з історією, і відкат можливий. Для `latest` Git не змінюється, Argo CD не бачить різниці, і невідомо, що саме запущено.

**Як образ потрапляє в кластер без `minikube image load`?** Образи публікуються в публічний GHCR, і kubelet у minikube тягне їх з інтернету за `image.repository:tag` з чарту.
