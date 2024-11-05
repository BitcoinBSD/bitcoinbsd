#!/bin/sh

# SPDX-FileCopyrightText: 2024 Timothy Redaelli
# SPDX-License-Identifier: MIT

set -eu

OS=$(uname -s)
: "${UID=$(id -ru)}"

if [ "$UID" != 0 ]; then
    echo "$0: need root privileges" >&2
    exit 130
fi

install_packages() {
    case $OS in
        OpenBSD)
            # https://github.com/bitcoin/bitcoin/blob/v28.0/doc/build-openbsd.md
            set -- bash git gmake libevent libtool boost
            _autoconf=$(pkg_info -qQ autoconf | sed -n '/^autoconf-[0-9]/p' \
                | sort -V | tail -n 1)
            _automake=$(pkg_info -qQ automake | sed -n '/^automake-[0-9]/p' \
                | sort -V | tail -n 1)
            _python=$(pkg_info -qQ python | sed -n '/^python-[0-9]/p' \
                | sort -V | tail -n 1)
            set -- "$@" "$_autoconf" "$_automake" "$_python"
            AUTOCONF_VERSION="$(echo "$_autoconf" \
                | sed 's/^autoconf-\([0-9]*\.[0-9]*\).*$/\1/')"
            AUTOMAKE_VERSION="$(echo "$_automake" \
                | sed 's/^automake-\([0-9]*\.[0-9]*\).*$/\1/')"
            unset _autoconf _automake _python
            # Descriptor Wallet Support
            set -- "$@" sqlite3
            # Legacy Wallet Support
            # https://github.com/bitcoin/bitcoin/blob/v28.0/depends/README.md
            set -- "$@" gtar--
            # Notifications
            set -- "$@" zeromq
            # Check GIT tag signature
            set -- "$@" gnupg

            pkg_add "$@"
            ;;
        *)
            echo "OS not supported." >&2
            exit 2
            ;;
    esac
}

install_packages

groupinfo -e _bitcoind || groupadd -g 813 _bitcoind
userinfo -e _bitcoind || useradd -d /var/empty -c "Bitcoind Account" \
    -g 813 -s /sbin/nologin -u 813 _bitcoind

mkdir -m 0700 /var/bitcoin && chown _bitcoind:_bitcoind /var/bitcoin
cd /var/bitcoin

export HOME=/var/bitcoin
GNUPGHOME=$(su -m _bitcoind -c "mktemp -d") ; export GNUPGHOME

trap 'rm -rf "$GNUPGHOME"' EXIT

echo "Select bitcoin variant:"
echo "1) Bitcoin Core"
echo "2) Bitcoin Knots"
echo "0) None"
echo "Enter the number of your choice:"

while :; do
    read -r choice
    case $choice in
        1)
            BITCOIN_REPO=https://github.com/bitcoin/bitcoin.git
            BITCOIN_TAG=v28.0
            BITCOIN_KEYS="E777299FC265DD04793070EB944D35F9AC3DB76A
                          D1DBF2C4B96F2DEBF4C16654410108112E7EA81F
                          152812300785C96444D3334D17565732E08E5E41
                          6B002C6EA3F91B1B0DF0C9BC8F617F1200A6D25C
                          4D1B3D5ECBA1A7E05371EEBE46800E30FC748A66"
            BITCOIN_PATCHES_REPO=""
            BITCOIN_PATCHES=""
            break
            ;;

        2)
            BITCOIN_REPO=https://github.com/bitcoinknots/bitcoin.git
            BITCOIN_TAG=v27.1.knots20240801
            BITCOIN_KEYS="1A3E761F19D2CC7785C5502EA291A2C45D0C504A
                          CFB16E21C950F67FA95E558F2EEB9F5CC09526C1"
            BITCOIN_PATCHES_REPO=https://github.com/bitcoin/bitcoin.git
            BITCOIN_PATCHES="8aff3fd292442c50b61db02527f68f9258263e4a"
            break
            ;;
        0)
            break
            ;;

        *)
            echo "Invalid selection."
            ;;
    esac
done

