# syntax=docker/dockerfile:1
# Flutter web served by nginx. Built by .github/workflows/deploy.yml; context = frontend/, extra context "deploy" = deploy/.
#
# The Flutter stage runs on the build machine's own platform (BUILDPLATFORM, the amd64 runner):
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


# Cloudflare can cache unversioned .js for hours. Give each release entry point a content address.
RUN cd build/web \
    && bundle=$(sha256sum main.dart.js | cut -c1-16) \
    && cp main.dart.js "main.$bundle.dart.js" \
    && sed -i "s|main\.dart\.js|main.$bundle.dart.js|g" flutter_bootstrap.js \
    && grep -Fq "main.$bundle.dart.js" flutter_bootstrap.js \
    && bootstrap=$(sha256sum flutter_bootstrap.js | cut -c1-16) \
    && cp flutter_bootstrap.js "flutter_bootstrap.$bootstrap.js" \
    && sed -i "s|flutter_bootstrap\.js|flutter_bootstrap.$bootstrap.js|g" index.html \
    && grep -Fq "flutter_bootstrap.$bootstrap.js" index.html


FROM nginx:1.29-alpine
COPY --from=deploy nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /src/build/web /usr/share/nginx/html
EXPOSE 80
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD ["wget", "-q", "-O", "/dev/null", "http://127.0.0.1/index.html"]
