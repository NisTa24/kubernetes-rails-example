# Updating the deployment (ConfigMaps, Secrets and new images)

How to roll out changes to `config/kube/`, and what restarts automatically.

## Apply changes

Apply the whole folder. Kubernetes only changes what differs from what's already running:

```sh
kubectl diff -f config/kube                 # optional: preview the changes
kubectl apply -f config/kube
kubectl rollout status deployment kubernetes-rails-example-deployment
```

To check a change without applying it, use a server dry run. It catches invalid fields that a plain `apply` would reject:

```sh
kubectl apply -f config/kube --dry-run=server
```

## Do pods restart automatically?

| What changed | Pods restart automatically? | What to run |
|---|---|---|
| Deployment file (e.g. adding `envFrom`) | Yes, new pods roll out | `kubectl apply -f config/kube` |
| **Only the ConfigMap values** | **No.** Pods read env vars only when they start | `apply`, then `kubectl rollout restart deployment kubernetes-rails-example-deployment` |
| Secret values | No | Same as the ConfigMap row |
| New app code / image | No, see [Deploying new code](#deploying-new-code) | Rebuild, push, then roll out |

## Using a ConfigMap for environment variables

`config/kube/env.yml` defines a ConfigMap named `env`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: env
data:
  RAILS_ENV: production
  RAILS_LOG_TO_STDOUT: enabled
  RAILS_SERVE_STATIC_FILES: enabled
```

`config/kube/deployment.yml` loads every key in it as an environment variable with `envFrom`:

```yaml
containers:
- name: rails-app
  image: nista24/kubernetes-rails-example:latest
  envFrom:
    - configMapRef:
        name: env        # must be indented under configMapRef
```

### Pitfall: indentation of `name`

If `name: env` is at the same indentation as `configMapRef`, Kubernetes reads it as a separate field, and the Deployment is rejected:

```
strict decoding error: unknown field "spec.template.spec.containers[0].envFrom[0].name"
```

`name` must be indented further than `configMapRef`, as shown above.

### Pitfall: `DATABASE_URL` / `REDIS_URL`

The app uses **SQLite** and only has the `sqlite3` gem. If you set `DATABASE_URL` to a `postgresql://...` URL, Rails tries to load the Postgres adapter on boot and every pod crashes (`CrashLoopBackOff`). Keep these commented out until you've:

1. added the `pg` gem and rebuilt the image,
2. deployed Postgres (and Redis, for `REDIS_URL`) to the cluster.

```yaml
  # DATABASE_URL: postgresql://example.com/mydb
  # REDIS_URL: redis://redis.default.svc.cluster.local:6379/
```

### ConfigMap vs Secret

Use a ConfigMap for plain settings. Values like `RAILS_MASTER_KEY` or database passwords belong in a Secret (e.g. `rails-secrets`), referenced with `secretKeyRef` or `secretRef`.

## Deploying new code

The Deployment uses `imagePullPolicy: IfNotPresent`. **Once minikube has a copy of `:latest`, it won't pull your newer push**, so `rollout restart` would start the old code again.

Use a new tag for each build instead:

```sh
docker build -t nista24/kubernetes-rails-example:v2 .
docker push nista24/kubernetes-rails-example:v2
kubectl set image deployment/kubernetes-rails-example-deployment \
  rails-app=nista24/kubernetes-rails-example:v2
kubectl rollout status deployment kubernetes-rails-example-deployment
```

If you prefer, update the `image:` tag in `config/kube/deployment.yml` and run `kubectl apply -f config/kube` instead. That keeps the file in sync with what's running. Either way, Kubernetes rolls out the new pods.

Alternatives:

- **Keep using `:latest`:** set `imagePullPolicy: Always`, then run `kubectl rollout restart deployment kubernetes-rails-example-deployment` after each push.
- **Skip Docker Hub:** build, then `minikube image load nista24/kubernetes-rails-example:v2`, and use that tag in the Deployment.

## Rolling back

If a rollout goes wrong:

```sh
kubectl rollout undo deployment kubernetes-rails-example-deployment
```

## Checking the result

```sh
kubectl get pods                          # all pods should be 1/1 Running
kubectl exec deploy/kubernetes-rails-example-deployment -- env | sort   # check env vars inside a pod
kubectl logs deploy/kubernetes-rails-example-deployment
```

If pods fail, see the troubleshooting section in [local-kubernetes-with-minikube.md](local-kubernetes-with-minikube.md#7-troubleshooting-pods).
