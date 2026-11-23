# syntax=docker/dockerfile:1.7

# ---------------------------------------------------------------------------
# Stage 1: build the nanobot venv with uv, pinned to the system Python.
# ---------------------------------------------------------------------------
ARG NANOBOT_VERSION=0.4.2
ARG PIXI_VERSION=v0.84.2
ARG UID=1000
ARG GID=1000
FROM ghcr.io/astral-sh/uv:python3.12-bookworm-slim AS nanobot

ARG NANOBOT_VERSION

ENV UV_PYTHON_PREFERENCE=only-system \
    UV_LINK_MODE=copy \
    UV_COMPILE_BYTECODE=1

# Pin the interpreter to the system Python present in this stage; stage 3 also
# ships /usr/local/bin/python3.12 so the venv resolves after the copy.
RUN --mount=type=cache,target=/root/.cache/uv \
    uv venv --python /usr/local/bin/python3.12 /app/.venv && \
    uv pip install --python /app/.venv/bin/python "nanobot-ai==${NANOBOT_VERSION}"

# ---------------------------------------------------------------------------
# Stage 2: download the pinned pixi release binary (statically linked, musl).
# ---------------------------------------------------------------------------
FROM debian:bookworm-slim AS pixi

ARG PIXI_VERSION
ARG TARGETARCH

RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates curl && \
    rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    arch="${TARGETARCH:-$(dpkg --print-architecture)}"; \
    case "$arch" in \
        amd64) pixi_arch=x86_64 ;; \
        arm64) pixi_arch=aarch64 ;; \
        *) echo "unsupported architecture: $arch" >&2; exit 1 ;; \
    esac; \
    asset="pixi-${pixi_arch}-unknown-linux-musl.tar.gz"; \
    url="https://github.com/prefix-dev/pixi/releases/download/${PIXI_VERSION}/${asset}"; \
    cd /tmp; \
    curl -fsSL -o "$asset" "$url"; \
    curl -fsSL -o "$asset.sha256" "$url.sha256"; \
    sha256sum -c "$asset.sha256"; \
    tar -xzf "$asset" pixi; \
    install -m 0755 pixi /usr/local/bin/pixi; \
    rm -f "$asset" "$asset.sha256" pixi; \
    /usr/local/bin/pixi --version

# ---------------------------------------------------------------------------
# Stage 3: runtime image.
#
# Homebrew is baked into /data/brew (persisted on its own named volume) because
# nanobot's WebUI app runner executes `brew install ...` with a minimal env
# (HOME, LANG, TERM, PATH, PYTHONUNBUFFERED) and resolves `brew` from PATH:
# image-level HOMEBREW_* variables never reach that subprocess. brew derives its
# prefix from the location of bin/brew, so the prefix must be a real install
# tree at a stable path, not an env-only convention.
# ---------------------------------------------------------------------------
FROM python:3.12-slim-bookworm AS runtime

ARG NANOBOT_VERSION
ARG UID
ARG GID

