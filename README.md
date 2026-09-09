# k8s-workload-identity-federation-lab

Lab PoC: a pod inside a Kubernetes cluster authenticates to a service **outside** the cluster
with a projected ServiceAccount token. The external service validates the JWT **offline** against
the cluster's JWKS (signature + `iss` + `aud` + `exp`) — the OIDC/JWKS flavour of workload
identity federation, not TokenReview.

Runs entirely on Docker + Compose. No `k3d`, `kubectl`, `jq` or `make` on the host.

> Full documentation follows once the end-to-end flow is verified.

## Quick start

```bash
cp .env.example .env
docker compose up -d --build      # k3s + external validator
docker compose run --rm demo      # live end-to-end verification
docker compose down -v            # tear everything down
```
