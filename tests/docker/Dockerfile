# syntax=docker/dockerfile:1.7
FROM ubuntu:22.04

ENV container=docker

RUN set -eux; \
  apt-get update; \
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    systemd \
    systemd-sysv \
    dbus \
    sudo \
    iproute2 \
    iputils-ping \
    curl \
    gnupg \
    jq \
    vim-tiny \
    less \
    tzdata \
    locales \
    uuid-runtime; \
  apt-get clean; \
  rm -rf /var/lib/apt/lists/*; \
  locale-gen en_US.UTF-8

ENV LANG=en_US.UTF-8 \
  LC_ALL=en_US.UTF-8 \
  DEBIAN_FRONTEND=noninteractive

RUN useradd --create-home --shell /bin/bash tester

VOLUME [ "/sys/fs/cgroup" ]
STOPSIGNAL SIGRTMIN+3
CMD ["/lib/systemd/systemd"]
