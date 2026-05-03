# syntax=docker/dockerfile:1.7
# ---------- Builder ----------
FROM node:20-alpine AS builder
WORKDIR /app

# Install build deps for native modules (bcryptjs is pure JS but pg may need).
# Skip the bundled Puppeteer Chromium download — runtime stage uses Alpine's
# system Chromium which is smaller and signed for Alpine's musl.
ENV PUPPETEER_SKIP_DOWNLOAD=true
RUN apk add --no-cache python3 make g++

COPY package*.json ./
RUN npm ci

COPY tsconfig.json ./
COPY src ./src
RUN node --max-old-space-size=512 ./node_modules/typescript/bin/tsc -p tsconfig.json

# Prune dev deps
RUN npm prune --omit=dev

# ---------- Runtime ----------
FROM node:20-alpine AS runtime
WORKDIR /app

# M1b: Puppeteer (PDF export) needs Chromium + system libs. Alpine package
# names differ from glibc distros — we install Alpine's chromium package
# rather than the libnss3/libatk*/libxss1/etc. set documented for Debian.
# PUPPETEER_EXECUTABLE_PATH points the puppeteer SDK at /usr/bin/chromium-browser.
# (See https://pptr.dev/troubleshooting#running-on-alpine)
RUN apk add --no-cache \
      chromium \
      nss \
      freetype \
      freetype-dev \
      harfbuzz \
      ca-certificates \
      ttf-freefont \
      font-noto \
      font-noto-arabic \
      dumb-init

ENV NODE_ENV=production \
    PORT=4000 \
    PUPPETEER_SKIP_DOWNLOAD=true \
    PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium-browser

# Non-root user for runtime
RUN addgroup -S app && adduser -S app -G app

COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/dist ./dist
COPY --from=builder /app/package.json ./package.json

USER app
EXPOSE 4000

# Healthcheck hits /api/health (no auth)
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD wget -qO- http://127.0.0.1:${PORT}/api/health || exit 1

# dumb-init handles SIGTERM cleanly so Puppeteer's headless Chromium child
# processes are reaped on container shutdown.
ENTRYPOINT ["dumb-init", "--"]
CMD ["node", "dist/src/server.js"]
