FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC

RUN apt-get update && apt-get install -y \
    adb \
    autoconf \
    automake \
    bc \
    bison \
    build-essential \
    ccache \
    ca-certificates \
    curl \
    flex \
    g++-multilib \
    gcc-multilib \
    git \
    git-lfs \
    gnupg \
    gperf \
    imagemagick \
    jq \
    libelf-dev \
    libgl1-mesa-dev \
    liblz4-tool \
    libncurses5 \
    libncurses5-dev \
    libsdl1.2-dev \
    libssl-dev \
    libxml2 \
    libxml2-utils \
    lzop \
    openjdk-17-jdk \
    openjdk-21-jdk \
    patch \
    pngcrush \
    python3 \
    python3-pip \
    repo \
    rsync \
    schedtool \
    squashfs-tools \
    unzip \
    wget \
    xsltproc \
    zip \
    zlib1g-dev \
 && rm -rf /var/lib/apt/lists/*

RUN useradd -m -s /bin/bash builder \
 && mkdir -p /home/builder/bin /home/builder/build /home/builder/patches /workspace /ccache \
 && chown -R builder:builder /home/builder /workspace /ccache

COPY build /home/builder/build
COPY patches /home/builder/patches

RUN chown -R builder:builder /home/builder/build /home/builder/patches \
 && chmod +x /home/builder/build/*.sh

USER builder
WORKDIR /home/builder

ARG GIT_USER_NAME="Lineage Builder"
ARG GIT_USER_EMAIL="builder@localhost"

RUN git config --global user.name "${GIT_USER_NAME}" \
 && git config --global user.email "${GIT_USER_EMAIL}"

ENV USE_CCACHE=1
ENV CCACHE_DIR=/ccache
ENV CCACHE_EXEC=/usr/bin/ccache
ENV PATH=/home/builder/bin:$PATH

CMD ["/bin/bash", "-lc", "sleep infinity"]
