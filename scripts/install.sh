#!/bin/sh
set -e

BIN="$(go env GOPATH 2>/dev/null || echo "$HOME/go")/bin"
GO_VERSION=$(sed -n 's/^go \([0-9.]*\)$/\1/p' go.mod)

has() {
    command -v "$1" > /dev/null 2>&1
}

at_least() {
    [ -n "$1" ] && [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]
}

version() {
    case "$1" in
        go) go version | sed 's/.*go\([0-9.]*\).*/\1/' ;;
        just) just --version | awk '{print $2}' ;;
        git) git --version | awk '{print $3}' ;;
        gh) gh --version | awk 'NR==1{print $3}' ;;
        docker) docker --version | sed 's/.*version \([0-9.]*\).*/\1/' ;;
        sbump) sbump --version | awk '{print $NF}' ;;
    esac
}

brew_install() {
    if ! has brew; then
        echo "$1 needs installing and Homebrew is not here to do it. Install $1, then run just install again."
        exit 1
    fi
    brew install "$@" || brew upgrade "$@"
}

ensure() {
    name=$1
    want=$2
    shift 2
    have=""
    if has "$name"; then
        have=$(version "$name" 2>/dev/null || true)
    fi
    if has "$name" && { [ -z "$want" ] || at_least "$have" "$want"; }; then
        echo "$name: found ${have:-}"
        return
    fi
    if has "$name"; then
        echo "$name: $have is below $want, installing $want"
    else
        echo "$name: installing ${want:-latest}"
    fi
    "$@"
    if ! has "$name"; then
        echo "$name: could not be installed"
        exit 1
    fi
}

ensure go "$GO_VERSION" brew_install go
ensure just "" brew_install just
ensure git "" brew_install git
ensure gh "" brew_install gh
ensure docker "" brew_install --cask orbstack
ensure sbump "" sh -c "GOPRIVATE=github.com/nimling/* go install github.com/nimling/sbump/cmd@latest && mv '$BIN/cmd' '$BIN/sbump'"

case ":$PATH:" in
    *":$BIN:"*) ;;
    *) echo "Add $BIN to PATH so smig and sbump are found." ;;
esac

go mod download
just build
install -m 755 bin/smig "$BIN/smig"
echo "Installed."
