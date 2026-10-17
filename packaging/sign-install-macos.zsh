#!/bin/zsh
set -euo pipefail

readonly expected_bundle_id="com.sharemouse.desktop"
readonly destination="${HOME}/Applications/ShareMouse.app"
readonly backup_root="${HOME}/Library/Application Support/ShareMouse/backups"

usage() {
  print -u2 -- "Usage: zsh $0 /path/to/ShareMouse-macos-universal.dmg"
  print -u2 -- "Or, when run from a mounted ShareMouse DMG, omit the argument."
}

if (( $# > 1 )); then
  usage
  exit 2
fi

script_dir=${0:A:h}
app_source="${script_dir}/ShareMouse.app"
work_root=""
mount_dir=""
mounted=0
incoming=""
backup_path=""
old_moved=0

cleanup() {
  local result=$?
  trap - EXIT INT TERM
  if (( mounted )); then
    hdiutil detach "$mount_dir" >/dev/null 2>&1 || true
  fi
  if [[ -n "$incoming" && ( -e "$incoming" || -L "$incoming" ) ]]; then
    /bin/rm -rf "$incoming"
  fi
  if [[ -n "$work_root" && -d "$work_root" ]]; then
    /bin/rm -rf "$work_root"
  fi
  if (( old_moved )) && [[ ! -e "$destination" && -e "$backup_path" ]]; then
    mv "$backup_path" "$destination" || print -u2 -- "Could not restore the previous app from: $backup_path"
  fi
  return $result
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ ! -d "$app_source" ]]; then
  if (( $# != 1 )) || [[ ! -f "$1" ]]; then
    usage
    exit 2
  fi
  work_root=$(mktemp -d "${TMPDIR:-/tmp}/sharemouse-sign-install.XXXXXX")
  mount_dir="$work_root/mount"
  mkdir -p "$mount_dir"
  hdiutil attach -readonly -nobrowse -mountpoint "$mount_dir" "$1"
  mounted=1
  app_source=$(find "$mount_dir" -maxdepth 4 -type d -name "ShareMouse.app" -print -quit)
fi

if [[ ! -d "$app_source" || ! -f "$app_source/Contents/Info.plist" ]]; then
  print -u2 -- "Could not find ShareMouse.app in the DMG."
  exit 1
fi

bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_source/Contents/Info.plist")
if [[ "$bundle_id" != "$expected_bundle_id" ]]; then
  print -u2 -- "Unexpected app bundle identifier: $bundle_id"
  exit 1
fi

identity_rows=$(security find-identity -v -p codesigning | \
  sed -nE 's/^[[:space:]]*([0-9]+)\) ([[:xdigit:]]{40}) "(Apple Development:[^"]+)".*$/\1|\2|\3/p')
identity_count=$(printf '%s\n' "$identity_rows" | awk 'NF { n++ } END { print n + 0 }')
if (( identity_count == 0 )); then
  print -u2 -- "No valid Apple Development signing identity was found in the keychain."
  print -u2 -- "In Xcode, open Settings > Accounts, sign in to your Apple Account, then Manage Certificates > + > Apple Development."
  print -u2 -- "Complete sign-in and any two-factor prompt in Xcode, then run this script again. Do not enter your Apple Account password in this script."
  exit 1
fi

if (( identity_count == 1 )); then
  identity_hash=$(printf '%s\n' "$identity_rows" | awk -F '|' 'NF == 3 { print $2; exit }')
else
  print -- "Multiple valid Apple Development identities are available:"
  printf '%s\n' "$identity_rows" | awk -F '|' 'NF == 3 { printf "  %s) %s\n", $1, $3 }'
  read "selected_number?Select the identity number to use: "
  identity_hash=$(printf '%s\n' "$identity_rows" | awk -F '|' -v choice="$selected_number" '$1 == choice { print $2; exit }')
  if [[ -z "$identity_hash" ]]; then
    print -u2 -- "No matching Apple Development identity was selected."
    exit 1
  fi
fi

if pgrep -x ShareMouse >/dev/null 2>&1; then
  print -u2 -- "Quit ShareMouse before installing the signed copy, then run this script again."
  exit 1
fi

mkdir -p "${HOME}/Applications" "$backup_root"
candidate="${HOME}/Applications/.ShareMouse.app.installing.$$"
if [[ -e "$candidate" || -L "$candidate" ]]; then
  print -u2 -- "Temporary install path already exists: $candidate"
  exit 1
fi
incoming="$candidate"

ditto "$app_source" "$incoming"
codesign --force --sign "$identity_hash" --timestamp=none "$incoming"
codesign --verify --deep --strict --verbose=2 "$incoming"

if [[ -e "$destination" || -L "$destination" ]]; then
  backup_path="$backup_root/ShareMouse-$(date '+%Y%m%d-%H%M%S')-$$.app"
  if [[ -e "$backup_path" || -L "$backup_path" ]]; then
    print -u2 -- "Backup path already exists: $backup_path"
    exit 1
  fi
  mv "$destination" "$backup_path"
  old_moved=1
fi

if ! mv "$incoming" "$destination"; then
  print -u2 -- "Could not move the signed app into $destination"
  exit 1
fi
incoming=""
old_moved=0

print -- "Installed and signed: $destination"
if [[ -n "$backup_path" ]]; then
  print -- "Previous per-user app saved at: $backup_path"
fi
print -- "This is an Apple Development signature for local use; it is not a Developer ID/notarized public release."
print -- "The script leaves Gatekeeper quarantine and Privacy & Security permissions unchanged."
print -- "Review Accessibility and Input Monitoring in System Settings for this signed app before using keyboard/mouse sharing."
print -- "If Gatekeeper blocks first launch, use System Settings > Privacy & Security to review the app warning; this script does not bypass it."

if ! open -n "$destination"; then
  print -u2 -- "The app was installed, but macOS did not launch it automatically."
fi
