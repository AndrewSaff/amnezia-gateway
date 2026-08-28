# syntax=docker/dockerfile:1.7

ARG GOLANG_IMAGE=golang:1.25.12-alpine3.22
ARG ALPINE_IMAGE=alpine:3.22.4@sha256:310c62b5e7ca5b08167e4384c68db0fd2905dd9c7493756d356e893909057601
# Pinned upstream refs (commit hashes for reproducible builds)
# amneziawg-go AWG 3.1 + RandomTrailers HandshakeCookie fix (2026-08-13)
ARG AWG_GO_REF=1b86b2ae0e493e7ea93f8c1a0f0cb6735b1551f1
# amneziawg-tools v3.1.20260812
ARG AWG_TOOLS_REF=ee0f0a9aa34ff0a0da4b3433b9512781cfe02843
# 3proxy 0.9.6
ARG PROXY3_REF=a2641cb103438b8caa5fcc551f085bcb5f244d47

FROM ${GOLANG_IMAGE} AS awg-go-builder
RUN apk add --no-cache git ca-certificates
WORKDIR /src/amneziawg-go
RUN git init . && git remote add origin https://github.com/amnezia-vpn/amneziawg-go.git \
    && git fetch --depth 1 origin "${AWG_GO_REF}" && git checkout --detach FETCH_HEAD
RUN CGO_ENABLED=0 go build -buildvcs=false -trimpath -ldflags="-s -w -buildid=" -o /out/amneziawg-go .

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
      org.opencontainers.image.source="https://github.com/AndrewSaff/amnezia-gateway" \
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

# awg-quick is a bash script upstream. Keep the src_valid_mark guard so
# containers with the sysctl preconfigured do not try to rewrite it.
RUN sed -i '1s|#!/bin/sh|#!/usr/bin/bash|' /usr/bin/awg-quick && \
    sed -i 's|\[\[ \$proto == -4 \]\] && cmd sysctl -q net.ipv4.conf.all.src_valid_mark=1|[[ $proto == -4 ]] \&\& [[ $(sysctl -n net.ipv4.conf.all.src_valid_mark) != 1 ]] \&\& cmd sysctl -q net.ipv4.conf.all.src_valid_mark=1|' /usr/bin/awg-quick

STOPSIGNAL SIGTERM
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 CMD ["/bin/sh", "/opt/amnezia/scripts/healthcheck.sh"]
ENTRYPOINT ["/sbin/tini", "--", "/opt/amnezia/scripts/start.sh"]
