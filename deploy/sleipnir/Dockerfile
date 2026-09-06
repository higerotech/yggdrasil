# Sleipnir — sonda de throughput por WAN. Base pineada por digest (cadena de suministro, A03);
# ver deploy/imagenes.md para actualizarla. Corre sin root, con el rootfs de solo lectura.
FROM alpine:3.22@sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce

RUN apk upgrade --no-cache \
 && apk add --no-cache busybox-extras iperf3 iproute2 jq python3 py3-pip tzdata \
 && pip install --no-cache-dir --break-system-packages speedtest-cli==2.1.3 \
 && adduser -D -H -u 65532 -s /sbin/nologin sleipnir \
 && mkdir -p /var/lib/sleipnir/www && chown -R 65532:65532 /var/lib/sleipnir

COPY --chmod=0755 sleipnir.sh /usr/local/bin/sleipnir.sh

USER 65532:65532
ENV HOME=/tmp
EXPOSE 9469
HEALTHCHECK --interval=5m --timeout=10s --start-period=1m \
  CMD wget -qO- "http://${SLEIPNIR_LISTEN:-172.17.0.1:9469}/metrics" >/dev/null || exit 1
ENTRYPOINT ["/usr/local/bin/sleipnir.sh"]
