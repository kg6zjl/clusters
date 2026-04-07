FROM python:3.11-slim

ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1
ENV VIRTUAL_ENV=/app/venv
ENV PATH=/app/venv/bin:$PATH

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    git \
    ffmpeg \
    ripgrep \
    nodejs \
    npm \
    && rm -rf /var/lib/apt/lists/*

RUN curl -LsSf https://astral.sh/uv/install.sh | sh && \
    ln -s /root/.local/bin/uv /usr/local/bin/uv

WORKDIR /app

ARG HERMES_VERSION=latest
RUN if [ "$HERMES_VERSION" = "latest" ]; then \
    git clone --depth 1 --recurse-submodules https://github.com/NousResearch/hermes-agent.git .; \
    else \
    git clone --recurse-submodules --branch "$HERMES_VERSION" https://github.com/NousResearch/hermes-agent.git .; \
    fi

RUN uv venv venv --python 3.11 && \
    uv pip install -e ".[all,mcp]" && \
    ln -sf /app/venv/bin/hermes /usr/local/bin/hermes && \
    rm -rf /root/.cache /root/.local/share/uv /root/.cache/uv

RUN mkdir -p /root/.hermes/{cron,sessions,logs,memories,skills,pairing,hooks,image_cache,audio_cache}

WORKDIR /app

ENTRYPOINT ["hermes", "gateway"]
