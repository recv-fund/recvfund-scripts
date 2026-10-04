#!/usr/bin/env bash
# Exits 0 only if ghcr.io/recv-fund/recvfund-{api,web}:<tag> can be fetched
# without credentials, for both linux/amd64 and linux/arm64. The release
# workflow runs this before publishing an installer that pins <tag>.
set -euo pipefail
tag="${1:?usage: published-images.sh <image tag>}"
for app in api web; do
  repo="recv-fund/recvfund-$app"
  token="$(curl -fsS "https://ghcr.io/token?scope=repository:$repo:pull" | sed -E 's/.*"token":"([^"]+)".*/\1/')"
  index="$(curl -fsS -H "Authorization: Bearer $token" \
    -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json' \
    "https://ghcr.io/v2/$repo/manifests/$tag")" \
    || { printf 'ghcr.io/%s:%s cannot be pulled without credentials\n' "$repo" "$tag" >&2; exit 1; }
  for arch in amd64 arm64; do
    grep -q "\"architecture\":\"$arch\"" <<<"${index// /}" \
      || { printf 'ghcr.io/%s:%s has no linux/%s image\n' "$repo" "$tag" "$arch" >&2; exit 1; }
  done
  printf 'ghcr.io/%s:%s is public for linux/amd64 and linux/arm64\n' "$repo" "$tag"
done
