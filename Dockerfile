FROM debian:stable-slim

# Install dependencies
RUN apt-get update && \
    apt-get install -y wget ca-certificates git build-essential cmake pkg-config libcurl4-openssl-dev \
    libboost-all-dev libssl-dev qtbase5-dev zlib1g-dev libjsoncpp-dev librhash-dev libtinyxml2-dev libtidy-dev && \
    rm -rf /var/lib/apt/lists/*

# Clone and build lgogdownloader
RUN git clone https://github.com/Sude-/lgogdownloader.git /lgogdownloader && \
    cd /lgogdownloader && \
    cmake . && \
    make && \
    make install

RUN useradd -m -u 1000 goguser

WORKDIR /downloads
USER 1000:1000

# Default command: show help
CMD ["lgogdownloader", "--help"]