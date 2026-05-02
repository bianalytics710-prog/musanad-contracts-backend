# syntax=docker/dockerfile:1.7
# ---------- Builder ----------
FROM node:20-alpine AS builder
WORKDIR /app

# Install build deps for native modules (bcryptjs is pure JS but pg may need)
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

# Non-root user for runtime
RUN addgroup -S app && adduser -S app -G app

ENV NODE_ENV=production \
    PORT=4000

COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/dist ./dist
COPY --from=builder /app/package.json ./package.json

USER app
EXPOSE 4000

# Healthcheck hits /api/health (no auth)
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD wget -qO- http://127.0.0.1:${PORT}/api/health || exit 1

CMD ["node", "dist/src/server.js"]
