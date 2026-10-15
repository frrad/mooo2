# syntax=docker/dockerfile:1
#
# Boxed reference client: official KakaoTalk (Windows x64) installed under Wine,
# driven headlessly. See docs/boxing.md and DESIGN.md §10 / §13.1.
#
# Architecture: KakaoTalk x64 is an x86-64 Windows PE, and WineHQ ships only
# amd64/i386. The image is therefore pinned to linux/amd64. On an arm64 host
# (e.g. Apple Silicon) Docker runs it under QEMU emulation — slower, but correct.
#
# Pins:
#   - Debian base is pinned by manifest digest (amd64 variant of the list).
#   - Wine is pinned to an exact WineHQ apt version (all sub-packages pinned so
#     apt cannot pull a newer wine-stable for a transitive i386 dependency).
#   - winetricks is pinned to a release tag.
#   - The installer bytes are pinned out-of-band by SHA256SUMS (see Makefile).

ARG DEBIAN_DIGEST=sha256:7c7b2c966bc9ee8cedfeef67e0e279108992c77681fa595db4a9d65c06ccc587
FROM --platform=linux/amd64 debian@${DEBIAN_DIGEST}

ARG WINE_BRANCH=stable
ARG WINE_VERSION=10.0.0.0~bookworm-1
ARG WINETRICKS_VERSION=20250102
ENV DEBIAN_FRONTEND=noninteractive

# --- Wine + headless X toolchain ------------------------------------------------
RUN dpkg --add-architecture i386 \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl xvfb x11-utils cabextract winbind procps \
 && mkdir -pm755 /etc/apt/keyrings \
 && curl -fsSL -o /etc/apt/keyrings/winehq-archive.key \
      https://dl.winehq.org/wine-builds/winehq.key \
 && curl -fsSL -o /etc/apt/sources.list.d/winehq-bookworm.sources \
      https://dl.winehq.org/wine-builds/debian/dists/bookworm/winehq-bookworm.sources \
 && apt-get update \
 && apt-get install -y --install-recommends \
      "winehq-${WINE_BRANCH}=${WINE_VERSION}" \
      "wine-${WINE_BRANCH}=${WINE_VERSION}" \
      "wine-${WINE_BRANCH}-amd64=${WINE_VERSION}" \
      "wine-${WINE_BRANCH}-i386:i386=${WINE_VERSION}" \
 && curl -fsSL -o /usr/local/bin/winetricks \
      "https://raw.githubusercontent.com/Winetricks/winetricks/${WINETRICKS_VERSION}/src/winetricks" \
 && chmod +x /usr/local/bin/winetricks \
 && rm -rf /var/lib/apt/lists/*

# --- Non-root Wine user + prefix ------------------------------------------------
RUN useradd -m -u 1000 -s /bin/bash wine
ENV WINEPREFIX=/home/wine/.wine \
    WINEARCH=win64 \
    WINEDEBUG=-all \
    DISPLAY=:0

# --- Boxing scripts + grey-box tap seam ----------------------------------------
COPY docker/box-install.sh docker/entrypoint.sh docker/verify-launch.sh \
     docker/prefix-snapshot.sh docker/prefix-restore.sh docker/prefix-diff.sh \
     docker/prefix-state.sh \
     /usr/local/bin/
RUN chmod +x /usr/local/bin/box-install.sh /usr/local/bin/entrypoint.sh /usr/local/bin/verify-launch.sh \
             /usr/local/bin/prefix-snapshot.sh /usr/local/bin/prefix-restore.sh /usr/local/bin/prefix-diff.sh \
             /usr/local/bin/prefix-state.sh
COPY patches/ /opt/patches/

# --- Install the client into the prefix at build time --------------------------
COPY --chown=wine:wine vendor/KakaoTalk_Setup.exe /home/wine/KakaoTalk_Setup.exe
USER wine
WORKDIR /home/wine
RUN /usr/local/bin/box-install.sh /home/wine/KakaoTalk_Setup.exe

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["/usr/local/bin/verify-launch.sh"]
