#!/usr/bin/env bash
# Build and push linux/amd64 test packages for the GCP provider family and its
# monitoring member. This intentionally follows provider-pagerduty's Artifact
# Registry path: build a runtime Docker archive, embed it directly in an xpkg,
# then push. It does not use `crossplane xpkg batch` or Docker's local image
# store, which avoids Docker Desktop containerd snapshot failures.
#
# Usage:
#   ./scripts/build-push-family-gcp-monitoring.sh [version]
set -euo pipefail

readonly registry="us-central1-docker.pkg.dev/bcs-gda-devplatform-ops/crossplane-provider"
readonly family_package="${registry}/provider-family-gcp"
readonly monitoring_package="${registry}/provider-gcp-monitoring"
readonly platform="linux_amd64"
readonly image_platform="linux/amd64"
readonly repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ $# -gt 1 ]]; then
  echo "usage: $0 [version]" >&2
  exit 2
fi
version="${1:-v0.0.0-$(git -C "${repo_root}" rev-parse --short HEAD).$(date -u +%Y%m%d%H%M%S)}"

for command in gcloud docker crossplane make; do
  command -v "${command}" >/dev/null || {
    echo "required command not found: ${command}" >&2
    exit 1
  }
done
docker info >/dev/null 2>&1 || { echo "Docker daemon is not running" >&2; exit 1; }

cd "${repo_root}"

if [[ -n "${CORPORATE_CA_BUNDLE:-}" ]]; then
  ca_bundle="${CORPORATE_CA_BUNDLE}"
else
  ca_bundle="${CA_BUNDLE_PATH:-}"
fi
if [[ -n "${ca_bundle}" && ! -s "${ca_bundle}" ]]; then
  echo "corporate CA bundle is missing or empty: ${ca_bundle}" >&2
  exit 1
fi

echo "Authenticating Docker to Artifact Registry..."
gcloud auth configure-docker us-central1-docker.pkg.dev --quiet

echo "Building linux/amd64 config and monitoring binaries..."
make build.code.platform PLATFORM="${platform}" PROVIDERS="config monitoring"

work_dir="$(mktemp -d)"
trap 'rm -rf "${work_dir}"' EXIT

build_runtime_tar() {
  local service="$1"
  local binary="${repo_root}/_output/bin/${platform}/${service}"
  local context="${work_dir}/${service}-runtime"
  local tarball="${work_dir}/${service}-runtime.tar"

  [[ -x "${binary}" ]] || { echo "missing provider binary: ${binary}" >&2; exit 1; }
  mkdir -p "${context}"
  cp "${binary}" "${context}/provider"
  if [[ -n "${ca_bundle}" ]]; then
    cp "${ca_bundle}" "${context}/corporate-ca.pem"
  else
    : > "${context}/corporate-ca.pem"
  fi
  cat > "${context}/Dockerfile" <<'EOF'
FROM alpine:3.23.4
COPY corporate-ca.pem /usr/local/share/ca-certificates/corporate-ca.crt
RUN if [ -s /usr/local/share/ca-certificates/corporate-ca.crt ]; then \
      cat /usr/local/share/ca-certificates/corporate-ca.crt >> /etc/ssl/cert.pem; \
    fi && \
    apk --no-cache add ca-certificates bash && \
    update-ca-certificates
COPY provider /usr/local/bin/provider
RUN chmod 0755 /usr/local/bin/provider
ENV USER_ID=65532
USER ${USER_ID}
EXPOSE 8080
ENTRYPOINT ["provider"]
EOF

  docker buildx build \
    --platform "${image_platform}" \
    --output "type=docker,dest=${tarball}" \
    "${context}" >&2 || return
  printf '%s\n' "${tarball}"
}

build_xpkg() {
  local service="$1"
  local package_name="$2"
  local runtime_tar="$3"
  local package_dir="${work_dir}/${service}-package"
  local package_file="${work_dir}/${package_name}-${version}.xpkg"

  mkdir -p "${package_dir}/crds" "${package_dir}/examples"

  if [[ "${service}" == "config" ]]; then
    cp package/crds/gcp.*providerconfig*.yaml "${package_dir}/crds/"
  else
    cp package/crds/monitoring.*.yaml "${package_dir}/crds/"
  fi

  cat > "${package_dir}/crossplane.yaml" <<EOF
apiVersion: meta.pkg.crossplane.io/v1
kind: Provider
metadata:
  name: ${package_name}
  labels:
    pkg.crossplane.io/provider-family: provider-family-gcp
spec:
  capabilities:
    - SafeStart
  crossplane:
    version: ">=v1.12.1-0"
EOF
  if [[ "${service}" == "monitoring" ]]; then
    cat >> "${package_dir}/crossplane.yaml" <<EOF
  dependsOn:
    - provider: ${family_package}
      version: ">=v0.0.0-0"
EOF
  fi

  crossplane xpkg build \
    --embed-runtime-image-tarball "${runtime_tar}" \
    --package-root "${package_dir}" \
    --examples-root "${package_dir}/examples" \
    --package-file "${package_file}" >&2 || return
  printf '%s\n' "${package_file}"
}

echo "Building config runtime archive..."
config_tar="$(build_runtime_tar config)"
echo "Building monitoring runtime archive..."
monitoring_tar="$(build_runtime_tar monitoring)"

echo "Building ${family_package}:${version}..."
family_xpkg="$(build_xpkg config provider-family-gcp "${config_tar}")"
echo "Building ${monitoring_package}:${version}..."
monitoring_xpkg="$(build_xpkg monitoring provider-gcp-monitoring "${monitoring_tar}")"

echo "Pushing ${family_package}:${version}..."
crossplane xpkg push --package-files "${family_xpkg}" "${family_package}:${version}"
echo "Pushing ${monitoring_package}:${version}..."
crossplane xpkg push --package-files "${monitoring_xpkg}" "${monitoring_package}:${version}"

cat <<EOF
Pushed linux/amd64 packages:
  ${family_package}:${version}
  ${monitoring_package}:${version}
EOF
