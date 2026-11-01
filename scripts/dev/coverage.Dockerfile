FROM kcov/kcov
ARG BATS_TAG=v1.14.0
ARG JQ_TAG=jq-1.7.1
ARG NODE_VERSION=24.22.1
RUN apt-get update && apt-get install -y --no-install-recommends python3 python3-coverage git tmux procps ca-certificates curl uuid-runtime xz-utils ripgrep && rm -rf /var/lib/apt/lists
# Debian nodejs carries CVE-2026-111497, so pin a fixed official release.
RUN arch="$(dpkg --print-architecture | sed 's/amd64/x64/')" && base="$(printf 'https:\057\057nodejs.org/dist/v%s' "${NODE_VERSION}")" && tarball="node-v${NODE_VERSION}-linux-${arch}.tar.xz" && cd /tmp && curl -fsSLO "${base}/${tarball}" && curl -fsSL "${base}/SHASUMS256.txt" | grep " ${tarball}\$" | sha256sum -c - && tar -xJf "${tarball}" -C /usr/local --strip-components=1 --no-same-owner && rm "${tarball}" && node --version
RUN git clone --depth 1 --branch "${BATS_TAG}" "$(printf 'https:\057\057github.com/bats-core/bats-core')" /opt/bats && /opt/bats/install.sh /usr/local
RUN curl -fsSL -o /usr/local/bin/jq "$(printf 'https:\057\057github.com/jqlang/jq/releases/download/%s/jq-linux-%s' "${JQ_TAG}" "$(dpkg --print-architecture)")" && chmod +x /usr/local/bin/jq
RUN printf '%s\n' 'import sys; sys.path.append("/usr/lib/python3/dist-packages"); exec("try:\n import coverage; coverage.process_startup()\nexcept ImportError: pass")' > /usr/local/lib/python3.11/dist-packages/zz_coverage.pth
RUN useradd -m -u 1000 cov && mkdir -p /private /w /out && ln -sfn /tmp /private/tmp && chown cov /w /out
USER cov
