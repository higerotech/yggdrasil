# Sleipnir — sonda de throughput por WAN. Base pineada por digest (cadena de suministro, A03);
# ver deploy/imagenes.md para actualizarla. Corre sin root, con el rootfs de solo lectura.
FROM alpine:3.22@sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce

# CLI oficial de Ookla (binario estatico musl) pineada por version y sha256: en midgard fue la unica
# medida que dio el ancho de banda real (939 Mbps) frente a speedtest-cli (76 Mbps, limitada por CPU y servidor).
ARG OOKLA_VERSION=1.2.0
ARG OOKLA_SHA256=5690596c54ff9bed63fa3732f818a05dbc2db19ad36ed68f21ca5f64d5cfeeb7

RUN apk upgrade --no-cache \
 && apk add --no-cache busybox-extras iperf3 iproute2 jq python3 py3-pip tzdata \
 && pip install --no-cache-dir --break-system-packages speedtest-cli==2.1.3 \
 && adduser -D -H -u 65532 -s /sbin/nologin sleipnir \
 && mkdir -p /var/lib/sleipnir/www && chown -R 65532:65532 /var/lib/sleipnir

RUN wget -qO /tmp/ookla.tgz "https://install.speedtest.net/app/cli/ookla-speedtest-${OOKLA_VERSION}-linux-x86_64.tgz" \
 && echo "${OOKLA_SHA256}  /tmp/ookla.tgz" | sha256sum -c - \
 && tar -xzf /tmp/ookla.tgz --no-same-owner -C /usr/local/bin speedtest \
 && rm -f /tmp/ookla.tgz && chmod 0755 /usr/local/bin/speedtest

COPY --chmod=0755 sleipnir.sh /usr/local/bin/sleipnir.sh

USER 65532:65532
ENV HOME=/tmp
EXPOSE 9469
HEALTHCHECK --interval=5m --timeout=10s --start-period=1m \
  CMD wget -qO- "http://${SLEIPNIR_LISTEN:-172.17.0.1:9469}/metrics" >/dev/null || exit 1
ENTRYPOINT ["/usr/local/bin/sleipnir.sh"]
