# Stage 1: Build
FROM --platform=$BUILDPLATFORM node:20-alpine AS builder
WORKDIR /app
# 锁定依赖版本，保证可复现构建（npm ci 严格按 lockfile 安装）
COPY package.json package-lock.json ./
RUN npm ci
COPY . .
RUN npm run build

# Stage 2: Serve
FROM --platform=$TARGETPLATFORM nginx:1.25-alpine
COPY --from=builder /app/dist /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf
EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
