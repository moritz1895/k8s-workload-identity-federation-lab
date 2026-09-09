# k8s-workload-identity-federation-lab

A lab that shows **workload identity federation** end to end: a pod inside a Kubernetes
cluster gets a short-lived, audience-bound ServiceAccount token and authenticates with it to a
service **outside** the cluster. The external service validates the token **offline** — it
verifies the JWT signature against the cluster's published JWKS and checks `iss`, `aud` and
`exp`. No call back to the API server (`TokenReview`) is involved.

Everything runs in containers. The only thing you need on the host is **Docker + Compose v2**.

```bash
cp .env.example .env
docker compose up -d --build      # k3s + the external validator
docker compose run --rm demo      # live end-to-end verification
docker compose down -v            # remove everything
```

---

## What talks to what

```
          ┌─────────────────────────── Docker network "wifnet" (172.31.7.0/24) ───────────────────────────┐
          │                                                                                               │
          │   ┌───────────────────────┐                             ┌──────────────────────────────────┐  │
          │   │  server (k3s)         │   iss = https://k3s-server:6443   validator  (Spring Boot)      │  │
          │   │  k3s-server:6443      │◄────── GET /openid/v1/jwks ──│  172.31.7.10:8080                │  │
          │   │                       │        (anonymous, TLS)      │  trusts only cluster server-ca   │  │
          │   │  ┌─────────────────┐  │                             │  checks sig + iss + aud + exp     │  │
          │   │  │ pod "consumer"  │  │                             └──────────────────────────────────┘  │
          │   │  │ projected token │──┼──── GET /whoami  Authorization: Bearer <token> ──►  ▲              │
          │   │  │ aud=wif-demo-…  │  │     (via hostAliases → 172.31.7.10)                 │              │
          │   │  └─────────────────┘  │                                                                   │
          │   └───────────────────────┘                                                                   │
          └───────────────────────────────────────────────────────────────────────────────────────────────┘

  bootstrap (one-shot)  – applies manifests/ into the cluster, then exits
  demo      (on demand) – docker compose run --rm demo
```

| Compose service | Image | Role |
|---|---|---|
| `server` | `rancher/k3s` | Single-node k3s. API server started with `service-account-issuer=https://k3s-server:6443` and `anonymous-auth=true`. |
| `bootstrap` | built from `tools/` | Waits for the API server, applies `manifests/`, waits for the `consumer` rollout, exits. Runs on every `up`; the applies are idempotent. |
| `validator` | built from `validator/` | The out-of-cluster relying party. Pinned to `172.31.7.10` on `wifnet`. |
| `demo` | built from `tools/` | The verification script. Not started by `up` (it is behind a Compose profile); run it with `docker compose run --rm demo`. |

---

## The trust anchor

k3s generates a CA (`server-ca.crt`) that signs the API server's serving certificate. The
validator is handed **only that one CA** — nothing else — through a read-only mount of the k3s
data volume (`/k3s/server/tls/server-ca.crt`). It builds a dedicated `SSLSocketFactory` from it
(`JwksTrustConfig`), so the JWKS fetch succeeds over real TLS with hostname verification and
fails for anything not signed by that CA. No `-k`, no JVM-wide truststore change.

The signing keys themselves live at `https://k3s-server:6443/openid/v1/jwks`. Those are the k3s
ServiceAccount signing keys (RSA, `RS256`). That endpoint is the actual root of trust for token
validation.

## The token flow

1. The `consumer` deployment mounts a `projected` volume with a `serviceAccountToken` source:
   `audience: wif-demo-validator`, `expirationSeconds: 600`. kubelet requests the token from the
   TokenRequest API and refreshes it before expiry. It lands in the pod at
   `/var/run/secrets/tokens/sa-token`.
2. The token is a JWT: `iss = https://k3s-server:6443`, `aud = ["wif-demo-validator"]`,
   `sub = system:serviceaccount:wif-demo:consumer`, plus `exp`, `iat`, `nbf` and a
   `kubernetes.io` claim describing namespace / pod / serviceaccount.
3. The pod sends it as `Authorization: Bearer …` to `http://validator.wif.local:8080/whoami`.
   `validator.wif.local` is pinned to the validator's IP with `hostAliases` in the pod spec —
   CoreDNS knows nothing about a container outside the cluster.
4. `TokenValidator` (an explicit Nimbus `DefaultJWTProcessor`):
   - selects the verification key from the JWKS by `kid`, restricted to `RS256`/`ES256`;
   - verifies the signature;
   - requires `iss` to equal `https://k3s-server:6443` exactly;
   - requires `aud` to contain `wif-demo-validator` exactly;
   - checks `exp` / `nbf` (60 s clock-skew tolerance).
