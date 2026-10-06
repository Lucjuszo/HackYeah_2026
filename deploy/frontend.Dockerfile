# syntax=docker/dockerfile:1
# Flutter web served by nginx. Built by deploy/build.sh; context = frontend/, extra context "deploy" = deploy/.
#
# The Flutter stage runs on the build machine's own platform (BUILDPLATFORM, e.g. the amd64 PC):
# its output is plain HTML/JS, the same for every CPU. Only the small nginx stage is linux/arm64,
# so the Raspberry Pi gets nginx + the built files and never the Flutter SDK.

FROM --platform=$BUILDPLATFORM debian:bookworm-slim AS build
ARG FLUTTER_VERSION=3.47.6
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl git unzip xz-utils \
    && rm -rf /var/lib/apt/lists/*
RUN git clone --depth 1 --branch "$FLUTTER_VERSION" https://github.com/flutter/flutter.git /opt/flutter
ENV PATH=/opt/flutter/bin:$PATH
RUN flutter --disable-analytics \
    && flutter config --no-cli-animations --enable-web \
    && flutter precache --web
WORKDIR /src
# Dependencies first: this layer is reused while only the code changes.
COPY pubspec.yaml pubspec.lock ./
RUN flutter pub get
COPY . .
# Public address of the backend, compiled into the app (no runtime config in Flutter web).
ARG API_URL
RUN test -n "$API_URL" || { echo "API_URL build arg is required" >&2; exit 1; } \
    && flutter build web --release --dart-define=API_URL="$API_URL"


FROM nginx:1.29-alpine
COPY --from=deploy nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /src/build/web /usr/share/nginx/html
EXPOSE 80
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD ["wget", "-q", "-O", "/dev/null", "http://127.0.0.1/index.html"]
