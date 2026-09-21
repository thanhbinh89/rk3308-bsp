ARG BASE_IMAGE=ubuntu:22.04
FROM ${BASE_IMAGE}
ARG BUILD_UID=1000
ARG BUILD_GID=1000
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    bc bison build-essential ca-certificates device-tree-compiler file flex git \
    gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu libgnutls28-dev libssl-dev \
    libncurses-dev libpython3-dev openssl patch pkg-config python3 \
    python3-pyelftools python3-setuptools python3-yaml python3-jsonschema \
    swig uuid-dev xxd \
    && dpkg-query -W > /opt/uboot-builder-packages.txt \
    && rm -rf /var/lib/apt/lists/*
RUN test "${BUILD_UID}" -gt 0 && test "${BUILD_GID}" -gt 0 \
    && groupadd --gid "${BUILD_GID}" builder \
    && useradd --uid "${BUILD_UID}" --gid "${BUILD_GID}" --create-home builder
ENV LANG=C.UTF-8 LC_ALL=C.UTF-8 TZ=Etc/UTC
WORKDIR /work
USER builder
CMD ["/bin/bash"]
