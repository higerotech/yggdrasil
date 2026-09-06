# yggdrasil-sync — tarea de un solo uso que corre en cada despliegue del receptor de
# despliegue-continuo (ADR-0005): hace checkout del commit exacto que se despliega (IMAGE_TAG),
# renderiza las plantillas y recarga los servicios. Misma base pineada que Sleipnir.
FROM alpine:3.22@sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce

RUN apk upgrade --no-cache \
 && apk add --no-cache bash git gettext iproute2 curl ca-certificates

COPY --chmod=0755 sync.sh /usr/local/bin/sync.sh

ENV HOME=/tmp
ENTRYPOINT ["/usr/local/bin/sync.sh"]
CMD ["host"]
