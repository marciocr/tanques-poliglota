#!/usr/bin/env bash
# Compila o Tanques em Object Pascal com o Free Pascal Compiler.
# Uso: ./build.sh          -> gera build/tanques
#      ./build.sh clean    -> remove build/
set -euo pipefail
cd "$(dirname "$0")"

if [[ "${1:-}" == "clean" ]]; then
  rm -rf build
  exit 0
fi

mkdir -p build
fpc -O2 -Xs -vew -FUbuild -obuild/tanques tanques.pas
echo "ok: build/tanques"
