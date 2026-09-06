# ffmpeg is the reason this container exists rather than an Edge Function, so it
# is installed in the runtime image, not just the build one.
FROM node:22-slim AS build
WORKDIR /app
COPY package.json package-lock.json* ./
RUN npm ci --include=dev || npm install --include=dev
COPY tsconfig.json ./
COPY src ./src
RUN npm run build

FROM node:22-slim AS runtime
WORKDIR /app
RUN apt-get update \
 && apt-get install -y --no-install-recommends ffmpeg ca-certificates \
 && rm -rf /var/lib/apt/lists/*
ENV NODE_ENV=production
COPY package.json package-lock.json* ./
RUN npm ci --omit=dev || npm install --omit=dev
COPY --from=build /app/dist ./dist
# Runs unprivileged: this process holds decrypted platform tokens in memory.
USER node
CMD ["node", "--enable-source-maps", "dist/index.js"]
