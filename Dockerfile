# syntax=docker/dockerfile:1
# ---------------------------------------------------------------------------
# Modrinth Server Setup — test image
#
# Build:
#   docker build -t modrinth-setup .
#
# Run (server/ is mounted so files survive the container):
#   docker run --rm -v "$(pwd)/server:/setup/server" \
#       modrinth-setup <slug> --agree-eula
#
# Example:
#   docker run --rm -v "$(pwd)/server:/setup/server" \
#       modrinth-setup yet-another-pack --agree-eula
#
# Pin a version:
#   docker run --rm -v "$(pwd)/server:/setup/server" \
#       modrinth-setup yet-another-pack --version 1.0.1 --agree-eula
#
# Disable auto-update:
#   docker run --rm -v "$(pwd)/server:/setup/server" \
#       modrinth-setup yet-another-pack --agree-eula --no-auto-update
#
# Note: Forge downloads the Minecraft server jar (~50 MB) and all mods
# (~300-600 MB depending on the pack). Expect a few minutes on first run.
# Subsequent runs are fast because existing files are skipped.
# ---------------------------------------------------------------------------

FROM eclipse-temurin:17-jdk-jammy

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       curl \
       unzip \
       python3 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /setup

COPY setup.sh .
RUN chmod +x setup.sh

ENTRYPOINT ["bash", "setup.sh"]