if [ -n "${BITCOIN_KEYS-}" ]; then
    for _key in $BITCOIN_KEYS; do
        su -m _bitcoind -c \
            "gpg --keyserver hkps://keys.openpgp.org --recv \"$_key\""
    done
    unset _key
    if [ -d "bitcoin" ]; then
        cd "bitcoin"
        su -m _bitcoind -c "git fetch --tags \"$BITCOIN_REPO\""
    else
        su -m _bitcoind -c "git clone \"$BITCOIN_REPO\""
        cd "bitcoin"
    fi

    su -m _bitcoind -c "git verify-tag \"$BITCOIN_TAG\""
    su -m _bitcoind -c "git checkout -f \"$BITCOIN_TAG\""

    for _patch in $BITCOIN_PATCHES; do
        su -m _bitcoind -c "git fetch \"$BITCOIN_PATCHES_REPO\" \"$_patch\""
        su -m _bitcoind -c "git verify-commit FETCH_HEAD"
        su -m _bitcoind -c "git cherry-pick FETCH_HEAD"
    done

    case "$(uname -m)" in
        amd64|x86_64)
            ;;
        *)
            sed -i "s:^\$(package)_config_opts_openbsd=.*:& --with-mutex=POSIX/pthreads/library:" \
                depends/packages/bdb.mk
            ;;
    esac

    CC=clang \
    CXX=clang++ \
    NO_BOOST=1 \
    NO_LIBEVENT=1 \
    NO_QT=1 \
    NO_QR=1 \
    NO_SQLITE=1 \
    NO_ZMQ=1 \
    NO_UPNP=1 \
    NO_USDT=1 \
    NO_NATPMP=1 \
        su -m _bitcoind -c "gmake -C depends -j \"$(sysctl -n hw.ncpu)\""
    BDB_PREFIX="$( echo "$PWD"/depends/*-unknown-*bsd* )"
    export AUTOCONF_VERSION AUTOMAKE_VERSION
    su -m _bitcoind -c "./autogen.sh"
    BDB_LIBS="-L${BDB_PREFIX}/lib -ldb_cxx-4.8" \
    BDB_CFLAGS="-I${BDB_PREFIX}/include" \
    MAKE=gmake \
        su -m _bitcoind -c "./configure --enable-werror --with-gui=no"
    su -m _bitcoind -c "gmake -j \"$(sysctl -n hw.ncpu)\""
    su -m _bitcoind -c "gmake check"
    cd -
fi

echo "Do you want to install electrs? (y/n)"
while :; do
    read -r choice
    case $choice in
        y|Y)
            break
            ;;

        n|N)
            exit 0
            ;;

        *)
            echo "Invalid selection."
            ;;
    esac
done

ELECTRS_REPO=https://github.com/romanz/electrs.git
ELECTRS_TAG=v0.10.6
ELECTRS_KEYS="15C8C3574AE4F1E25F3F35C587CAE5FA46917CBB"

case $OS in
    OpenBSD)
        _llvm=$(pkg_info -qQ llvm | sed -n '/^llvm-[0-9]/p' | \
            sort -V | tail -n 1)
        pkg_add rust rust-rustfmt "$_llvm"
        LLVM_VERSION="$(echo "$_llvm" | sed 's/^llvm-\([0-9]*\).*$/\1/')"
        unset _llvm
        export CC="/usr/local/llvm$LLVM_VERSION/bin/clang"
        export CXX="/usr/local/llvm$LLVM_VERSION/bin/clang++"
        export LIBCLANG_PATH="/usr/local/llvm$LLVM_VERSION/lib"
        # FIXME librocksdb-sys/build.rs should include openbsd as well
        export CXXFLAGS="${CXXFLAGS-} -DOS_OPENBSD -DROCKSDB_PLATFORM_POSIX -DROCKSDB_LIB_IO_POSIX"
        ;;

    *)
        echo "OS not supported." >&2
        exit 2
        ;;
esac

for _key in $ELECTRS_KEYS; do
    su -m _bitcoind -c "gpg --keyserver hkps://keys.openpgp.org --recv \"$_key\""
done

if [ -d "electrs" ]; then
    cd "electrs"
    su -m _bitcoind -c "git fetch --tags \"$ELECTRS_REPO\""
else
    su -m _bitcoind -c "git clone \"$ELECTRS_REPO\""
    cd "electrs"
fi

su -m _bitcoind -c "git tag -v \"$ELECTRS_TAG\""
su -m _bitcoind -c "git checkout -f \"$ELECTRS_TAG\""
su -m _bitcoind -c "cargo build --locked --release"

cd -
