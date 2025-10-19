# Setup 1st stage
FROM m.daocloud.io/docker.io/library/golang:1.21-alpine AS builder
# Set timezone
ENV TZ=Asia/Shanghai
# Update mirrors and install dependencies
RUN set -eux && \
    sed -i 's/dl-cdn.alpinelinux.org/mirrors.ustc.edu.cn/g' /etc/apk/repositories && \
    apk update && apk add --no-cache git ca-certificates
# Set working directory
WORKDIR /app
# Copy go.mod and go.sum
#COPY golang/go.mod golang/go.sum ./
# Set GOPROXY and GOSUMDB
ARG GOPROXY=https://goproxy.cn,https://goproxy.io,direct
ARG GOSUMDB=off
# Copy source code first
COPY golang/main.go ./
# Download dependencies
RUN GOPROXY=${GOPROXY} GOSUMDB=${GOSUMDB} go mod init k8s-healthcheck-checker && \
    go get k8s.io/api/core/v1@v0.28.0 && \
    go get k8s.io/apimachinery/pkg/apis/meta/v1@v0.28.0 && \
    go get k8s.io/client-go/kubernetes@v0.28.0 && \
    go get k8s.io/client-go/tools/clientcmd@v0.28.0 && \
    go get github.com/xuri/excelize/v2@v2.8.0 && \
    go mod tidy
# Build binary
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
    -a -installsuffix cgo \
    -ldflags="-w -s" \
    -o k8s-health-checker \
    ./main.go

# Setup 2nd stage
FROM m.daocloud.io/docker.io/library/alpine:3.21
# Set timezone
ENV TZ=Asia/Shanghai
# Update mirrors and install runtime dependencies
RUN set -eux && \
    sed -i 's/dl-cdn.alpinelinux.org/mirrors.ustc.edu.cn/g' /etc/apk/repositories && \
    apk update && \
    apk add --no-cache ca-certificates tzdata curl vim wget bash netcat-openbsd && \
    cp /usr/share/zoneinfo/${TZ} /etc/localtime && \
    echo ${TZ} > /etc/timezone && \
    apk del tzdata
# Install kubectl for URL verification
RUN curl -LO "https://repo.huaweicloud.com/kubernetes/v1.28.0/bin/linux/amd64/kubectl" && \
    install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl && \
    rm kubectl
# Set working directory
WORKDIR /app
# Create necessary directories with proper permissions
RUN mkdir -p /app/scripts /app/config /app/output && \
    chmod 755 /app/scripts /app/config /app/output
# Copy binary from builder
COPY --from=builder /app/k8s-health-checker /app/k8s-health-checker
# Copy scripts
COPY scripts/*.sh /app/scripts/
# Set permissions
RUN chmod +x /app/k8s-health-checker /app/scripts/*.sh
# Create non-root user
RUN addgroup -g 1000 appuser && \
    adduser -D -u 1000 -G appuser appuser && \
    chown -R appuser:appuser /app
# Switch to non-root user
USER appuser
# Set entrypoint
ENTRYPOINT ["/app/scripts/entrypoint.sh"]