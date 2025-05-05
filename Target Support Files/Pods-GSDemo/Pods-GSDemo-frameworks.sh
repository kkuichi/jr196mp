#!/bin/sh
set -e
set -u
set -o pipefail

function on_error {
  echo "$(realpath -mq "${0}"):$1: error: Unexpected failure"
}
trap 'on_error $LINENO' ERR

if [ -z ${FRAMEWORKS_FOLDER_PATH+x} ]; then
  exit 0
fi

echo "Creating frameworks folder: ${CONFIGURATION_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}"
mkdir -p "${CONFIGURATION_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}"

COCOAPODS_PARALLEL_CODE_SIGN="${COCOAPODS_PARALLEL_CODE_SIGN:-false}"
SWIFT_STDLIB_PATH="${TOOLCHAIN_DIR}/usr/lib/swift/${PLATFORM_NAME}"
BCSYMBOLMAP_DIR="BCSymbolMaps"

install_framework() {
  local source=""
  if [ -r "${BUILT_PRODUCTS_DIR}/$1" ]; then
    source="${BUILT_PRODUCTS_DIR}/$1"
  elif [ -r "${BUILT_PRODUCTS_DIR}/$(basename "$1")" ]; then
    source="${BUILT_PRODUCTS_DIR}/$(basename "$1")"
  elif [ -r "$1" ]; then
    source="$1"
  else
    echo "Framework $1 not found!"
    return
  fi

  local destination="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}"

  if [ -L "${source}" ]; then
    echo "Resolving symlink..."
    source="$(readlink "${source}")"
  fi

  echo "Copying framework $source to $destination via ditto"
  ditto "$source" "$destination/$(basename "$source")"

  local basename
  basename="$(basename -s .framework "$1")"
  local binary="${destination}/${basename}.framework/${basename}"

  if ! [ -r "$binary" ]; then
    binary="${destination}/${basename}"
  elif [ -L "${binary}" ]; then
    binary="$(readlink "${binary}")"
  fi

  if [[ "$(file "$binary")" == *"dynamically linked shared library"* ]]; then
    strip_invalid_archs "$binary"
  fi

  code_sign_if_enabled "${destination}/$(basename "$1")"
}

strip_invalid_archs() {
  binary="$1"
  binary_archs="$(lipo -info "$binary" | rev | cut -d ':' -f1 | awk '{$1=$1;print}' | rev)"
  intersected_archs="$(echo ${ARCHS[@]} ${binary_archs[@]} | tr ' ' '\n' | sort | uniq -d)"

  if [[ -z "$intersected_archs" ]]; then
    echo "warning: No valid architectures in $binary (has $binary_archs, needs ${ARCHS})"
    return
  fi

  stripped=""
  for arch in $binary_archs; do
    if ! [[ "${ARCHS}" == *"$arch"* ]]; then
      lipo -remove "$arch" -output "$binary" "$binary"
      stripped="$stripped $arch"
    fi
  done
  if [[ "$stripped" ]]; then
    echo "Stripped $binary of architectures:$stripped"
  fi
}

code_sign_if_enabled() {
  if [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ] && [ "${CODE_SIGNING_REQUIRED:-}" != "NO" ] && [ "${CODE_SIGNING_ALLOWED}" != "NO" ]; then
    echo "Code Signing $1 with Identity ${EXPANDED_CODE_SIGN_IDENTITY_NAME}"
    /usr/bin/codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY}" "${OTHER_CODE_SIGN_FLAGS:-}" --preserve-metadata=identifier,entitlements "$1"
  fi
}

# ✅ DJI SDK only on real device
if [[ "$PLATFORM_NAME" == "iphoneos" ]]; then
  install_framework "${PODS_ROOT}/DJI-SDK-iOS/iOS_Mobile_SDK/DJISDK.framework"
else
  echo "Skipping DJISDK.framework for simulator build"
fi

if [ "${COCOAPODS_PARALLEL_CODE_SIGN}" == "true" ]; then
  wait
fi
