FROM alpine:3.18.2

ENV LANG=C.UTF-8
ENV MIX_ENV=prod
ENV USER=jumpwire

# Creates an unprivileged user to be used exclusively to run the app
RUN \
    addgroup \
    -g 1000 \
    -S "${USER}" \
    && adduser \
    -s /bin/sh \
    -u 1000 \
    -G "${USER}" \
    -h "/opt/jumpwire" \
    -D "${USER}"

RUN apk add --update --no-cache bash curl jq sudo

WORKDIR /opt/jumpwire

COPY extract-release.sh /tmp/
COPY *.tar.gz /tmp/
RUN /tmp/extract-release.sh

EXPOSE 4369
EXPOSE 4004
EXPOSE 4443
EXPOSE 3306
EXPOSE 5432

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
CMD ["/usr/local/bin/entrypoint.sh"]
