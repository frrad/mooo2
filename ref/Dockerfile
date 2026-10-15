# syntax=docker/dockerfile:1
#
# Reference image: the official Windows client under Wine, with grey-box taps.
# See DESIGN.md §10 and §10.1. Layers are ordered from least to most often
# changed so a tap change reuses the cached Wine and client layers.
#
# Build args come from ref/pin.env (see pin.env.example). This image contains
# the official client and must only ever be pushed to the private registry.

FROM debian:trixie-slim AS wine
RUN dpkg --add-architecture i386 \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl wine wine32:i386 xauth xvfb \
 && rm -rf /var/lib/apt/lists/*
ENV WINEPREFIX=/opt/wine WINEDEBUG=-all
RUN xvfb-run -a wineboot --init && wineserver -w

FROM wine AS client
ARG KAKAO_VERSION
ARG KAKAO_URL
ARG KAKAO_SHA256
RUN test -n "$KAKAO_VERSION" && test -n "$KAKAO_URL" && test -n "$KAKAO_SHA256" \
 && curl -fsSL "$KAKAO_URL" -o /tmp/setup.exe \
 && echo "$KAKAO_SHA256  /tmp/setup.exe" | sha256sum -c - \
 && xvfb-run -a wine /tmp/setup.exe /S \
 && wineserver -w \
 && rm /tmp/setup.exe
LABEL org.opencontainers.image.version="$KAKAO_VERSION"

FROM client
COPY taps/ /opt/taps/