5. Valid → `200` with the claims. Anything else → `401` with a short reason.

### Why the `iss` value matters

`iss` is not just a label — it is the URL the validator loads the JWKS from
(`${iss}/openid/v1/jwks`). It therefore has to resolve **from inside the validator container**.
That is the whole reason the API server is told its issuer is `https://k3s-server:6443`
(`--kube-apiserver-arg=service-account-issuer=…`) and `k3s-server` is added to the serving
certificate SAN (`--tls-san=k3s-server`): `k3s-server` is a Docker-network name the validator
can reach, and the TLS name checks out.

### Anonymous discovery

The validator reads `/openid/v1/jwks` without a credential. That requires two things:
`anonymous-auth=true` on the API server (k3s ships with it **off**), and an RBAC binding of the
built-in `system:service-account-issuer-discovery` ClusterRole to `system:unauthenticated`
(`manifests/10-rbac-anonymous-oidc.yaml`).

---

## Verifying it yourself

`docker compose run --rm demo` runs, in one pass:

| Step | Expectation |
|---|---|
| Print the OIDC discovery document and JWKS the cluster advertises | `issuer` = `https://k3s-server:6443`, one `RS256` key |
| Mint an `aud=wif-demo-validator` token and decode it | claims as described above |
| `kubectl exec` into the pod, `curl` the validator with the **projected** token | **HTTP 200** + claims |
| Send a token minted for a different audience | **HTTP 401** — `JWT aud claim rejected` |
| Flip the last character of a valid token | **HTTP 401** — `Signed JWT rejected: Invalid signature` |

Genuine expiry needs a real wait: the TokenRequest API refuses to issue a token with a TTL
below **10 minutes**. Run `DEMO_EXPIRY=1 docker compose run --rm demo` to append a step that
mints a 10-minute token and polls `/whoami` until it flips from `200` to `401`.

Poke the validator directly from the host: `curl -s localhost:18080/healthz`
(port configurable via `VALIDATOR_HOST_PORT`).

---

## What you would do differently outside a lab

1. **Where discovery/JWKS is hosted.** Here it is the API server itself, reached over a Docker
   network name, served anonymously. In production the OIDC discovery document and JWKS are
   usually published at a stable, public HTTPS URL (an object-storage bucket or a gateway) that
   is decoupled from the API server's lifetime and certificate, and the relying party does
   real OIDC discovery (`/.well-known/openid-configuration` → `jwks_uri`) instead of hard-coding
   the JWKS path. The CA would be a public one or an explicitly pinned bundle, not a volume
   mount.
2. **No revocation.** Offline validation cannot retract a token before `exp`. If you need
   immediate revocation you either keep TTLs short and accept the window, maintain a `jti`
   denylist, or validate online via `TokenReview` (the API server can then refuse a token whose
   pod or ServiceAccount is gone — at the cost of a round trip and a hard dependency on API
   server availability). This lab is deliberately the offline half of that trade-off.
3. **TTL and clock skew.** 600 s here is the API server minimum. Pick the token TTL, the JWKS
   cache lifetime (`JWKS_CACHE_TTL_MS`, 5 min here) and the accepted clock skew deliberately for
   your environment.
4. **Cluster hardening.** `privileged: true` on the k3s container and anonymous read access to
   discovery are lab conveniences. The `iss`/JWKS endpoints are commonly public anyway, but the
   cluster around them still needs the usual hardening.

---

## Layout

```
compose.yaml                     all four services + the wifnet network
manifests/
  00-namespace.yaml
  10-rbac-anonymous-oidc.yaml     anonymous access to the discovery endpoints
  20-consumer.yaml               ServiceAccount + Deployment with the projected token volume
validator/                       Spring Boot 4 / Java 25, Nimbus JOSE
  src/main/java/ms/rohde/wifpoc/
    TokenValidator.java          the offline check
    JwksTrustConfig.java         CA-pinned SSLSocketFactory + JWKSource
    TokenController.java         GET /whoami, GET /healthz
  src/test/java/…/TokenValidatorTest.java   valid / wrong-aud / expired / wrong-iss / bad-sig
tools/
  bootstrap.sh                   apply manifests
  demo.sh                        end-to-end verification
```

`CLAUDE.md` records where this PoC intentionally skips the wider project standards (hexagonal
layering, the arch-annotation library) and what still applies.
