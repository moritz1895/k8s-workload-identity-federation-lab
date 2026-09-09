# k8s-workload-identity-federation-lab

A lab that shows **workload identity federation** end to end: a pod inside a Kubernetes
cluster gets a short-lived, audience-bound ServiceAccount token and authenticates with it to a
service **outside** the cluster. The external service validates the token **offline** — it
verifies the JWT signature against the issuer's published JWKS and checks `iss`, `aud` and
`exp`. It never calls back to the API server (`TokenReview`).

Everything runs in containers. The only thing you need on the host is **Docker + Compose v2**.

```bash
cp .env.example .env
docker compose up -d --build      # k3s + issuer endpoint + the external validator
docker compose run --rm demo      # live end-to-end verification
docker compose down -v            # remove everything
```

---

## What talks to what

```
        ┌──────────────────────────── Docker network "wifnet" (172.31.7.0/24) ─────────────────────────────┐
        │                                                                                                  │
        │  ┌───────────────────────┐      ┌────────────────────┐      ┌───────────────────────────────┐    │
        │  │  server (k3s)         │      │  issuer-web (nginx) │      │  validator (Spring Boot)       │    │
        │  │  mints tokens with    │      │  https://issuer-web │◄─────│  172.31.7.10:8080              │    │
        │  │  iss=https://issuer-  │      │  /.well-known/…     │ OIDC │  trusts only issuer-web's cert │    │
        │  │  web                  │      │  /openid/v1/jwks    │ disc.│  checks sig + iss + aud + exp  │    │
        │  │  ┌─────────────────┐  │      └────────▲───────────┘      └───────────────▲───────────────┘    │
        │  │  │ pod "consumer"  │  │               │ published once by                │                    │
        │  │  │ projected token │  │        bootstrap (kubectl get --raw)             │                    │
        │  │  │ aud=wif-demo-…  │──┼──── GET /whoami   Authorization: Bearer <token> ─┘                    │
        │  │  └─────────────────┘  │      (via hostAliases → 172.31.7.10)                                  │
        │  └───────────────────────┘                                                                       │
        └──────────────────────────────────────────────────────────────────────────────────────────────────┘

  bootstrap (one-shot) – applies manifests/, mints issuer-web's TLS cert, copies the cluster's
                         discovery document + JWKS into the volume issuer-web serves, then exits
  demo      (on demand) – docker compose run --rm demo
```

| Compose service | Image | Role |
|---|---|---|
| `server` | `rancher/k3s` | Single-node k3s. API server started with `service-account-issuer=https://issuer-web` and `service-account-jwks-uri=https://issuer-web/openid/v1/jwks`. |
| `bootstrap` | built from `tools/` | Waits for the API server; applies `manifests/`; mints a self-signed cert for `issuer-web`; copies `/.well-known/openid-configuration` and `/openid/v1/jwks` out of the cluster into the `oidc-web` volume; exits. Runs on every `up` (idempotent). |
| `issuer-web` | `nginx:alpine` | Serves the discovery document and JWKS over HTTPS at `https://issuer-web`. This is the URL in every token's `iss` claim. |
| `validator` | built from `validator/` | The out-of-cluster relying party. Pinned to `172.31.7.10` on `wifnet`. Talks **only** to `issuer-web`. |
| `demo` | built from `tools/` | The verification script. Behind a Compose profile — run it with `docker compose run --rm demo`. |

---

## The trust anchor

The token's `iss` is `https://issuer-web`, and that is also where the validator loads the JWKS
from — so the value has to resolve **from inside the validator container**. `issuer-web` is a
Docker-network name; the API server is configured to use it as the issuer
(`--kube-apiserver-arg=service-account-issuer=https://issuer-web`).

`issuer-web` serves HTTPS with a self-signed certificate that `bootstrap` mints at first `up`.
The validator is handed **only that one certificate** (a read-only mount of the `oidc-web`
volume, `/oidc/tls.crt`) and builds a dedicated `SSLSocketFactory` from it (`JwksTrustConfig`).
The JWKS fetch therefore succeeds over real TLS with hostname verification and fails for
anything not presenting that certificate. No `-k`, no JVM-wide truststore change. The validator
never connects to the Kubernetes API server at all.

