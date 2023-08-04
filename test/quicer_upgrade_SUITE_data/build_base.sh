#!/usr/bin/env sh
TAG=${1:-0.0.114}

script_dir=$(cd $(dirname $0); pwd)

cd "$script_dir"

if [ ! -d "${script_dir}/quic-${TAG}" ];
then
    wget https://github.com/emqx/quic/archive/refs/tags/${TAG}.tar.gz
    tar zxvf $TAG.tar.gz
fi
cd "quic-$TAG"
make
