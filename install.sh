#!/bin/sh
set -e

REPO="nicolaygerold/deck"
INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"

main() {
    os=$(uname -s | tr '[:upper:]' '[:lower:]')
    arch=$(uname -m)

    case "$os" in
        linux) os="linux" ;;
        darwin) os="macos" ;;
        *) echo "Unsupported OS: $os" && exit 1 ;;
    esac

    case "$arch" in
        x86_64|amd64) arch="x86_64" ;;
        arm64|aarch64) arch="aarch64" ;;
        *) echo "Unsupported architecture: $arch" && exit 1 ;;
    esac

    binary="deck-${os}-${arch}"
    url="https://github.com/${REPO}/releases/latest/download/${binary}"

    echo "Downloading deck for ${os}-${arch}..."
    
    mkdir -p "$INSTALL_DIR"
    
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url" -o "$INSTALL_DIR/deck"
    elif command -v wget >/dev/null 2>&1; then
        wget -q "$url" -O "$INSTALL_DIR/deck"
    else
        echo "Error: curl or wget required" && exit 1
    fi

    chmod +x "$INSTALL_DIR/deck"

    echo "Installed deck to $INSTALL_DIR/deck"
    
    case ":$PATH:" in
        *":$INSTALL_DIR:"*) ;;
        *) echo "Add $INSTALL_DIR to your PATH to use deck" ;;
    esac
}

main
