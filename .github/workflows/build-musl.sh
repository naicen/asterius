#!/bin/sh

set -eu

echo "http://dl-cdn.alpinelinux.org/alpine/edge/testing" >> /etc/apk/repositories
apk update --no-progress
apk upgrade --no-progress
apk add --no-progress \
  alpine-sdk \
  autoconf \
  automake \
  bash \
  binutils-gold \
  bzip2 \
  coreutils \
  curl \
  file \
  findutils \
  g++ \
  gawk \
  git \
  gmp-dev \
  grep \
  gzip \
  libffi-dev \
  libtool \
  musl-dev \
  ncurses-dev \
  openssh \
  patch \
  perl \
  py3-sphinx \
  sed \
  tar \
  xz \
  zlib-dev
ln -s /usr/lib/libncursesw.so.6 /usr/lib/libtinfow.so.6

mkdir -p ~/.local/bin
curl -L https://github.com/commercialhaskell/stack/releases/download/v2.3.1/stack-2.3.1-linux-x86_64-bin -o ~/.local/bin/stack
chmod +x ~/.local/bin/stack
mkdir ~/.stack
echo "ghc-build: musl" > ~/.stack/config.yaml
~/.local/bin/stack --resolver nightly-2020-06-20 install \
  alex \
  happy \
  hscolour

cd /tmp
git clone --recurse-submodules --branch $BRANCH https://github.com/TerrorJack/ghc.git
cd /asterius

export PATH=~/.local/bin:$PATH
mv .github/workflows/build-linux.mk /tmp/ghc/mk/build.mk
cd /tmp/ghc
./boot
./configure --disable-ld-override
make
make binary-dist
mkdir ghc-bindist
mv *.tar.* ghc-bindist/
(ls -l ghc-bindist && sha256sum -b ghc-bindist/*) > ghc-bindist/sha256.txt
cd /asterius

mv /tmp/ghc/ghc-bindist .
