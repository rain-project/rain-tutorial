FROM rust:1-slim-bookworm

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        git \
        ca-certificates \
        pkg-config \
        libssl-dev \
        htop \
        tmux \
        bmon \
        vim \
        nano \
 && rm -rf /var/lib/apt/lists/*

RUN rustup component add rust-analyzer rust-src clippy rustfmt && \
    rustup toolchain install nightly --profile minimal --component rustfmt

# Force cargo to shell out to system git so ~/.gitconfig's insteadOf rewrites are honored.
RUN mkdir -p /root/.cargo && \
    printf '[net]\ngit-fetch-with-cli = true\n' > /root/.cargo/config.toml

# Keep target/ off the bind-mounted source folder for build performance.
ENV CARGO_TARGET_DIR=/work/target

WORKDIR /work
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
