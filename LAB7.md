# Лабораторна робота №7. Observability: метрики, логи, дашборди й відкат за метриками

**Дисципліна:** Технології DevOps
**Проєкт:** Cavalry, мережа зарядних станцій для електромобілів (`cavalry-backend`, `notification-service`, PostgreSQL, RabbitMQ, Keycloak)
**Вихідні дані:** репозиторій `cavalry-gitops` під керуванням Argo CD ([LAB5.md](LAB5.md)) з canary-релізами Argo Rollouts ([LAB6.md](LAB6.md))
**Середовище:** Windows 10, Docker Desktop, minikube (**4 CPU, 8 ГБ**), Argo CD, Argo Rollouts, PowerShell

Цей файл пояснює, **що** зроблено і **чому так**. Як саме здавати (порядок дій на захисті, команди, що показати й що сказати) описано в [LAB7-DEFENSE.md](LAB7-DEFENSE.md).

Назви з методички відповідають так:

| У методичці | У цьому проєкті |
|---|---|
| `myapp-gitops` | `cavalry-gitops` (`D:\uni\Java\cavalry-gitops`) |
| namespace `myapp`, Service `myapp` | namespace `cavalry`, Service `cavalry-backend` (порт **8082**, ім'я порту `http`) |
| `/metrics` | `/actuator/prometheus` (Spring Boot Actuator) |
| `http_requests_total` | `http_server_requests_seconds_count` |
| `http_request_duration_seconds_bucket` | `http_server_requests_seconds_bucket` |
| мітка `route` | мітка `uri` (шаблон маршруту, напр. `/api/stations/{id}`) |
| `rollout.analysis` у values | `backend.rollout.analysis` (Rollout лише для бекенду) |
| `env:` у values | `backend.extraEnv` (вже був у чарті з ЛР-5) |
| AnalysisTemplate `myapp-success-rate` | `cavalry-success-rate` |
| `level="error"` у LogQL | `level="ERROR"` (формат logstash пише рівень великими літерами) |

---

## Зміст

1. [Що зроблено: відповідність пунктам завдання](#1-що-зроблено-відповідність-пунктам-завдання)
2. [Як усе влаштовано](#2-як-усе-влаштовано)
3. [Пункт 1. Стек моніторингу через Argo CD](#3-пункт-1-стек-моніторингу-через-argo-cd)
4. [Пункт 2. Метрики застосунку](#4-пункт-2-метрики-застосунку)
5. [Пункт 3. Логи в JSON і Loki](#5-пункт-3-логи-в-json-і-loki)
6. [Пункт 4. Дашборд як код](#6-пункт-4-дашборд-як-код)
7. [Пункт 5. Навантаження](#7-пункт-5-навантаження)
8. [Пункт 6. Автоматичний відкат за метриками](#8-пункт-6-автоматичний-відкат-за-метриками)
9. [Одноразова підготовка (lab7-setup.ps1)](#9-одноразова-підготовка-lab7-setupps1)
10. [Відхилення від методички і чому](#10-відхилення-від-методички-і-чому)
11. [Типові проблеми та їх рішення](#11-типові-проблеми-та-їх-рішення)
12. [Теорія: відповіді на ймовірні питання](#12-теорія-відповіді-на-ймовірні-питання)

---

## 1. Що зроблено: відповідність пунктам завдання

| Пункт | Що зроблено | Де |
|---|---|---|
| 1 | Три Application, по одному на чарт, версії зафіксовані: `kube-prometheus-stack` **92.17.1**, `loki` **20.2.2** (репозиторій `grafana-community`), `alloy` **1.15.0**. Пароль Grafana — у Secret `grafana-admin`, створеному вручну | `argocd-apps/kps.yaml`, `loki.yaml`, `alloy.yaml` |
| 2a | `/actuator/prometheus` (Actuator + `micrometer-registry-prometheus`): лічильник і гістограма `http_server_requests_seconds` з мітками `method`, `uri` (шаблон, не URL), `status`. Гістограму (бакети для p95) вмикає `percentiles-histogram` | репозиторій застосунку, гілка `lab7-observability`: `pom.xml`, `application.yml` |
| 2b | `ServiceMonitor` у чарті; порт Service названо `http`; Service отримав мітку `component: backend`, щоб ServiceMonitor вибирав лише бекенд | `templates/servicemonitor.yaml`, `backend-service.yaml` |
| 3 | У профілі `prod` (у кластері) усі логи — JSON у stdout (`logging.structured.format.console=logstash`). Фільтр пише рядок на кожен запит: `@timestamp`, `level`, `message`, `method`, `route`, `status`, `duration_ms`, `version` | `RequestObservabilityFilter.java`, `application.yml` |
| 4 | Дашборд **Cavalry backend** (9 панелей): RPS, частка 5xx, p95/p50, 5xx по подах, RPS по ReplicaSet, p95 по маршрутах, CPU, пам'ять, логи помилок з Loki. JSON у чарті, ConfigMap з міткою `grafana_dashboard: "1"` | `dashboards/cavalry.json`, `templates/dashboard.yaml` |
| 5 | Фоновий трафік `demo/load.yaml`, короткий тест `hey`; «інша зміна»: повільний ендпоінт `/slow` (зростання p95) і `kubectl delete pod` | `demo/load.yaml`, `SlowController.java` |
| 6a | `AnalysisTemplate cavalry-success-rate` (частка не-5xx ≥ 95 %), підключений кроком `analysis` у canary замість ручної паузи ЛР-6 | `templates/analysistemplate.yaml`, `values-minikube.yaml` |
| 6b | Змінна `FAIL_RATE` (частка запитів, що отримують 500), задається з Git через `backend.extraEnv` | `RequestObservabilityFilter.java`, `values-minikube.yaml` |
| 6c | Сценарій: коміт `FAIL_RATE="0.5"` → AnalysisRun `Failed` → abort → stable → `git revert` | [LAB7-DEFENSE.md](LAB7-DEFENSE.md) |
| 6d* | `PrometheusRule CavalryHighErrorRate` (> 5 % 5xx протягом 1 хв) | `templates/prometheusrule.yaml` |

Версія чарту `0.4.0 → 0.5.0`. Образ бекенду `1.3.0 → 1.5.0` (перший з метриками), `1.6.0` — той самий код під іншим тегом для демонстрації «хорошого» релізу.

**Що перевірено, а що ні.** Перевірено локально: тести бекенду (24, з них 5 нових для фільтра), реальний запуск застосунку в профілі `prod` з Postgres і Keycloak у Docker (JSON-логи, `/actuator/prometheus` з бакетами, `FAIL_RATE=0.5` дає ≈ 50 % відповідей 500, ендпоінти `/slow` і `/actuator/*` доступні без токена), `helm lint` / `helm template` чарту і всіх трьох чартів моніторингу з нашими values. **На кластері ще не запускалося**: перший прогін робить `lab7-setup.ps1` (розділ 9), тож очікувані виводи в [LAB7-DEFENSE.md](LAB7-DEFENSE.md) — розрахункові, звірте їх на репетиції.

---

## 2. Як усе влаштовано

```
 Git: cavalry-gitops                          minikube (4 CPU, 8 GB)
 ┌──────────────────────────────┐   ┌─────────────────────────────────────────────────────────┐
 │ argocd-apps/                 │   │ ns monitoring                                            │
 │   kps.yaml   (-1) ───────────┼──►│  Prometheus ◄── scrape /actuator/prometheus (15s) ──┐     │
 │   loki.yaml  (-1) ───────────┼──►│  Loki ◄── push ── Alloy ◄── логи подів (K8s API)    │     │
 │   alloy.yaml ────────────────┼──►│  Grafana: джерела Prometheus + Loki, дашборд з CM   │     │
 │   argo-rollouts.yaml (-1)    │   │  Alertmanager ◄── PrometheusRule                    │     │
 │   cavalry.yaml ──────────────┼──►│ ns cavalry                                          │     │
 │ charts/cavalry/templates/    │   │  Rollout cavalry-backend ── 5 подів ────────────────┘     │
 │   servicemonitor.yaml        │   │    крок analysis ── AnalysisRun ── PromQL ──► Prometheus │
 │   analysistemplate.yaml      │   │  ServiceMonitor, PrometheusRule, ConfigMap (дашборд)     │
 │   prometheusrule.yaml        │   │ ns default                                               │
 │   dashboard.yaml + JSON      │   │  Deployment load ── curl /version ──► Service backend    │
 └──────────────────────────────┘   └─────────────────────────────────────────────────────────┘
```

Три «стовпи» observability і хто за що відповідає:

| Що | Хто збирає | Де зберігається | Мова запитів | Що відповідає |
|---|---|---|---|---|
| **Метрики** (числа в часі) | Prometheus сам ходить (pull) на `/actuator/prometheus` кожні 15 с; куди ходити — каже ServiceMonitor | Prometheus TSDB, 2 доби | PromQL | «скільки, як швидко, яка частка помилок» |
| **Логи** (події) | застосунок пише JSON у stdout → kubelet у файл → Alloy читає через K8s API → push у Loki | Loki (індекс лише міток, вміст стиснутий) | LogQL | «що саме сталося з конкретним запитом» |
| **Дашборд / алерти** | Grafana читає обидва джерела; Prometheus обчислює правила, Alertmanager розсилає | дашборд — JSON у Git | — | «побачити разом» і «дізнатися, не дивлячись» |

Замикання циклу (пункт 6): ті самі метрики використовує **Argo Rollouts**. Крок `analysis` створює `AnalysisRun`, який кожні 30 с виконує PromQL-запит. Якщо частка успішних запитів < 95 % — реліз скасовується **без людини**.

---

## 3. Пункт 1. Стек моніторингу через Argo CD

### 3.1. `argocd-apps/kps.yaml` (kube-prometheus-stack)

Один чарт ставить: **Prometheus Operator** (керує Prometheus через CRD), **Prometheus**, **Alertmanager**, **Grafana**, **kube-state-metrics** (стан об'єктів K8s), **node-exporter** (метрики вузла) і готові правила/дашборди для кластера. Метрики контейнерів (CPU, пам'ять) Prometheus бере з **cAdvisor** у kubelet.

Ключові налаштування:

| Параметр | Навіщо |
|---|---|
| `fullnameOverride: kps` | короткі імена сервісів: `kps-prometheus`, `kps-grafana`, `kps-alertmanager` (без них були б `kps-kube-prometheus-stack-prometheus`) |
| `sync-wave: "-1"` | root створює його раніше за `cavalry`: CRD `ServiceMonitor`/`PrometheusRule` мають існувати до чарту застосунку |
| `ServerSideApply=true` | CRD цього чарту (напр. `prometheuses`) більші за 256 КБ — ліміт анотації `last-applied-configuration` звичайного `kubectl apply` |
| `kubeEtcd/ControllerManager/Scheduler/Proxy: false` | у minikube ці компоненти слухають лише localhost, скрейп дав би вічно червоні цілі й алерти |
| `admissionWebhooks/tls: false` | менше рухомих частин: без вебхука і Job-ів, що генерують для нього сертифікати |
| `...SelectorNilUsesHelmValues: false` | за замовчуванням Prometheus бере лише ServiceMonitor з міткою `release: kps`. `false` = брати **всі** з усіх namespace |
| `retention: 2d` | економія диска minikube |
| `grafana.admin.existingSecret` | пароль не в Git; крім того, чарт генерує випадковий пароль при рендерингу, а Argo CD рендерить на кожній синхронізації — пароль змінювався б постійно |
| `sidecar.dashboards.searchNamespace: ALL` | sidecar Grafana шукає ConfigMap-и з міткою `grafana_dashboard` в **усіх** namespace (наш — у `cavalry`) |
| `additionalDataSources: Loki (uid loki)` | джерело Loki додається з Git; `uid` фіксований, щоб дашборд посилався на нього |

Джерело Prometheus чарт створює сам з `uid: prometheus` (перевірено `helm template`), на нього посилається дашборд.

### 3.2. `argocd-apps/loki.yaml`

`deploymentMode: SingleBinary` — усі компоненти Loki (distributor, ingester, querier, ...) в **одному процесі**, одна репліка, сховище — файлова система поду. Для навчального кластера досить; у продакшні — режим SimpleScalable/Distributed і S3. Вимкнено кеші (`chunksCache`, `resultsCache` — це окремі memcached на гігабайти), `lokiCanary`, `test`. `read/write/backend: 0` — поди інших режимів не потрібні. `auth_enabled: false` — один tenant, не треба заголовка `X-Scope-OrgID`.

Перед Loki стоїть **gateway** (nginx) — сервіс `loki-gateway` на порту 80: туди пушить Alloy і звідти читає Grafana.

Чарт з березня 2026 року підтримує спільнота, тому репозиторій `grafana-community`, а не `grafana`.

### 3.3. `argocd-apps/alloy.yaml`

Grafana Alloy — агент збору (наступник Promtail і Grafana Agent). Конфіг на мові Alloy (River) — це конвеєр компонентів:

```
discovery.kubernetes "pods"   — список усіх подів кластера з K8s API
        ↓
discovery.relabel "pods"      — з метаданих робимо мітки Loki: namespace, pod, container, app, component
        ↓
loki.source.kubernetes "pods" — читає логи цих подів через K8s API (як kubectl logs)
        ↓
loki.write "default"          — пушить у http://loki-gateway.monitoring/loki/api/v1/push
```

`controller.type: deployment, replicas: 1`: одна репліка читає логи через API, тому не потрібен DaemonSet з доступом до файлів вузла. Порівняно з методичкою додано мітки `container` і `component` (з `app.kubernetes.io/component`): у чарті Cavalry **усі** поди мають `app.kubernetes.io/name=cavalry`, тож лише `component=backend` відрізняє бекенд від Keycloak/Postgres.

### 3.4. Два коміти

Як і в ЛР-6, стек моніторингу — **окремий коміт** (`Add monitoring stack`), і лише після `Healthy` — коміт з `ServiceMonitor` у чарті. Інакше `cavalry` синхронізується до появи CRD і впаде з `no matches for kind ServiceMonitor` (у `cavalry.yaml` вже є `retry` і `SkipDryRunOnMissingResource=true` з ЛР-6, тож він би відновився, але так чистіше).

---

## 4. Пункт 2. Метрики застосунку

### 4.1. Код (репозиторій застосунку, гілка `lab7-observability`)

Застосунок на Spring Boot 3.5, тому метрики не пишемо вручну — це робить **Micrometer** у складі Actuator:

```xml
<!-- cavalry-backend/pom.xml -->
<artifactId>spring-boot-starter-actuator</artifactId>
<artifactId>micrometer-registry-prometheus</artifactId>
```

```yaml
# application.yml
management:
  endpoints.web.exposure.include: health, prometheus   # лише ці два ендпоінти
  metrics.distribution.percentiles-histogram:
    http.server.requests: true                         # бакети гістограми
```

Spring сам вимірює кожен HTTP-запит і публікує:

| Метрика | Тип | Що це |
|---|---|---|
| `http_server_requests_seconds_count` | counter | кількість запитів (= `http_requests_total` з методички) |
| `http_server_requests_seconds_sum` | counter | сумарний час, с (середнє = sum/count) |
| `http_server_requests_seconds_bucket{le="..."}` | counter | скільки запитів тривали ≤ `le` секунд — для `histogram_quantile` |
| `http_server_requests_seconds_max` | gauge | максимум за останні ~2 хв |

Мітки: `method`, `uri`, `status`, `outcome` (`SUCCESS`, `CLIENT_ERROR`, `SERVER_ERROR`), `exception`, `error`. Prometheus додає `namespace`, `service`, `pod`, `container`, `endpoint`, `job` і (через `podTargetLabels`) `rollouts_pod_template_hash`.

**Низька кардинальність.** `uri` — це **шаблон** маршруту (`/api/stations/{id}`), а не реальна адреса (`/api/stations/0b5e...`). Інакше кожен UUID створював би новий часовий ряд — мільйони рядів і падіння Prometheus. Запити, що не дійшли до контролера (401 від Security, впорскнуті 500), отримують `uri="UNKNOWN"` — теж одне значення.

Безпека: `/actuator/prometheus` і `/actuator/health` додано в `permitAll()` у `SecurityConfig`, бо Prometheus ходить без токена (інакше 302 на Keycloak і ціль `DOWN`). Інші ендпоінти Actuator не відкриті.

Перевірено локально (уривок `/actuator/prometheus` після 20 запитів з `FAIL_RATE=0.5`):

```
http_server_requests_seconds_count{...,method="GET",outcome="SERVER_ERROR",status="500",uri="UNKNOWN"} 15
http_server_requests_seconds_count{...,method="GET",outcome="SUCCESS",status="200",uri="/version"} 7
```

### 4.2. `templates/servicemonitor.yaml`

ServiceMonitor — CRD Prometheus Operator: «скрейпи поди за Service з такими мітками, порт з таким ім'ям, такий шлях». Оператор перетворює його на конфіг Prometheus.

```yaml
spec:
  selector:
    matchLabels: {app.kubernetes.io/name: cavalry, app.kubernetes.io/instance: cavalry,
                  app.kubernetes.io/component: backend}     # лише Service бекенду
  podTargetLabels: [rollouts-pod-template-hash]             # stable vs canary на дашборді
  endpoints:
    - port: http                     # ІМ'Я порту в Service (тому додано name: http)
      path: /actuator/prometheus
      interval: 15s
```

Prometheus скрейпить **кожен под** окремо (через Endpoints сервісу), а не Service — тому видно метрики по подах.

---

## 5. Пункт 3. Логи в JSON і Loki

### 5.1. Формат

Spring Boot 3.4+ вміє структуровані логи без бібліотек. У профілі `prod` (у кластері `SPRING_PROFILES_ACTIVE=prod` приходить з ConfigMap чарту):

```yaml
logging.structured.format.console: logstash   # JSON, один об'єкт на рядок
spring.main.banner-mode: off                  # ASCII-банер не JSON
spring.jpa.show-sql: false                    # show-sql пише SQL прямо в stdout повз логер
```

Локально (без `prod`) логи лишаються звичайним текстом — зручно для розробки.

`RequestObservabilityFilter` додає рядок на кожен запит. Поля кладуться в **MDC**, а форматер logstash виносить MDC у верхній рівень JSON:

```json
{"@timestamp":"2026-11-03T15:08:27.96+02:00","@version":"1","message":"request","logger_name":"http.access",
 "thread_name":"http-nio-8082-exec-2","level":"ERROR","level_value":40000,
 "duration_ms":"4.1","route":"UNKNOWN","method":"GET","version":"1.5.0","status":"500"}
```

Рівень `ERROR` для статусів ≥ 500, `INFO` для решти. `/actuator/**` не логується (скрейп кожні 15 с засмічував би логи).

### 5.2. Шлях логу

```
stdout контейнера → kubelet: /var/log/pods/... → Alloy (loki.source.kubernetes, K8s API)
  → мітки {namespace, pod, container, app, component} → Loki → Grafana Explore
```

Loki **індексує лише мітки**, а не текст. Тому запит завжди починається з селектора міток `{namespace="cavalry", component="backend"}`, а поля JSON розбираються вже під час запиту (`| json`). Мітки мають бути з малою кардинальністю — `status` чи `route` міткою Loki робити **не можна**, це поля.

### 5.3. LogQL

```logql
{namespace="cavalry", component="backend"}                                    # усі логи бекенду
{namespace="cavalry", component="backend"} | json | status >= 500             # лише 5xx
{namespace="cavalry", component="backend"} | json | level="ERROR"             # лише помилки
{namespace="cavalry", component="backend"} | json | duration_ms > 200
    | line_format "{{.route}} {{.duration_ms}}ms"                             # повільні, коротко
sum by (pod) (count_over_time({namespace="cavalry", component="backend"} | json | status >= 500 [1m]))
                                                                              # 5xx за хвилину по подах
```

`| json` перетворює поля JSON на тимчасові мітки; `status >= 500` — числове порівняння (рядок `"500"` перетворюється на число).

---

## 6. Пункт 4. Дашборд як код

`charts/cavalry/dashboards/cavalry.json` → `templates/dashboard.yaml`:

```yaml
kind: ConfigMap
metadata:
  name: cavalry-dashboard
  labels:
    grafana_dashboard: "1"           # sidecar Grafana шукає саме цю мітку
data:
  cavalry.json: |-
{{ .Files.Get "dashboards/cavalry.json" | indent 4 }}
```

`.Files.Get` вставляє файл **без** обробки шаблонізатором, тому `{{pod}}` у легендах Grafana не конфліктує з Helm. Sidecar (контейнер поруч з Grafana) стежить за ConfigMap-ами і кладе JSON у теку, з якої Grafana підвантажує дашборди. Такий дашборд у UI позначений як provisioned: зберегти зміни в UI не можна, правки — через експорт і коміт.

Панелі (діапазон 15 хв, автооновлення 10 с), де `SEL = namespace="cavalry",service="cavalry-backend",uri!~"/actuator.*"`:

| Панель | PromQL / LogQL | Одиниця |
|---|---|---|
| Запити за секунду | `sum(rate(http_server_requests_seconds_count{SEL}[1m]))` + `sum by (status)` | req/s |
| Частка 5xx | `sum(rate(...{SEL,status=~"5.."}[1m])) / sum(rate(...{SEL}[1m]))`, лінія порогу 5 % | 0.0–1.0 |
| p95 / p50 | `histogram_quantile(0.95, sum by (le) (rate(http_server_requests_seconds_bucket{SEL}[1m])))` | s |
| 5xx по подах | `sum by (pod) (rate(...{SEL,status=~"5.."}[1m]))` | req/s |
| RPS по ReplicaSet | `sum by (rollouts_pod_template_hash) (rate(...{SEL}[1m]))` | req/s |
| p95 по маршрутах | `histogram_quantile(0.95, sum by (le, uri) (rate(..._bucket{SEL}[1m])))` | s |
| CPU подів | `sum by (pod) (rate(container_cpu_usage_seconds_total{namespace="cavalry",container="backend"}[1m]))` | ядра |
| Пам'ять подів | `sum by (pod) (container_memory_working_set_bytes{namespace="cavalry",container="backend"})` | байти |
| Логи помилок | `{namespace="cavalry", component="backend"} \| json \| level="ERROR" \| line_format ...` | Loki |

Чому `uri!~"/actuator.*"`: скрейпи Prometheus теж HTTP-запити, вони завжди успішні й розбавляли б частку помилок. Чому `container="backend"` замість `container!=""`: інакше в CPU/пам'ять потрапили б Keycloak і Postgres з того ж namespace.

---

## 7. Пункт 5. Навантаження

- `demo/load.yaml` — Deployment `load` у namespace `default` (не в чарті, не під Argo CD): `curl` на `http://cavalry-backend.cavalry.svc:8082/version` кожні 50 мс, ≈ 15–20 req/s на репліку. `kubectl scale deployment load --replicas=3` — більше трафіку.
- Короткий потужний тест (20 паралельних клієнтів, 3 хв):
  `kubectl run hey --rm -it --restart=Never --image=williamyeh/hey -- -z 3m -c 20 http://cavalry-backend.cavalry.svc:8082/version`
- **Інша зміна** (на вибір, підготовлено дві):
  - **повільний ендпоінт** `GET /slow` — випадкова затримка 0–1 с: `hey ... -c 10 http://cavalry-backend.cavalry.svc:8082/slow` → на панелях «p95» і «p95 по маршрутах» `/slow` ≈ 0,95 с;
  - **вимкнення пода** `kubectl -n cavalry delete pod <под бекенду>` → на CPU/пам'яті зникає лінія й з'являється нова (новий под), RPS ненадовго перерозподіляється, Rollout сам відновлює 5 реплік.

Навантаження йде **через Service**, як справжній клієнт: `port-forward` прив'язується до одного пода і розподілу не покаже.

---

## 8. Пункт 6. Автоматичний відкат за метриками

### 8.1. `templates/analysistemplate.yaml`

```yaml
kind: AnalysisTemplate
metadata: {name: cavalry-success-rate}
spec:
  metrics:
    - name: success-rate
      interval: 30s            # вимір кожні 30 с
      count: 4                 # 4 виміри (≈ 1,5 хв)
      failureLimit: 1          # допускається 1 невдалий; 2-й невдалий = AnalysisRun Failed
      successCondition: result[0] >= 0.95
      provider:
        prometheus:
          address: http://kps-prometheus.monitoring:9090
          query: |
            sum(rate(http_server_requests_seconds_count{namespace="cavalry",service="cavalry-backend",uri!~"/actuator.*",status!~"5.."}[1m]))
            /
            sum(rate(http_server_requests_seconds_count{namespace="cavalry",service="cavalry-backend",uri!~"/actuator.*"}[1m]))
```

Фільтр міток (`selector`) задається у values, тому той самий шаблон підходить і для blue-green (`service="cavalry-backend-preview"`).

### 8.2. Стратегія (`values-minikube.yaml`)

```yaml
backend:
  extraEnv:
    - name: FAIL_RATE
      value: "0"               # "0.5" = поганий реліз
  rollout:
    analysis: {enabled: true, ...}
    strategy:
      canary:
        steps:
          - setWeight: 20             # 1 новий под з 5
          - pause: {duration: 60s}    # накопичити метрики canary (rate за [1m])
          - analysis:                 # замість ручної паузи ЛР-6: рішення приймає Prometheus
              templates: [{templateName: cavalry-success-rate}]
          - setWeight: 60
          - pause: {duration: 30s}
          - setWeight: 80
          - pause: {duration: 30s}
```

Пауза **60 с** замість 30 с з методички: `rate(...[1m])` потребує щонайменше двох скрейпів нового пода (15 с), а в minikube под ще й повільно стає Ready. На 30 с перший вимір часто дає `NaN`.

### 8.3. Арифметика поганого релізу

5 реплік, canary = 1 под (20 % трафіку). `FAIL_RATE=0.5` → цей под відповідає 500 на половину запитів:

```
помилок = 20 % × 50 % = 10 %   →   успішних = 90 % < 95 %   →   вимір Failed
```

1-й вимір Failed (≤ failureLimit, ще чекаємо) → через 30 с 2-й Failed → **AnalysisRun Failed** → Rollout робить **abort**: canary масштабується до 0, увесь трафік на stable, статус `Degraded`. В Argo CD: `Synced / Degraded` (у Git досі «погана» версія — Git і кластер розходяться за змістом, тому завершуємо `git revert`).

### 8.4. Чому `FAIL_RATE` через `extraEnv`, а не окремий образ

Зміна змінної оточення змінює **шаблон пода** → Rollout бачить нову ревізію і запускає canary так само, як для нового тегу образу. Реліз — це коміт в один рядок, і `git revert` повертає все назад.

Фільтр `FAIL_RATE` стоїть **всередині** фільтра метрик Spring (порядок `HIGHEST_PRECEDENCE + 10` проти `+ 1`), тому впорскнуті 500 потрапляють у `http_server_requests_seconds_count{status="500"}` як справжні, і **перед** Spring Security (порядок `-100`), тому не залежать від авторизації. `/actuator/**` ніколи не ламається — інакше Prometheus втратив би ціль.

### 8.5. Алерт (6d*)

`PrometheusRule CavalryHighErrorRate`: частка 5xx > 5 % протягом `for: 1m` → `Pending` → `Firing`, видно в Prometheus → Alerts і в Alertmanager. Під час canary abort може статися раніше, ніж мине 1 хв, тому алерт може не встигнути — тоді показати його окремо (див. [LAB7-DEFENSE.md](LAB7-DEFENSE.md), розділ 6).

---

## 9. Одноразова підготовка (lab7-setup.ps1)

Скрипт робить усе, що треба один раз:

1. **Застосунок.** Зміни коду лежать у гілці `lab7-observability` репозиторію `cavalry` (окремий worktree `D:\uni\Java\cavalry-lab7`, бо в `D:\uni\Java\cavalry` на `main` є незакомічені зміни з іншої роботи — їх не чіпаємо). Скрипт пушить гілку і теги `v1.5.0`, `v1.6.0`; workflow `Release images` збирає `ghcr.io/darmohrai/cavalry/cavalry-backend:1.5.0` і `:1.6.0`.
2. **minikube 4 CPU / 8 ГБ** (питає підтвердження перед `minikube delete`). Docker Desktop має мати ≥ 10 ГБ (Settings → Resources або `%UserProfile%\.wslconfig`: `[wsl2]` `memory=12GB`).
3. **Argo CD і два Secret-и** (`cavalry-secret`, `grafana-admin`) — паролі питає, у лог не пише.
4. **Push 1** (`Add monitoring stack`) + `bootstrap/root.yaml` → чекає `kps`, `loki`, `alloy`, `argo-rollouts` `Synced/Healthy` і поки `cavalry` підніметься на старому чарті.
5. Запускає `demo/load.yaml` і підтягує образи `1.5.0`, `1.6.0` у minikube.
6. **Push 2** (чарт) → перший реліз `1.5.0` проходить canary **з аналізом** (тому трафік потрібен заздалегідь).

```powershell
powershell -ExecutionPolicy Bypass -File D:\uni\Java\cavalry-gitops\lab7-setup.ps1
```

Лог: `lab7-setup.log`. Після minikube delete пароль Argo CD скидається на початковий (див. [LAB7-DEFENSE.md](LAB7-DEFENSE.md), розділ 2.2).

Якщо згодом захочете злити гілку застосунку в `main`: `git merge lab7-observability` у `D:\uni\Java\cavalry` після того, як закомітите свої поточні зміни (можливі конфлікти в `pom.xml` і `application.yml`).

---

## 10. Відхилення від методички і чому

| Методичка | Тут | Чому |
|---|---|---|
| `minio: {enabled: false}` у Loki | прибрано | чарт `loki` 20.2.2 відхиляє його схемою: `additional properties 'minio' not allowed` (перевірено `helm template`) |
| власні `http_requests_total` / `http_request_duration_seconds` | `http_server_requests_seconds_*` | Spring Boot — методичка прямо дозволяє стандартні метрики Actuator |
| `level="error"` | `level="ERROR"` | формат logstash Spring Boot |
| `pause: {duration: 30s}` перед аналізом | `60s` | розділ 8.2 |
| селектор `namespace="myapp"` | + `service="cavalry-backend"`, `uri!~"/actuator.*"` | у namespace є інші сервіси; скрейпи розбавляють частку помилок |
| CPU/пам'ять `container!=""` | `container="backend"` | лише поди бекенду, без Keycloak/Postgres |
| Alloy: мітки namespace, pod, app | + `container`, `component` | `app` однаковий для всіх подів Cavalry |

---

## 11. Типові проблеми та їх рішення

| Симптом | Причина | Рішення |
|---|---|---|
| Поди в `monitoring` у `Pending` | бракує пам'яті | `kubectl -n monitoring describe pod <pod>` → `Insufficient memory`; перестворити minikube з 8 ГБ, у Docker Desktop ≥ 10 ГБ |
| `kps` `OutOfSync`/`SyncFailed`, помилка про розмір анотації | немає `ServerSideApply=true` | вже є в `kps.yaml`; `argocd app sync kps` |
| `cavalry` `SyncFailed`: `no matches for kind ServiceMonitor` | CRD ще немає | дочекатися `kps` Healthy; `retry` у `cavalry.yaml` повторить сам |
| Цілі `cavalry-backend` немає в Status → Targets | порт без імені / селектор не збігся | `kubectl -n cavalry get svc cavalry-backend -o yaml` → `name: http` і мітка `component: backend`; `kubectl -n cavalry get servicemonitor` |
| Ціль є, але `DOWN`, 401/302 | старий образ без `/actuator/prometheus` або без `permitAll` | тег `1.5.0`+: `kubectl -n cavalry get rollout cavalry-backend -o jsonpath='{..image}'` |
| `http_server_requests_seconds_bucket` порожньо | не ввімкнено `percentiles-histogram` | є в `application.yml` образу 1.5.0 |
| AnalysisRun одразу `Failed`/`Error`, значення `NaN` | немає трафіку (0/0) | `kubectl get deploy load`; `kubectl apply -f demo/load.yaml` |
| AnalysisRun `Error`: connection refused | неправильна адреса Prometheus | `kubectl -n monitoring get svc kps-prometheus` (порт 9090) |
| Хороший реліз раптом `Failed` | перший вимір до появи метрик нового пода | збільшити паузу (у нас 60 с); `kubectl -n cavalry describe analysisrun <name>` |
| Дашборду немає в Grafana | немає мітки / sidecar не шукає в усіх namespace / зламаний JSON | `kubectl -n cavalry get cm cavalry-dashboard --show-labels`; `kubectl -n monitoring logs deploy/kps-grafana -c grafana-sc-dashboard` |
| У Loki немає логів | Alloy не дістає до Loki | `kubectl -n monitoring logs deploy/alloy`; `kubectl -n monitoring get svc loki-gateway` |
| `\| json` дає `__error__="JSONParserErr"` | не-JSON рядки (старий образ / інший контейнер) | фільтр `component="backend"`, образ ≥ 1.5.0; додати `\| __error__=""` |
| Пароль Grafana не підходить | Secret створено після старту Grafana | `kubectl -n monitoring rollout restart deploy/kps-grafana` |

---

## 12. Теорія: відповіді на ймовірні питання

**Що таке observability і чим відрізняється від моніторингу?** Моніторинг відповідає на заздалегідь відомі питання («чи живий сервіс, чи перевищено поріг»). Observability — здатність за зовнішніми сигналами (метрики, логи, трейси) зрозуміти внутрішній стан системи і відповісти на **нові** питання, не змінюючи код.

**Три стовпи?** Метрики (агреговані числа в часі, дешеві, для алертів і трендів), логи (окремі події з деталями), трейси (шлях одного запиту через сервіси; у цій роботі не робили).

**Pull vs push.** Prometheus сам ходить по цілі (pull): він знає, хто має бути живим (ціль `DOWN` — це вже сигнал), застосунок не залежить від доступності Prometheus. Loki навпаки отримує логи push-ем від агента (Alloy).

**Що робить Prometheus Operator / ServiceMonitor?** Оператор стежить за CRD (`Prometheus`, `ServiceMonitor`, `PrometheusRule`, ...) і генерує з них конфіг Prometheus. ServiceMonitor — декларативне «скрейпи цей Service»: живе поруч із застосунком у його чарті, а не в центральному конфігу.

**Типи метрик.** Counter — лише зростає (кількість запитів), дивимось через `rate()`. Gauge — довільне значення (пам'ять, черга). Histogram — лічильники по кошиках `le` + `_sum` + `_count`; квантилі рахуються на сервері (`histogram_quantile`) і **агрегуються** між подами. Summary — квантилі рахує клієнт, між подами їх скласти не можна.

**`rate` vs `irate` vs `increase`.** `rate(x[1m])` — середня швидкість за вікно (стабільна, для алертів і графіків). `irate` — за двома останніми точками (різка). `increase(x[1h])` = `rate × тривалість`. Усі коректно обробляють скидання лічильника при рестарті пода.

**Чому `sum(rate())`, а не `rate(sum())`?** Спершу `rate` для кожного ряду (поди рестартують незалежно, скидання лічильника видно лише в окремому ряді), потім сума.

**Як рахується p95?** `histogram_quantile(0.95, sum by (le) (rate(..._bucket[1m])))`: бере розподіл за бакетами і лінійно інтерполює всередині бакета, куди потрапляє 95-й перцентиль. Точність залежить від меж бакетів.

**Кардинальність.** Кількість унікальних комбінацій міток = кількість часових рядів. Мітка з id/URL/email робить її необмеженою: пам'ять Prometheus росте, запити гальмують. Тому `uri` — шаблон маршруту, а id — лише в логах.

**Чому Loki дешевший за Elasticsearch?** Індексує лише мітки (namespace, pod, ...), а вміст рядків зберігає стиснутими чанками і проглядає під час запиту. Платимо швидкістю пошуку по тексту, виграємо в обсязі.

**Структуровані логи — навіщо?** Поля (`status`, `route`, `duration_ms`) можна фільтрувати й агрегувати (`| json | status >= 500`, `count_over_time`), а не шукати регулярками по тексту.

**RED і USE.** RED для сервісів: **R**ate (RPS), **E**rrors (частка 5xx), **D**uration (p95) — перші три панелі дашборда. USE для ресурсів: **U**tilization, **S**aturation, **E**rrors — CPU і пам'ять подів.

**Що таке SLI/SLO?** SLI — виміряний показник (частка успішних запитів). SLO — ціль для нього (≥ 95 %). Наш AnalysisTemplate — це перевірка SLO на canary перед тим, як пустити версію на всіх.

**Як працює AnalysisRun?** Rollout на кроці `analysis` створює AnalysisRun з шаблону. Той `count` разів з інтервалом `interval` виконує запит; кожен результат перевіряється `successCondition`. Більше `failureLimit` невдалих → `Failed` → Rollout abort. Якщо запит не вдався технічно (Prometheus недоступний) — `Error` (окремий ліміт `consecutiveErrorLimit`, за замовчуванням 4).

**Чому NaN = провал?** Без трафіку `0/0 = NaN`, `NaN >= 0.95` хибне. Відсутність даних — не доказ того, що версія хороша, тому краще провалити.

**Canary-аналіз по всьому сервісу чи лише по canary?** У нас — по всьому Service: простіше, але помилки canary «розбавлені» stable-подами (10 % замість 50 %). Точніше — фільтр `rollouts_pod_template_hash` з аргументом `valueFrom.podTemplateHashValue: Latest` (мітка вже є в метриках завдяки `podTargetLabels`).

**Blue-green з аналізом?** `prePromotionAnalysis` по preview-сервісу: до перемикання користувачі погану версію не бачать взагалі, але на preview треба подавати окремий трафік. Шаблон підтримує це зміною `selector`.

**Чому пароль Grafana не в Git і не з чарту?** Секрети не зберігаємо в Git. А чарт генерує випадковий пароль під час рендерингу, Argo CD рендерить на кожній синхронізації — пароль постійно змінювався б.

**Навіщо `ServerSideApply`?** Client-side apply кладе весь об'єкт в анотацію `last-applied-configuration` (ліміт 256 КБ); CRD Prometheus Operator більші. Server-side apply рахує злиття на сервері через `managedFields`, без анотації.

**Що таке sync-wave?** Порядок створення ресурсів Argo CD: менша хвиля — раніше. `-1` для операторів і CRD, `0` (за замовчуванням) для застосунку.
