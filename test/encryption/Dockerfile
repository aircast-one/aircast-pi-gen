FROM debian:trixie
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      mmdebstrap ca-certificates debian-archive-keyring \
      e2fsprogs dosfstools mtools fdisk tang socat curl \
 && rm -rf /var/lib/apt/lists/*
