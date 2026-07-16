# syntax=docker/dockerfile:1.7

ARG GOLANG_IMAGE=golang:1.24.4-alpine3.22@sha256:68932fa6d4d4059845c8f40ad7e654e626f3ebd3706eef7846f319293ab5cb7a
ARG ALPINE_IMAGE=alpine:3.22.4@sha256:310c62b5e7ca5b08167e4384c68db0fd2905dd9c7493756d356e893909057601
# Pinned upstream refs (commit hashes for reproducible builds)
# amneziawg-go v0.2.19
ARG AWG_GO_REF=1cc94272ca8e9e223a5fe76382f5880f09d3c12d
# amneziawg-tools v1.0.20260618-2
ARG AWG_TOOLS_REF=61e741780e8465a67a7d7fb6cffe14a8a15d624a
# 3proxy 0.9.6
ARG PROXY3_REF=a2641cb103438b8caa5fcc551f085bcb5f244d47

FROM ${GOLANG_IMAGE} AS awg-go-builder
RUN apk add --no-cache git ca-certificates
WORKDIR /src/amneziawg-go
RUN git init . && git remote add origin https://github.com/amnezia-vpn/amneziawg-go.git \
    && git fetch --depth 1 origin "${AWG_GO_REF}" && git checkout --detach FETCH_HEAD
RUN --mount=type=cache,target=/go/pkg/mod --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 go build -buildvcs=false -trimpath -ldflags="-s -w -buildid=" -o /out/amneziawg-go .

FROM ${GOLANG_IMAGE} AS awg-tools-builder
RUN apk add --no-cache git make bash build-base linux-headers ca-certificates
WORKDIR /src/amneziawg-tools
RUN git init . && git remote add origin https://github.com/amnezia-vpn/amneziawg-tools.git \
    && git fetch --depth 1 origin "${AWG_TOOLS_REF}" && git checkout --detach FETCH_HEAD
RUN make -C src -j"$(nproc)"

FROM ${ALPINE_IMAGE} AS proxy-builder
RUN apk add --no-cache git make gcc musl-dev openssl-dev linux-headers ca-certificates
WORKDIR /src/3proxy
RUN git init . && git remote add origin https://github.com/z3apa3a/3proxy.git \
    && git fetch --depth 1 origin "${PROXY3_REF}" && git checkout --detach FETCH_HEAD
RUN ln -s Makefile.Linux Makefile && make -j"$(nproc)"

FROM ${ALPINE_IMAGE} AS runtime
ARG TARGETPLATFORM
ARG TARGETARCH
LABEL org.opencontainers.image.title="amnezia-gateway" \
      org.opencontainers.image.description="AmneziaWG + 3proxy gateway container" \
      org.opencontainers.image.source="local" \
      org.opencontainers.image.vendor="self-hosted"

# Minimal runtime dependencies for awg/iptables/healthcheck
RUN apk add --no-cache \
    bash \
    ca-certificates \
    ip6tables \
    iproute2 \
    iptables \
    iputils \
    openresolv \
    openssl \
    tini \
    wireguard-tools-wg-quick

COPY --from=awg-go-builder /out/amneziawg-go /usr/bin/amneziawg-go
COPY --from=awg-tools-builder /src/amneziawg-tools/src/wg /usr/bin/awg
COPY --from=awg-tools-builder /src/amneziawg-tools/src/wg-quick/linux.bash /usr/bin/awg-quick
COPY --from=proxy-builder /src/3proxy/bin/3proxy /usr/bin/3proxy
COPY --chmod=0755 docker/scripts/ /opt/amnezia/scripts/
COPY docker/3proxy/3proxy.cfg /etc/3proxy/3proxy.cfg

# Fix shebang to bash and apply sysctl patch
RUN sed -i '1s|#!/bin/sh|#!/usr/bin/bash|' /usr/bin/awg-quick && \
    sed -i 's|\[\[ \$proto == -4 \]\] && cmd sysctl -q net.ipv4.conf.all.src_valid_mark=1|[[ $proto == -4 ]] \&\& [[ $(sysctl -n net.ipv4.conf.all.src_valid_mark) != 1 ]] \&\& cmd sysctl -q net.ipv4.conf.all.src_valid_mark=1|' /usr/bin/awg-quick

STOPSIGNAL SIGTERM
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 CMD ["/bin/sh", "/opt/amnezia/scripts/healthcheck.sh"]
ENTRYPOINT ["/sbin/tini", "--", "/opt/amnezia/scripts/start.sh"]
