# Why not to use `:latest` as an image tag

This project currently deploys `nista24/kubernetes-rails-example:latest` with `imagePullPolicy: Always`. That's fine for learning locally on minikube, but it causes problems in shared environments.

The root problem is that **`:latest` is a mutable tag**: the same name can point to different images over time. So nothing in the manifests says which code is actually running.

## 1. Pods change version without anyone deploying

Pods restart for many reasons besides a deploy:

- a crash
- a node being drained
- eviction under memory pressure
- autoscaling adding pods

With `:latest` and `Always`, each of those pulls whatever `:latest` is at that moment. If someone pushed an unfinished build an hour ago, it goes live the next time any pod restarts.

## 2. Different pods run different code

Following from #1, after a few restarts some pods run the old code and some run the new. Requests are spread across pods, so users get different behavior depending on which pod they reach, and bugs become hard to reproduce.

With `IfNotPresent` it's similar: each node keeps whichever `:latest` it pulled first.

## 3. Migrations and schema drift

This applies directly to this project. `bin/docker-entrypoint` runs migrations whenever the container starts the Rails server:

```bash
# If running the rails server then create or migrate existing database
if [ "${@: -2:1}" == "./bin/rails" ] && [ "${@: -1:1}" == "server" ]; then
  ./bin/rails db:prepare
fi
```

The Dockerfile's default command is `./bin/thrust ./bin/rails server`, so **every web pod runs `db:prepare` when it starts**.

With `:latest`, a pod that restarts and pulls a newer image migrates the database to the new schema while the other pods are still running old code against it. You also can't be sure a migration Job and the app ran the same version.

This isn't visible yet only because each pod has its own SQLite file. With a shared database like Postgres, it would matter.

**Usual fix:**

- Run migrations **once**, as a Kubernetes Job or init container, using the **same immutable tag** as the app.
- Keep schema changes backward compatible, so old and new code can both run during a rollout (for example, add a column in one release and remove the old one in a later release).

## 4. Rollback doesn't work

`kubectl rollout undo` restores the previous pod spec. If that spec also says `:latest`, "rolling back" pulls the same new image again.

To roll back, you'd have to re-tag an old image and push it as `:latest`, during an incident.

## 5. Kubernetes and tools can't see changes

- `kubectl apply` sees no difference in the manifest, so no rollout happens. You need `kubectl rollout restart`.
- GitOps tools like Argo CD and Flux can't tell from Git what's deployed.
- If the Git history says `:latest` throughout, it can't tell you what ran last Tuesday.

## 6. Debugging and auditing are harder

"Which version is in production?" can't be answered from `kubectl describe pod`. You'd have to compare image digests by hand. Linking an error to a commit, or reproducing a bug locally, becomes guesswork.

## 7. Security and supply chain risks

- **Anyone who can push can change production.** A bad or compromised image pushed as `:latest` gets deployed on the next pod restart, without review.
- **Scans don't stay valid.** If you scanned `:latest` yesterday, that result says nothing about what `:latest` is today.
- **Signature and admission checks** (such as cosign or Kyverno) are meant to verify a specific image, and that doesn't work with a moving tag.

## 8. Every pod start depends on the registry

`Always` with `:latest` means each pod start contacts Docker Hub. That:

- makes startup slower,
- uses up Docker Hub's pull rate limits for anonymous and free accounts,
- means a registry outage stops pods from starting, during exactly the scale-up or recovery when you need them.

## 9. Architecture overwrites

If you push `:latest` from an Apple Silicon Mac, it's an `arm64` image. That overwrites any `amd64` `:latest`, and cloud nodes, which are usually `amd64`, then fail with `exec format error`.

With distinct tags, or multi-platform builds, that can't happen by accident:

```sh
docker buildx build --platform linux/amd64,linux/arm64 \
  -t nista24/kubernetes-rails-example:v2 --push .
```

## 10. `:latest` in base images and dependencies

The same applies to `FROM` lines in Dockerfiles and to third-party images. With `redis:latest` or `ruby:latest`, a rebuild or pod restart could silently jump a major version.

This project already avoids it:

- `config/kube/redis.yml` uses `redis:7.4-alpine`
- the `Dockerfile` pins `ruby:4.0.7-slim` (via `ARG RUBY_VERSION=4.0.7`)

## What to use instead

| Approach | Example | Notes |
|---|---|---|
| Git commit SHA tag | `nista24/kubernetes-rails-example:a35b3d3` | Unique per build; links directly to the code. Most CI pipelines and Kamal do this by default |
| Version tag | `nista24/kubernetes-rails-example:v1.4.2` | Readable; never push the same version twice |
| Digest | `nista24/kubernetes-rails-example@sha256:...` | Identifies exactly one image and can't be changed. Even a version tag like `v2` can technically be overwritten |
| Immutable tags in the registry | ECR, GHCR rules, Harbor | The registry blocks overwriting an existing tag |

With unique tags, use `imagePullPolicy: IfNotPresent`: it's fast and consistent, with no extra pulls.

Example using the git SHA:

```sh
TAG=$(git rev-parse --short HEAD)
docker build -t nista24/kubernetes-rails-example:$TAG .
docker push nista24/kubernetes-rails-example:$TAG
kubectl set image deployment/kubernetes-rails-example-deployment rails-app=nista24/kubernetes-rails-example:$TAG
kubectl set image deployment/sidekiq sidekiq=nista24/kubernetes-rails-example:$TAG
```

To keep `config/kube/` in sync with what's running, update the `image:` tags in the manifests and run `kubectl apply -f config/kube` instead of `kubectl set image`.

## Summary

| Problem with `:latest` | Cause |
|---|---|
| Unplanned upgrades on pod restart | Tag points to a new image; `Always` pulls it |
| Mixed versions across pods | Pods pull at different times |
| Migrations run by the wrong version | Each web pod runs `db:prepare` on start |
| No rollback | Previous spec is also `:latest` |
| `apply` doesn't roll out | Manifest doesn't change |
| Can't tell what's running | Every pod says `:latest` |
| Unreviewed images reach production | Anyone who can push changes what runs |
| Slow starts, rate limits, outages | Pull on every pod start |
| `exec format error` on cloud nodes | `arm64` push overwrites `amd64` |
| Surprise major upgrades | Unpinned base and dependency images |

`:latest` is fine for learning locally on minikube. For anything shared, deploy a unique tag (git SHA or version) or a digest.

See [updating-the-deployment.md](updating-the-deployment.md#latest-vs-versioned-tags-v1-v2-) for the current deploy workflow and how `imagePullPolicy` works.
