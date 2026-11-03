# cavalry-gitops

GitOps configuration for [Cavalry](https://github.com/Darmohrai/cavalry), the EV charging network.
The desired state of the cluster is described here, and Argo CD running in the cluster applies it.

```
cavalry-gitops/
├── bootstrap/
│   └── root.yaml              # root Application (App of Apps), applied by hand once
├── argocd-apps/               # Applications managed by root
│   ├── argo-rollouts.yaml     # Argo Rollouts controller + CRDs (Helm chart, sync-wave -1)
│   ├── kps.yaml               # Lab 7: kube-prometheus-stack (Prometheus, Alertmanager, Grafana), sync-wave -1
│   ├── loki.yaml              # Lab 7: Loki, single binary, filesystem storage, sync-wave -1
│   ├── alloy.yaml             # Lab 7: Grafana Alloy, pod logs -> Loki
│   └── cavalry.yaml
├── charts/
│   └── cavalry/               # Helm chart from Lab 4
│       ├── Chart.yaml
│       ├── values.yaml
│       ├── values-minikube.yaml   # values for the minikube cluster (no passwords, canary strategy)
│       ├── files/realm-export.json
│       ├── dashboards/cavalry.json  # Lab 7: Grafana dashboard, delivered as ConfigMap grafana_dashboard="1"
│       └── templates/             # backend-rollout.yaml replaces backend-deployment.yaml when
│                                  # backend.rollout.enabled is true; Lab 7: servicemonitor, dashboard,
│                                  # analysistemplate, prometheusrule
└── demo/
    ├── traffic.yaml           # request loop inside the cluster for the canary demo (applied by hand)
    └── load.yaml              # Lab 7: background load generator in namespace default (applied by hand)
```

## Images

Images are built by the `Release images` workflow of the application repository
when a tag `vX.Y.Z` is pushed:

- `ghcr.io/darmohrai/cavalry/cavalry-backend:X.Y.Z`
- `ghcr.io/darmohrai/cavalry/notification-service:X.Y.Z`

The version is baked into the image and returned by `GET /version`.

## Secrets

Passwords are not stored in Git. `values-minikube.yaml` sets `existingSecret: cavalry-secret`,
so the chart does not render its own Secret and all pods read credentials from a Secret
created by hand:

```powershell
kubectl create namespace cavalry
kubectl -n cavalry create secret generic cavalry-secret `
  --from-literal=POSTGRES_DB=ev_charge_db `
  --from-literal=POSTGRES_USER=root `
  --from-literal=POSTGRES_PASSWORD=<password> `
  --from-literal=KEYCLOAK_ADMIN=admin `
  --from-literal=KEYCLOAK_ADMIN_PASSWORD=<password>
```

Argo CD does not delete this Secret even with `prune: true`, because it was not created from Git.

The Grafana admin password (Lab 7) is a Secret created by hand as well:

```powershell
kubectl create namespace monitoring
kubectl -n monitoring create secret generic grafana-admin `
  --from-literal=admin-user=admin --from-literal=admin-password=<password>
```

## Bootstrap

```powershell
kubectl apply -f bootstrap/root.yaml
```

Everything else comes from Git. A new application or cluster component is added with
one more file in `argocd-apps/`.

## Progressive delivery (Lab 6)

The backend is a `Rollout` managed by [Argo Rollouts](https://argo-rollouts.readthedocs.io/) with a
canary strategy (5 replicas; Lab 6: 20% → manual pause → 60% → 30s → 80% → 30s → 100%,
Lab 7: 20% → 60s → analysis → 60% → 30s → 80% → 30s → 100%).
A release is still a commit that changes `backend.image.tag`; it is then promoted or aborted with
`kubectl argo rollouts promote|abort cavalry-backend -n cavalry` or from the Argo CD UI.

## Observability (Lab 7)

Prometheus scrapes `/actuator/prometheus` of every backend pod (ServiceMonitor in the chart), Alloy ships
the JSON logs of all pods to Loki, Grafana shows the dashboard **Cavalry backend** from Git. The canary
has an `analysis` step instead of the manual pause: the AnalysisTemplate `cavalry-success-rate` asks
Prometheus for the share of non-5xx responses and aborts the release below 95 %. A bad release is
simulated with `backend.extraEnv FAIL_RATE` (share of requests answered with 500).

```powershell
kubectl -n monitoring port-forward svc/kps-grafana 3000:80        # Grafana, admin / <password>
kubectl -n monitoring port-forward svc/kps-prometheus 9090:9090   # Prometheus
```

## Lab guides

- [LAB5.md](LAB5.md): GitOps with Argo CD, every command
- [LAB6.md](LAB6.md): canary releases with Argo Rollouts, every command
- [LAB7.md](LAB7.md): observability (metrics, logs, dashboard, rollback by metrics): what and why
- [LAB7-DEFENSE.md](LAB7-DEFENSE.md): Lab 7 live demo, step by step
