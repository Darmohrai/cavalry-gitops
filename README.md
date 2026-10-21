# cavalry-gitops

GitOps configuration for [Cavalry](https://github.com/Darmohrai/cavalry), the EV charging network.
The desired state of the cluster is described here, and Argo CD running in the cluster applies it.

```
cavalry-gitops/
├── bootstrap/
│   └── root.yaml              # root Application (App of Apps), applied by hand once
├── argocd-apps/               # Applications managed by root
│   └── cavalry.yaml
└── charts/
    └── cavalry/               # Helm chart from Lab 4
        ├── Chart.yaml
        ├── values.yaml
        ├── values-minikube.yaml   # values for the minikube cluster (no passwords)
        ├── files/realm-export.json
        └── templates/
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

## Bootstrap

```powershell
kubectl apply -f bootstrap/root.yaml
```

Everything else comes from Git. A new application or cluster component is added with
one more file in `argocd-apps/`.

Step-by-step lab guide with every command: [LAB5.md](LAB5.md).
