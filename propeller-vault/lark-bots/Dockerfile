FROM node:22-alpine
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund
COPY index.mjs policy.mjs ./
USER node
HEALTHCHECK --interval=60s --timeout=5s --start-period=180s CMD node -e "const h=JSON.parse(require('fs').readFileSync('/tmp/propeller-bot-health.json'));process.exit(h.ok&&Date.now()-h.at<180000?0:1)"
CMD ["node","index.mjs"]
