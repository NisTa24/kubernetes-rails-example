# Troubleshooting: Missing `secret_key_base` when running the Docker image

## Issue

After building and running the image:

```sh
docker build -t nista24/kubernetes-rails-example:latest .
docker run -p 3000:3000 nista24/kubernetes-rails-example:latest
```

the container exits with:

```
bin/rails aborted!
ArgumentError: Missing `secret_key_base` for 'production' environment, set this string with `bin/rails credentials:edit` (ArgumentError)
/rails/config/environment.rb:5:in '<main>'
Tasks: TOP => db:prepare => db:load_config => environment
```

## Cause

- The image runs Rails in **production** mode (`RAILS_ENV="production"` in the `Dockerfile`), and production needs a `secret_key_base`.
- Rails reads `secret_key_base` from `config/credentials.yml.enc`, which is encrypted with `config/master.key`.
- `.dockerignore` keeps `config/master.key` out of the image. That's correct, because the key is a secret, but it means the container can't decrypt the credentials.

## Solution

Pass the master key in as an environment variable when you start the container:

```sh
docker run -p 3000:80 \
  -e RAILS_MASTER_KEY=$(cat config/master.key) \
  nista24/kubernetes-rails-example:latest
```

Then open http://localhost:3000.

### Port mapping

The `Dockerfile` starts the app through Thruster on **port 80** (`EXPOSE 80`), so map host port 3000 to container port 80 (`-p 3000:80`). The original `-p 3000:3000` doesn't reach the app.

## Kubernetes

Don't put the master key in the image or in a manifest. Store it in a Secret:

```sh
kubectl create secret generic rails-secrets \
  --from-file=RAILS_MASTER_KEY=config/master.key
```

Then expose it to the container as an environment variable:

```yaml
env:
  - name: RAILS_MASTER_KEY
    valueFrom:
      secretKeyRef:
        name: rails-secrets
        key: RAILS_MASTER_KEY
```

The container listens on port 80, so set `containerPort: 80` in the Deployment and point the Service's `targetPort` at it.

## Note on the database

The app uses **SQLite**. In Kubernetes, each pod gets its own database file inside the container. That data is lost whenever a pod restarts, and replicas won't share it. For anything beyond a demo, use a PersistentVolume or a separate database such as Postgres.
