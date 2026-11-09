# The story renderer. Built from the repository root so it can carry the
# caption module the story engine uses (`--dockerfile renderer/Dockerfile`).
FROM node:24-bookworm-slim

# ffmpeg with libass for burned-in captions; Liberation Sans is metric-equal
# to Arial, which the caption themes name, and fontconfig maps one to the other.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ffmpeg fonts-liberation fontconfig ca-certificates \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
# Code-drawn videos (renderer/draw) need @napi-rs/canvas, which ships a
# prebuilt binary for this image; installed before the code so it is cached.
COPY renderer/package.json renderer/package.json
RUN cd renderer && npm install --omit=dev --no-audit --no-fund
COPY supabase/functions/_shared/video/ supabase/functions/_shared/video/
COPY renderer/render.ts renderer/render.ts
COPY renderer/draw/*.ts renderer/draw/
COPY renderer/draw/fonts/ renderer/draw/fonts/
# Node runs the TypeScript itself (type stripping); the files are ES modules.
RUN echo '{"type":"module","private":true}' > package.json

ENV NODE_NO_WARNINGS=1
CMD ["node", "renderer/render.ts"]