LABEL org.opencontainers.image.title="nanobot + pixi" \
      org.opencontainers.image.description="nanobot-ai with pixi-managed runtime tools and persistent /data trees" \
      org.opencontainers.image.version="${NANOBOT_VERSION}" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.base.name="docker.io/library/python:3.12-slim-bookworm"

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        openssh-client \
        libmagic1 \
        tini \
        tzdata \
        xz-utils && \
    rm -rf /var/lib/apt/lists/*

# Fixed non-root identity. UID/GID are build args so image tags can be
# aligned with host users, but the container always runs as "nanobot".
RUN groupadd --gid "${GID}" nanobot && \
    useradd --uid "${UID}" --gid nanobot --home-dir /data/home \
        --shell /bin/bash --no-create-home nanobot

ENV HOME=/data/home \
    NANOBOT_HOME=/data/config \
    NANOBOT_UID=${UID} \
    NANOBOT_GID=${GID} \
    PIXI_HOME=/data/pixi \
    PIXI_NO_TELEMETRY=1 \
    PIXI_CACHE_DIR=/data/cache/pixi \
    XDG_CACHE_HOME=/data/cache \
    UV_CACHE_DIR=/data/cache/uv \
    UV_TOOL_DIR=/data/home/.local/share/uv/tools \
    UV_TOOL_BIN_DIR=/data/home/.local/bin \
    PIP_CACHE_DIR=/data/cache/pip \
    HOMEBREW_PREFIX=/data/brew \
    HOMEBREW_CELLAR=/data/brew/Cellar \
    HOMEBREW_REPOSITORY=/data/brew/Homebrew \
    HOMEBREW_CACHE=/data/cache/brew \
    HOMEBREW_NO_AUTO_UPDATE=1 \
    HOMEBREW_NO_ANALYTICS=1 \
    HOMEBREW_NO_ENV_HINTS=1 \
    npm_config_prefix=/data/home/.local \
    npm_config_cache=/data/home/.npm \
    PATH=/data/pixi/bin:/data/home/.local/bin:/data/brew/bin:/app/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    PYTHONUNBUFFERED=1 \
    PYTHONFAULTHANDLER=1 \
    UV_LINK_MODE=copy \
    NANOBOT_VERSION=${NANOBOT_VERSION}

# The venv stays in the image layer: never mount a volume over /app/.venv.
# --chown avoids a second full-size layer just to fix ownership.
COPY --chown=nanobot:nanobot --from=nanobot /app/.venv /app/.venv
COPY --from=nanobot /usr/local/bin/uv /usr/local/bin/uvx /usr/local/bin/
COPY --from=pixi /usr/local/bin/pixi /usr/local/bin/pixi

# Persistent trees are seeded with the right ownership so Docker named
# volumes created from this image inherit 1000:1000 on first use. The runtime
# entrypoint never runs an unconditional recursive chown.
RUN mkdir -p /data/config/workspace \
        /data/home/.local/bin \
        /data/home/.local/share/uv/tools \
        /data/pixi \
        /data/brew \
        /data/cache/pixi /data/cache/uv /data/cache/pip /data/cache/brew && \
    chown -R nanobot:nanobot /data

# Bake Homebrew into /data/brew. brew refuses to run as root, so the install
# step runs as nanobot and the runtime user is restored afterwards.
#
# A depth-1 clone plus the prefix/bin/brew symlink is the official custom-prefix
# layout: bin/brew derives HOMEBREW_PREFIX from its own resolved path, which is
# what makes `brew` work when the WebUI's minimal subprocess env has no
# HOMEBREW_* variables at all. `brew --version` is answered by bin/brew without
# Ruby; `brew config` is the first command that needs it and vendors Homebrew's
# portable Ruby (brew has no system ruby on this image). Running it here bakes
# that in, so a fresh /data/brew volume seeded from the image needs no network
# to run brew at all. The scratch HOMEBREW_CACHE keeps downloaded tarballs and
# the API index out of the image: /data/cache is a volume at runtime, so a
# build-time copy there would be dead weight. No formulae are installed at
# build time: bottles belong in the volume.
USER nanobot
RUN git clone --depth 1 --single-branch https://github.com/Homebrew/brew /data/brew/Homebrew && \
    mkdir -p /data/brew/bin && \
    ln -s ../Homebrew/bin/brew /data/brew/bin/brew && \
    HOMEBREW_CACHE=/tmp/brew-cache brew --version && \
    HOMEBREW_CACHE=/tmp/brew-cache brew config > /tmp/brew-config.txt && \
    grep -q '^Homebrew Ruby:' /tmp/brew-config.txt && \
    rm -rf /tmp/brew-config.txt /tmp/brew-cache
USER root

# Container-side shim: make NANOBOT_HOME the default nanobot instance root.
# Without it, default CLI calls print the symlink path (/data/home/.nanobot)
# instead of /data/config, even though both name the same files.
COPY scripts/sitecustomize.py /app/.venv/lib/python3.12/site-packages/sitecustomize.py
RUN chown nanobot:nanobot /app/.venv/lib/python3.12/site-packages/sitecustomize.py

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN sed -i 's/\r$//' /usr/local/bin/entrypoint.sh && \
    chmod 0755 /usr/local/bin/entrypoint.sh
COPY scripts/nanobot-bootstrap.py /usr/local/bin/nanobot-bootstrap.py
COPY scripts/nanobot-channels.py /usr/local/bin/nanobot-channels.py
COPY scripts/healthcheck.py /usr/local/bin/healthcheck.py
COPY scripts/workspace-agents-env.py /usr/local/bin/workspace-agents-env.py
COPY scripts/brew-wrapper.sh /usr/local/bin/nanobot-brew
RUN sed -i 's/\r$//' /usr/local/bin/nanobot-brew && \
    chmod 0755 /usr/local/bin/nanobot-bootstrap.py \
        /usr/local/bin/nanobot-channels.py \
        /usr/local/bin/healthcheck.py \
        /usr/local/bin/workspace-agents-env.py \
        /usr/local/bin/nanobot-brew

COPY etc/nanobot-env.md /etc/nanobot-env.md
RUN chmod 0444 /etc/nanobot-env.md

# Start as root only for the entrypoint's setup phase; it drops to nanobot.
USER root
WORKDIR /data/config/workspace

EXPOSE 8765 18790
STOPSIGNAL SIGTERM

# -B keeps Docker's root-executed healthcheck from writing __pycache__.
HEALTHCHECK --interval=30s --timeout=5s --start-period=45s --retries=3 \
    CMD ["/app/.venv/bin/python", "-B", "/usr/local/bin/healthcheck.py"]

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["gateway"]
