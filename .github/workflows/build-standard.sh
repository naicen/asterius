#!/bin/bash

set -euo pipefail

echo 'deb [check-valid-until=no] http://snapshot.debian.org/archive/debian/20200615T204439Z stretch main contrib non-free' > /etc/apt/sources.list
echo 'deb [check-valid-until=no] http://snapshot.debian.org/archive/debian-security/20200615T204439Z stretch/updates main contrib non-free' >> /etc/apt/sources.list
echo 'deb [check-valid-until=no] http://snapshot.debian.org/archive/debian/20200615T204439Z stretch-updates main contrib non-free' >> /etc/apt/sources.list
apt update
apt full-upgrade -y
apt install -y \
  automake \
  build-essential \
  curl \
  gawk \
  git \
  libffi-dev \
  libgmp-dev \
  libncurses-dev \
  libtool-bin \
  pkg-config \
  python3-sphinx \
  xz-utils \
  zlib1g-dev
mkdir -p ~/.local/bin
curl -L https://github.com/commercialhaskell/stack/releases/download/v2.3.1/stack-2.3.1-linux-x86_64-bin -o ~/.local/bin/stack
chmod u+x ~/.local/bin/stack
~/.local/bin/stack --resolver nightly-2020-06-20 install \
  alex \
  happy \
  hscolour

pushd /tmp
git clone --recurse-submodules --branch $BRANCH https://github.com/TerrorJack/ghc.git
popd

export PATH=~/.local/bin:$(~/.local/bin/stack path --compiler-bin):$PATH
mv .github/workflows/build-linux.mk /tmp/ghc/mk/build.mk
pushd /tmp/ghc
./boot
./configure
make
make binary-dist
mkdir ghc-bindist
mv *.tar.* ghc-bindist/
(ls -l ghc-bindist && sha256sum -b ghc-bindist/*) > ghc-bindist/sha256.txt
popd

mv /tmp/ghc/ghc-bindist .
