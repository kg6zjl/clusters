# Renders the site's Mermaid sources to SVG. Nothing about the *site* needs this: the SVGs are
# committed to site/assets/img/ and Pages publishes them as files. This image exists so the render
# is reproducible by anything with a Docker daemon -- a laptop, a runner pod, or the agent, which
# has no internet egress and therefore cannot `npm install` anything at runtime.
#
# Pinned, not floating: a diagram that renders differently after an upstream release is worse than
# no build step at all, because the committed SVG stops matching what the source says. renovate
# tracks the mermaid-cli pin below (customManagers in renovate.json).
FROM node:22-bookworm-slim

# renovate: datasource=npm depName=@mermaid-js/mermaid-cli
ARG MERMAID_CLI_VERSION=11.12.0

# Puppeteer drives a real Chromium. These are its shared-library dependencies on bookworm; the
# list is upstream's and is complete for headless rendering, which is all render.sh does.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      fonts-dejavu-core \
      fonts-liberation \
      libasound2 \
      libatk-bridge2.0-0 \
      libatk1.0-0 \
      libc6 \
      libcairo2 \
      libcups2 \
      libdbus-1-3 \
      libexpat1 \
      libfontconfig1 \
      libgbm1 \
      libglib2.0-0 \
      libgtk-3-0 \
      libnspr4 \
      libnss3 \
      libpango-1.0-0 \
      libpangocairo-1.0-0 \
      libstdc++6 \
      libx11-6 \
      libxcb1 \
      libxcomposite1 \
      libxdamage1 \
      libxext6 \
      libxfixes3 \
      libxkbcommon0 \
      libxrandr2 \
      libxshmfence1 \
 && rm -rf /var/lib/apt/lists/*

# Chromium comes from Debian, not from Puppeteer's own download: it is already in the apt index,
# so this needs no network at render time and no version skew between the binary and the libraries
# above.
ENV PUPPETEER_SKIP_DOWNLOAD=true \
    PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium

RUN apt-get update \
 && apt-get install -y --no-install-recommends chromium \
 && rm -rf /var/lib/apt/lists/*

RUN npm install --global --no-fund --no-audit "@mermaid-js/mermaid-cli@${MERMAID_CLI_VERSION}" \
 && mmdc --version

COPY mermaid.config.json /etc/mermaid/mermaid.config.json
COPY puppeteer.config.json /etc/mermaid/puppeteer.config.json
COPY render.sh /usr/local/bin/render.sh
COPY normalize-svg.js /usr/local/bin/normalize-svg.js
RUN chmod +x /usr/local/bin/render.sh

# /src holds the .mmd sources, /out receives the .svg. Both are bind-mounted, so the image carries
# no copy of the diagrams and cannot drift from them.
WORKDIR /work
ENTRYPOINT ["/usr/local/bin/render.sh"]
