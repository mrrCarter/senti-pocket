#!/usr/bin/env bash
set -euo pipefail
set +x

if [ "$#" -ne 2 ]; then
  echo "::error::Usage: require-secret.sh <SECRET_NAME> <SECRET_VALUE>"
  exit 1
fi

secret_name="$1"
secret_value="$2"

if [ -z "$(echo "${secret_name}" | xargs || true)" ]; then
  echo "::error::SECRET_NAME is required."
  exit 1
fi

if [ -n "${secret_value}" ]; then
  printf '::add-mask::%s\n' "${secret_value}"
fi

if [ -z "${secret_value}" ]; then
  echo "::error::required credential unavailable in this context (${secret_name})"
  exit 1
fi

