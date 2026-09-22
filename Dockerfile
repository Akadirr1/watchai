# syntax=docker/dockerfile:1.7
#
# QuotaPets — Claude + Codex quota API.
#
# Alpine is the right base here even though the image is large: the Codex CLI publishes
# ONLY musl Linux artifacts (there is no glibc build at all), and Claude Code publishes
# matching -musl packages. Both vendor CLIs are installed because login drives the real
# binaries rather than reimplementing OAuth.
#
# Coolify builds this on the deployment server, so an ARM host produces an ARM image with
# no multi-arch work. Nothing here is architecture-pinned.

FROM node:22-alpine AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY tsconfig.json ./
COPY src ./src
RUN npm run build

FROM node:22-alpine AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force

FROM node:22-alpine AS runtime
ENV NODE_ENV=production \
    PORT=3000 \
    DATA_DIR=/data \
    CLAUDE_CONFIG_DIR=/data/claude \
    CODEX_HOME=/data/codex
WORKDIR /app

# The vendor CLIs. --omit=optional must NOT be used: it skips the native package and
# leaves a stub that cannot log in.
RUN npm install -g @anthropic-ai/claude-code @openai/codex \
 && npm cache clean --force

COPY --from=deps  /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
COPY package.json ./

RUN mkdir -p /data/claude /data/codex
VOLUME ["/data"]
EXPOSE 3000

# Liveness only — deliberately independent of provider health, so a vendor outage cannot
# trigger a restart loop.
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:'+(process.env.PORT||3000)+'/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

CMD ["node", "dist/index.js"]
