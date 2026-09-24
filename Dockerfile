# syntax=docker/dockerfile:1

# --- Stage 1: build the Flutter web bundle -------------------------------
# Flutter 3.44.0 ships Dart 3.12.0, the floor pubspec.yaml declares
# (`sdk: ^3.12.0`). The same version is pinned in .github/workflows/ci.yml
# (env.FLUTTER_VERSION) and in DEVELOPMENT.md's toolchain table; the CI job greps
# all three and fails on drift. Bump them together.
FROM ghcr.io/cirruslabs/flutter:3.44.0 AS build

WORKDIR /app

# Resolve dependencies first so they cache independently of app sources.
# No codegen step: the build_runner/json_serializable dependencies are gone and
# model (de)serialization is hand-written, so `pub get` + `build web` is the
# whole build. Adding a `build_runner` invocation here would fail (no
# build_runner in pubspec) -- do not reintroduce one.
COPY pubspec.yaml pubspec.lock ./
RUN flutter pub get

COPY . .

# The backend URL is compiled into the web bundle. For web it is resolved by the
# BROWSER, so it must be reachable from the client machine. Leave it empty for
# the default deployment: nginx (runtime stage below) proxies /api/ to the
# PocketBase service, so the app is same-origin and needs no absolute URL.
ARG PB_URL=
RUN flutter build web --release --dart-define=PB_URL=${PB_URL}

# --- Stage 2: serve the compiled bundle ----------------------------------
FROM nginx:1.27-alpine AS runtime

# Serves the bundle and reverse-proxies /api/ (including the realtime SSE
# stream) to http://pocketbase:8090 -- see docker/nginx.conf.
COPY docker/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/build/web /usr/share/nginx/html

EXPOSE 80
