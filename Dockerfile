# syntax=docker/dockerfile:1

# --- Stage 1: build the Flutter web bundle -------------------------------
# Flutter 3.44.0 ships Dart 3.12, satisfying pubspec.yaml (sdk ^3.12.0,
# flutter >=3.44.0).
FROM ghcr.io/cirruslabs/flutter:3.44.0 AS build

WORKDIR /app

# Resolve dependencies first so they cache independently of app sources.
COPY pubspec.yaml pubspec.lock ./
RUN flutter pub get

COPY . .

# Backend URL is compiled into the web bundle. For web this is resolved by the
# browser, so it must be a URL the client can reach (default: same host).
ARG PB_URL=http://127.0.0.1:8090
RUN flutter build web --release --dart-define=PB_URL=${PB_URL}

# --- Stage 2: serve the compiled bundle ----------------------------------
FROM nginx:1.27-alpine AS runtime

COPY docker/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/build/web /usr/share/nginx/html

EXPOSE 80