The signing keys served at `https://issuer-web/openid/v1/jwks` are the k3s ServiceAccount
signing keys (RSA, `RS256`) — copied verbatim out of the cluster by `bootstrap`. Those keys are
the actual root of trust for token validation.

## The token flow

1. The `consumer` deployment mounts a `projected` volume with a `serviceAccountToken` source:
   `audience: wif-demo-validator`, `expirationSeconds: 600`. kubelet requests the token from the
   TokenRequest API and refreshes it before expiry. It lands in the pod at
   `/var/run/secrets/tokens/sa-token`.
2. The token is a JWT: `iss = https://issuer-web`, `aud = ["wif-demo-validator"]`,
   `sub = system:serviceaccount:wif-demo:consumer`, plus `exp`, `iat`, `nbf` and a
   `kubernetes.io` claim describing namespace / pod / serviceaccount.
3. The pod sends it as `Authorization: Bearer …` to `http://validator.wif.local:8080/whoami`.
   `validator.wif.local` is pinned to the validator's IP with `hostAliases` in the pod spec —
   CoreDNS knows nothing about a container outside the cluster.
4. The validator:
   - runs OIDC discovery — `GET https://issuer-web/.well-known/openid-configuration`, checks the
     `issuer` field, follows `jwks_uri` (`JwksTrustConfig`);
   - selects the verification key from the JWKS by `kid`, restricted to `RS256`/`ES256`;
   - verifies the signature;
   - requires `iss` to equal `https://issuer-web` exactly;
   - requires `aud` to contain `wif-demo-validator` exactly;
   - checks `exp` / `nbf` (60 s clock-skew tolerance).
5. Valid → `200` with the claims. Anything else → `401` with a short reason.

---

## Verifying it yourself

`docker compose run --rm demo` runs, in one pass:

| Step | Expectation |
|---|---|
| `GET https://issuer-web/.well-known/openid-configuration` and its JWKS | `issuer` = `https://issuer-web`, one `RS256` key |
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

1. **Who owns the issuer endpoint.** Here `bootstrap` copies the cluster's discovery document
   and JWKS into a plain nginx once at startup. In production that endpoint is published at a
   stable public HTTPS URL (object storage, a CDN, a gateway) and kept in sync with the cluster
   signing keys by automation — key rotation has to propagate before old keys are dropped.
2. **The issuer's certificate.** `issuer-web` uses a self-signed cert the validator is handed
   directly. A real relying party trusts a public CA (or an explicitly pinned bundle) and never
   receives lab-specific trust material out of band.
3. **Network reachability.** `issuer-web` is a name on a shared Docker network. Really it is a
   public URL the relying party reaches over the internet.
4. **No revocation.** Offline validation cannot retract a token before `exp`. If you need
   immediate revocation you keep TTLs short and accept the window, maintain a `jti` denylist, or
   validate online via `TokenReview` — which can refuse a token whose pod or ServiceAccount is
   gone, at the cost of a round trip and a hard dependency on API server availability. This lab
   is deliberately the offline half of that trade-off.
5. **TTL and clock skew.** 600 s here is the API server minimum. Pick the token TTL, the JWKS
   cache lifetime (`JWKS_CACHE_TTL_MS`, 5 min here) and the accepted clock skew deliberately.
6. **`privileged` k3s** is a lab convenience for running the cluster in a container.

---

## Layout

```
compose.yaml                     all services + the wifnet network
manifests/
  00-namespace.yaml
  20-consumer.yaml               ServiceAccount + Deployment with the projected token volume
validator/                       Spring Boot 4 / Java 25, Nimbus JOSE
  src/main/java/ms/rohde/wifpoc/
    TokenValidator.java          the offline check
    JwksTrustConfig.java         cert-pinned SSLSocketFactory + OIDC discovery + JWKSource
    TokenController.java         GET /whoami, GET /healthz
  src/test/java/…/TokenValidatorTest.java   valid / wrong-aud / expired / wrong-iss / bad-sig
tools/
  bootstrap.sh                   apply manifests, mint issuer cert, publish discovery + JWKS
  nginx-issuer.conf              issuer-web server config
  demo.sh                        end-to-end verification
```

`CLAUDE.md` records where this PoC intentionally skips the wider project standards (hexagonal
layering, the arch-annotation library) and what still applies.
