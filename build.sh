#!/bin/bash
# ./build.sh        test, build, sign, install to ~/Applications and (re)start
# ./build.sh test   run the model tests only
set -euo pipefail
cd "$(dirname "$0")"

LABEL=local.windowbar
DOMAIN="gui/$(id -u)"
APP=build/WindowBar.app
INSTALLED="$HOME/Applications/WindowBar.app"
KEYCHAIN="$HOME/Library/Keychains/windowbar-signing.keychain-db"
IDENTITY="WindowBar Local Signing"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
SWIFTC=(xcrun swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos14")

xcrun --find swiftc >/dev/null 2>&1 || { echo "Install the Xcode Command Line Tools first: xcode-select --install"; exit 1; }

mkdir -p build
"${SWIFTC[@]}" -parse-as-library Sources/Model.swift Tests/ModelTests.swift -o build/model-tests
build/model-tests
[ "${1:-}" = test ] && exit 0

[ -f "$KEYCHAIN" ] || ./setup-signing.sh
security unlock-keychain -p "$(security find-generic-password -s windowbar-signing-keychain -w)" "$KEYCHAIN"
security find-identity -p codesigning "$KEYCHAIN" | grep "$IDENTITY" >/dev/null || { echo "Signing identity \"$IDENTITY\" missing"; exit 1; }

rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/"
"${SWIFTC[@]}" Sources/*.swift -o "$APP/Contents/MacOS/WindowBar"

# codesign only finds identities in keychains on the user's search list, so ours is added just for signing
SEARCH_LIST=()
restore_search_list() {
  security list-keychains -d user -s ${SEARCH_LIST[@]+"${SEARCH_LIST[@]}"} || echo "Could not restore the keychain search list: ${SEARCH_LIST[*]-}"
}
sign_app() {
  local listing line k rc=0 quoted='^[[:space:]]*"(.*)"[[:space:]]*$'
  listing=$(security list-keychains -d user) || return 1
  while IFS= read -r line; do
    if [[ $line =~ $quoted ]]; then SEARCH_LIST+=("${BASH_REMATCH[1]}"); fi
  done <<< "$listing"
  for k in ${SEARCH_LIST[@]+"${SEARCH_LIST[@]}"}; do
    if [ "$k" = "$KEYCHAIN" ]; then
      codesign --force --sign "$IDENTITY" --keychain "$KEYCHAIN" "$APP"
      return
    fi
  done
  trap restore_search_list EXIT
  trap 'exit 130' INT TERM HUP
  security list-keychains -d user -s ${SEARCH_LIST[@]+"${SEARCH_LIST[@]}"} "$KEYCHAIN" || rc=$?
  if [ $rc -eq 0 ]; then codesign --force --sign "$IDENTITY" --keychain "$KEYCHAIN" "$APP" || rc=$?; fi
  trap - EXIT INT TERM HUP
  restore_search_list
  return $rc
}
sign_app || { echo "Signing failed"; exit 1; }
codesign --verify --strict "$APP"
# The Accessibility permission is tied to this requirement: it must name our certificate, not a per-build hash
codesign -d -r- "$APP" 2>&1 | grep -E 'certificate (root|leaf) = H"' >/dev/null || { echo "Unexpected designated requirement"; exit 1; }

stop_agent() {
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  for _ in $(seq 50); do
    launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || return 0
    sleep 0.1
  done
  echo "WindowBar did not stop"
  return 1
}

start_agent() {
  sed "s|__APP__|$INSTALLED|" $LABEL.plist > "$AGENT" || return 1
  launchctl bootstrap "$DOMAIN" "$AGENT" || return 1
  sleep 1
  launchctl print "$DOMAIN/$LABEL" | grep "state = running" >/dev/null
}

# Stage the complete copy first: a full disk or failed copy leaves the running version untouched
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"
rm -rf "$INSTALLED.new" "$INSTALLED.previous"
cp -R "$APP" "$INSTALLED.new"
codesign --verify --strict "$INSTALLED.new"

# From here on every step is checked, and a failure undoes exactly the steps that already happened
backed_up=false
replaced=false
rollback() {
  echo "Install failed, rolling back"
  stop_agent || true
  if $replaced; then rm -rf "$INSTALLED"; fi
  if $backed_up; then mv "$INSTALLED.previous" "$INSTALLED" || echo "Could not restore $INSTALLED.previous"; fi
  rm -rf "$INSTALLED.new"
  start_agent || echo "The previous version did not start either"
  exit 1
}

stop_agent || rollback
if [ -d "$INSTALLED" ]; then
  mv "$INSTALLED" "$INSTALLED.previous" || rollback
  backed_up=true
fi
mv "$INSTALLED.new" "$INSTALLED" || rollback
replaced=true
start_agent || rollback
rm -rf "$INSTALLED.previous"
echo "WindowBar installed and running"
