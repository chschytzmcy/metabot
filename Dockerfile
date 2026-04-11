# ---- Build stage ----
FROM node:20-slim AS builder

WORKDIR /app

# Install build dependencies for native modules (better-sqlite3)
RUN apt-get update && apt-get install -y python3 make g++ && rm -rf /var/lib/apt/lists/*

# Install backend dependencies
COPY package.json package-lock.json ./
RUN npm ci

# Install web dependencies
COPY web/package.json web/package-lock.json ./web/
RUN cd web && npm ci --include=dev

# Copy source and build
COPY tsconfig.json ./
COPY src/ ./src/
COPY web/ ./web/

RUN npm run build

# ---- Runtime stage ----
FROM node:20-slim

WORKDIR /app

# Install runtime deps for better-sqlite3
RUN apt-get update && apt-get install -y python3 make g++ git wget && rm -rf /var/lib/apt/lists/*

# Install Go 1.25.0
RUN wget -qL -O /tmp/go.tar.gz https://go.dev/dl/go1.25.0.linux-amd64.tar.gz \
    && tar -C /usr/local -xzf /tmp/go.tar.gz \
    && rm /tmp/go.tar.gz

# Reuse the existing node user (uid=1000) to match host etsme (uid=1000)
# Rename home directory and user so bind-mounted /home/etsme works
RUN usermod -l etsme -d /home/etsme -m node && groupmod -n etsme node

# Claude CLI is mounted from host (see docker-compose.yml)
# /home/etsme/ is bind-mounted, providing:
#   - ~/.local/bin/claude (binary)
#   - ~/.claude/ (auth credentials)
#   - ~/.local/share/claude/ (versions)

# Install production dependencies (rebuilds native modules for this stage)
COPY package.json package-lock.json ./
RUN npm ci --omit=dev

# Copy built output from builder
COPY --from=builder /app/dist ./dist

# Copy supporting files
COPY bin/ ./bin/
COPY .env.example ./

# Ensure app dir and data dir are writable by etsme
RUN mkdir -p /app/data && chown -R etsme:etsme /app

USER etsme
ENV NODE_ENV=production
ENV API_PORT=9100
ENV HOME=/home/etsme
ENV PATH="/usr/local/go/bin:/home/etsme/.local/bin:${PATH}"

EXPOSE 9100

CMD ["node", "dist/index.js"]
