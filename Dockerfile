## Stage 1: Build the Vue Frontend using pnpm
FROM node:24-alpine AS frontend-builder
WORKDIR /src

# Enable corepack to handle pnpm natively
RUN corepack enable && corepack prepare pnpm@latest --activate

# Copy lock and configuration files first to optimize Docker caching
COPY frontend/package*.json frontend/pnpm-lock.yaml* ./
RUN pnpm install

COPY frontend/ .
RUN pnpm run build

## Stage 2: Build the Go Backend (Bumped to Go 1.26)
FROM golang:1.26-alpine AS backend-builder
WORKDIR /src
RUN apk add --no-cache git
COPY . .
COPY --from=frontend-builder /src/dist ./frontend/dist
RUN go build -o filebrowser .

## Stage 3: Fetch runtime dependencies & Fix Windows line endings
FROM alpine:3.23 AS fetcher
RUN apk update && \
    apk --no-cache add ca-certificates mailcap tini-static dos2unix && \
    wget -O /JSON.sh https://raw.githubusercontent.com/dominictarr/JSON.sh/0d5e5c77365f63809bf6e77ef44a1f34b0e05840/JSON.sh

# Copy scripts into the fetcher stage to sanitize them
COPY docker/common/ /sanitized/
COPY docker/alpine/ /sanitized/
# Force convert all .sh files to Linux LF line endings
RUN find /sanitized/ -type f -name "*.sh" -exec dos2unix {} +

## Stage 4: Final Lightweight Runtime Environment
FROM busybox:1.37.0-musl

ENV UID=1000
ENV GID=1000

RUN addgroup -g $GID user && \
    adduser -D -u $UID -G user user

COPY --chown=user:user --from=backend-builder /src/filebrowser /bin/filebrowser
# Copy the sanitized, Linux-friendly scripts instead of the raw local ones
COPY --chown=user:user --from=fetcher /sanitized/ /
COPY --chown=user:user --from=fetcher /sbin/tini-static /bin/tini
COPY --from=fetcher /JSON.sh /JSON.sh
COPY --from=fetcher /etc/ca-certificates.conf /etc/ca-certificates.conf
COPY --from=fetcher /etc/ca-certificates /etc/ca-certificates
COPY --from=fetcher /etc/mime.types /etc/mime.types
COPY --from=fetcher /etc/ssl /etc/ssl

RUN mkdir -p /config /database /srv && \
    chown -R user:user /config /database /srv \
    && chmod +x /healthcheck.sh

HEALTHCHECK --start-period=2s --interval=5s --timeout=3s CMD /healthcheck.sh

USER user
VOLUME /srv /config /database
EXPOSE 80

ENTRYPOINT [ "tini", "--", "/init.sh" ]