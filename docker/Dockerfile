ARG BASE_IMAGE=ubuntu:22.04
FROM ${BASE_IMAGE}

ARG BUILD_UID=1000
ARG BUILD_GID=1000

LABEL org.opencontainers.image.title="EPCB RK3308 Buildroot builder" \
      org.opencontainers.image.version="lab2-v1"

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      bc binutils bison build-essential bzip2 ca-certificates cmake cpio \
      file flex gawk git libncurses-dev libssl-dev patch perl pkg-config \
      python3 python3-dev python3-setuptools python-is-python3 \
      ripgrep rsync tar unzip util-linux wget xz-utils zlib1g-dev \
 && rm -rf /var/lib/apt/lists/*

RUN test "${BUILD_UID}" -gt 0 \
 && (getent group "${BUILD_GID}" >/dev/null || groupadd --gid "${BUILD_GID}" builder) \
 && useradd --uid "${BUILD_UID}" --gid "${BUILD_GID}" \
      --create-home --shell /bin/bash builder

ENV LANG=C.UTF-8 LC_ALL=C.UTF-8 TZ=Etc/UTC
WORKDIR /work
USER builder
CMD ["/bin/bash"]
