#!/bin/bash

set -eu

DATE_FORMAT="%Y-%m-%d %H:%M:%S"

fetch_tags() {
  # https://docs.github.com/ja/rest/git/refs?apiVersion=2022-11-28
  curl \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${repo_token}" \
    -H "X-GitHub-Api-Version: 2022-11-28" https://api.github.com/repos/nim-lang/nim/git/refs/tags |
    jq -r '.[].ref' |
    sed -E 's:^refs/tags/v::'
}

fetch_nightlies_releases() {
  # https://docs.github.com/en/rest/releases/releases?apiVersion=2022-11-28
  curl -sSL \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${repo_token}" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    https://api.github.com/repos/nim-lang/nightlies/releases
}

filter_latest_devel_assets() {
  jq -r '.[] | select(.tag_name | test("latest-devel")) | .assets' "$1"
}

filter_os_asset() {
  jq --arg target "$1" -r '.[] | select(.name | test($target))' "$2"
}

info() {
  echo "$(date +"$DATE_FORMAT") [INFO] $*"
}

err() {
  echo "$(date +"$DATE_FORMAT") [ERR] $*"
}

tag_regexp() {
  version=$1
  echo "$version" |
    sed -E \
      -e 's/\./\\./g' \
      -e 's/^/^/' \
      -e 's/x$//'
}

latest_version() {
  sort -V | tail -n 1
}

move_nim_compiler() {
  src_dir="$1"
  dst_dir="$2"
  if [[ -d "$dst_dir" ]]; then
    info "remove cached directory (path = $dst_dir)"
    rm -rf "$dst_dir"
  fi
  mv "$src_dir" "$dst_dir"
}

# parse commandline args
nim_version="stable"
nim_install_dir=".nim_runtime"
os="Linux"
repo_token=""
parent_nim_install_dir=""
use_nightlies="false"
while ((0 < $#)); do
  opt=$1
  shift
  case $opt in
    --nim-version)
      nim_version=$1
      ;;
    --nim-install-directory)
      nim_install_dir=$1
      ;;
    --parent-nim-install-directory)
      parent_nim_install_dir=$1
      ;;
    --os)
      os=$1
      ;;
    --repo-token)
      repo_token=$1
      ;;
    --use-nightlies)
      use_nightlies=$1
      ;;
  esac
done

if [[ "$parent_nim_install_dir" = "" ]]; then
  parent_nim_install_dir="$PWD"
fi

cd "$parent_nim_install_dir"

# build nim compiler for devel branch
if [[ "$nim_version" = "devel" ]]; then
  if [[ "$os" = Windows ]]; then
    err "'devel' version and windows runner are not supported yet"
    exit 1
  fi

  if [[ "$use_nightlies" = true ]]; then
    target="linux_x64"
    if [[ "$os" = macOS ]]; then
      target="macosx_x64"
    fi

    work_dir="/tmp/setup_nim_action_work"
    mkdir -p "$work_dir"
    pushd "$work_dir"

    fetch_nightlies_releases > releases.json
    filter_latest_devel_assets releases.json > assets.json
    filter_os_asset "$target" assets.json > os_asset.json
    asset_name="$(jq -r '.name' os_asset.json)"
    browser_download_url="$(jq -r '.browser_download_url' os_asset.json)"
    info "download nightlies build: asset_name = $asset_name, browser_download_url = $browser_download_url"
    # asset_name ex: linux_x64.tar.xz
    curl -sSL "$browser_download_url" > "$asset_name"
    mkdir -p outfiles
    tar xf "$asset_name" -C outfiles --strip-components=1
    rm -f "$asset_name"

    popd
    move_nim_compiler "${work_dir}/outfiles" "${nim_install_dir}"
    rm -rf "$work_dir"
  else
    git clone -b devel --depth 1 https://github.com/nim-lang/Nim
    cd Nim
    info "build nim compiler (devel)"
    ./build_all.sh
    cd ..
    move_nim_compiler Nim "${nim_install_dir}"
  fi

  exit
fi

# get exact version of stable
if [[ "$nim_version" = "stable" ]]; then
  nim_version=$(curl -sSL https://nim-lang.org/channels/stable)
elif [[ "$nim_version" =~ ^[0-9]+\.[0-9]+\.x$ ]] || [[ "$nim_version" =~ ^[0-9]+\.x$ ]]; then
  nim_version="$(fetch_tags | grep -E "$(tag_regexp "$nim_version")" | latest_version)"
fi

info "install nim $nim_version"

# download nim compiler
arch="x64"
if [[ "$os" = Windows ]]; then
  download_url="https://nim-lang.org/download/nim-${nim_version}_${arch}.zip"
  curl -sSL "${download_url}" > nim.zip
  unzip -q nim.zip
  rm -f nim.zip
elif [[ "$os" = "Linux" && "$HOSTTYPE" = "x86_64" ]]; then
  download_url="https://nim-lang.org/download/nim-${nim_version}-linux_${arch}.tar.xz"
  curl -sSL "${download_url}" > nim.tar.xz
  tar xf nim.tar.xz
  rm -f nim.tar.xz

elif [[ "$os" = "macOS" ]]; then
  if ! command -v brew >/dev/null 2>&1; then
    err "Homebrew not found. Please install Homebrew first."
    exit 1
  fi

  # Try to install a specific version if available, else fallback to latest
  if brew search nim@"$nim_version" | grep -q "nim@$nim_version"; then
    info "Installing Nim version $nim_version via Homebrew"
    brew install nim@"$nim_version"
    brew link --force --overwrite nim@"$nim_version"
    nim_bin="/usr/local/opt/nim@${nim_version}/bin/nim"
    nimble_bin="/usr/local/opt/nim@${nim_version}/bin/nimble"
  else
    info "Installing latest Nim via Homebrew (requested $nim_version not found as a versioned formula)"
    brew install nim
    nim_bin="$(command -v nim)"
    nimble_bin="$(command -v nimble)"
  fi

  installed_version="$($nim_bin --version | awk '/Version/{print $3; exit}')"
  info "Using Nim from Homebrew: $installed_version"

  mkdir -p "${nim_install_dir}/bin"
  ln -sfn "$nim_bin" "${nim_install_dir}/bin/nim"
  [[ -x "$nimble_bin" ]] && ln -sfn "$nimble_bin" "${nim_install_dir}/bin/nimble"
  [[ -x "/usr/local/bin/nimgrep" ]] && ln -sfn "/usr/local/bin/nimgrep" "${nim_install_dir}/bin/nimgrep"
  exit
fi
move_nim_compiler "nim-${nim_version}" "${nim_install_dir}"
