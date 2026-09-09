# syntax=docker/dockerfile:1
FROM alpine:3.20

ARG KUBECTL_VERSION=v1.34.11
ARG TARGETARCH=amd64

RUN apk add --no-cache bash curl jq coreutils ca-certificates \
 && curl -fsSL -o /usr/local/bin/kubectl \
      "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl" \
 && chmod +x /usr/local/bin/kubectl \
 && kubectl version --client

WORKDIR /work
ENTRYPOINT ["bash"]
