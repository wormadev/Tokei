FROM oven/bun:1.4-alpine
WORKDIR /app
COPY package.json bun.lock ./
RUN bun install --production --frozen-lockfile
COPY server.ts ./
ENV NODE_ENV=production DB_PATH=/data/tokei.db PORT=3000
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD bun -e "fetch('http://127.0.0.1:' + process.env.PORT + '/api/stats').then(r => process.exit(r.ok ? 0 : 1), () => process.exit(1))"
CMD ["bun", "server.ts"]
