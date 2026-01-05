# Build stage
FROM node:24-alpine AS builder

# Install build dependencies
RUN apk add --no-cache \
    curl \
    build-base \
    perl \
    llvm-dev \
    clang-dev

# Allow linking libclang on musl
ENV RUSTFLAGS="-C target-feature=-crt-static"

# Install Rust
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
ENV PATH="/root/.cargo/bin:${PATH}"

ARG POSTHOG_API_KEY
ARG POSTHOG_API_ENDPOINT

ENV VITE_PUBLIC_POSTHOG_KEY=$POSTHOG_API_KEY
ENV VITE_PUBLIC_POSTHOG_HOST=$POSTHOG_API_ENDPOINT

# Set working directory
WORKDIR /app

# Copy package files for dependency caching
COPY package*.json pnpm-lock.yaml pnpm-workspace.yaml ./
COPY frontend/package*.json ./frontend/
COPY npx-cli/package*.json ./npx-cli/

# Install pnpm and dependencies
RUN npm install -g pnpm && pnpm install

# Copy source code
COPY . .

# Build application
RUN npm run generate-types
# Increase Node memory for frontend build
ENV NODE_OPTIONS="--max-old-space-size=4096"
RUN cd frontend && pnpm run build
RUN cargo build --release --bin server

# Runtime stage - use Node.js for CLI tools
FROM node:24-alpine AS runtime

# Install runtime dependencies (python3 + build-base needed for gemini-cli native modules)
RUN apk add --no-cache \
    ca-certificates \
    tini \
    libgcc \
    wget \
    git \
    bash \
    openssh-client \
    python3 \
    build-base

# Create app user for security
RUN addgroup -g 1001 -S appgroup && \
    adduser -u 1001 -S appuser -G appgroup -h /home/appuser

# Copy binary from builder
COPY --from=builder /app/target/release/server /usr/local/bin/server

# Create directories and set permissions
RUN mkdir -p /repos /home/appuser/.claude /home/appuser/.codex /home/appuser/.gemini && \
    chown -R appuser:appgroup /repos /home/appuser

# Install Coding Agent CLIs globally
RUN npm install -g \
    @anthropic-ai/claude-code \
    @openai/codex \
    @google/gemini-cli

# Switch to non-root user
USER appuser

# Set runtime environment
ENV HOST=0.0.0.0
ENV PORT=3000
ENV HOME=/home/appuser
EXPOSE 3000

# Set working directory
WORKDIR /repos

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD wget --quiet --tries=1 --spider "http://${HOST:-localhost}:${PORT:-3000}" || exit 1

# Run the application
ENTRYPOINT ["/sbin/tini", "--"]
CMD ["server"]
