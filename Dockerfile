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
        tzdata && \
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
    PATH=/data/pixi/bin:/data/home/.local/bin:/app/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    PYTHONUNBUFFERED=1 \
    PYTHONFAULTHANDLER=1 \
    UV_LINK_MODE=copy

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
        /data/cache/pixi /data/cache/uv /data/cache/pip && \
    chown -R nanobot:nanobot /data

# Container-side shim: make NANOBOT_HOME the default nanobot instance root.
# Without it, default CLI calls print the symlink path (/data/home/.nanobot)
# instead of /data/config, even though both name the same files.
COPY scripts/sitecustomize.py /app/.venv/lib/python3.12/site-packages/sitecustomize.py
RUN chown nanobot:nanobot /app/.venv/lib/python3.12/site-packages/sitecustomize.py

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN sed -i 's/\r$//' /usr/local/bin/entrypoint.sh && \
    chmod 0755 /usr/local/bin/entrypoint.sh
COPY scripts/nanobot-bootstrap.py /usr/local/bin/nanobot-bootstrap.py
COPY scripts/healthcheck.py /usr/local/bin/healthcheck.py
RUN chmod 0755 /usr/local/bin/nanobot-bootstrap.py /usr/local/bin/healthcheck.py

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
