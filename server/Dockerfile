FROM oven/bun:1.3-alpine
WORKDIR /app
COPY package.json bun.lock ./
RUN bun install --production --frozen-lockfile
COPY server.ts ./
ENV DB_PATH=/data/tokei.db PORT=3000
EXPOSE 3000
CMD ["bun", "server.ts"]
