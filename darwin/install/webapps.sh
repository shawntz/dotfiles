#!/usr/bin/env zsh

# Create a Chrome-like desktop app from a website using Nativefier
# Usage: install_webapp "My App" "https://example.com" "https://example.com/icon.png"
install_webapp() {
  local name="$1" url="$2" icon_url="$3"
  if [[ -z "$name" || -z "$url" || -z "$icon_url" ]]; then
    echo "Usage: install_webapp <Name> <URL> <icon_png_url>" >&2
    return 2
  fi

  # Dependencies
  for cmd in curl magick iconutil; do
    command -v "$cmd" >/dev/null 2>&1 || {
      echo "Missing dependency: $cmd (try: brew install imagemagick)" >&2
      return 1
    }
  done
  if ! command -v nativefier >/dev/null 2>&1; then
    if command -v brew >/dev/null 2>&1; then
      brew install nativefier || {
        command -v npm >/dev/null 2>&1 || { echo "Need Node/npm or Homebrew" >&2; return 1; }
        npm install -g nativefier || return 1
      }
    else
      echo "Install Homebrew or run: npm install -g nativefier" >&2
      return 1
    fi
  fi

  # Temp workspace (auto-clean)
  local tmp base_out outdir app_path
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/webapp.XXXXXXXX")" || { echo "mktemp failed" >&2; return 1; }
  trap 'rm -rf "$tmp"' EXIT

  echo "Working in temp: $tmp"

  # 1) Download icon and determine format
  local icon_src="$tmp/icon_src"
  echo "Downloading icon..."
  curl -fsSL "$icon_url" -o "$icon_src" || { echo "Icon download failed" >&2; return 1; }
  
  # Detect if it's ICNS or other format
  local icon_format
  icon_format="$(file -b --mime-type "$icon_src")"
  
  local icon_png="$tmp/icon_src.png"
  if [[ "$icon_format" == "image/x-icns" ]] || [[ "$icon_url" == *.icns ]]; then
    # Convert ICNS to PNG using macOS sips command
    echo "Converting ICNS to PNG..."
    sips -s format png "$icon_src" --out "$icon_png" || { echo "ICNS conversion failed" >&2; return 1; }
  else
    # Just rename/copy if it's already a supported format
    mv "$icon_src" "$icon_png"
  fi

  # 2) Preserve aspect ratio: contain to 1024, pad to square (transparent)
  local square="$tmp/icon.square.png"
  magick "$icon_png" -alpha on -background none -strip \
          -resize 1024x1024 \
          -gravity center -extent 1024x1024 \
          "$square" || { echo "Image conversion failed" >&2; return 1; }

  # 3) Build .iconset and .icns
  local iconset="$tmp/icon.iconset"; mkdir -p "$iconset"
  for s in 16 32 128 256 512; do
    magick "$square" -resize ${s}x${s}          "$iconset/icon_${s}x${s}.png"
    magick "$square" -resize $((s*2))x$((s*2))  "$iconset/icon_${s}x${s}@2x.png"
  done
  local icns="$tmp/icon.icns"
  iconutil -c icns "$iconset" -o "$icns" || { echo "iconutil failed" >&2; return 1; }

  # 4) Nativefier build (force CWD to tmp so artifacts never hit your repo)
  base_out="$tmp/build"
  outdir="$base_out"
  mkdir -p "$outdir"

  echo "Building app with Nativefier..."
  (
    cd "$tmp" || exit 1
    # Use positional destination to avoid --out ordering quirks; URL last
    nativefier \
      "$url" "$outdir" \
      --name "$name" \
      --icon "$icns" \
      --single-instance \
      --disable-dev-tools \
      --hide-window-frame \
      --title-bar-style 'hiddenInset' \
      --counter \
      --darwin-dark-mode-support \
      --fast-quit \
      --platform mac \
      --arch "$(uname -m)"
  ) || { echo "nativefier build failed" >&2; return 1; }

  # 5) Locate .app produced by Nativefier
  app_path="$(find "$outdir" -maxdepth 2 -type d -name "*.app" -print -quit)"
  # Fallback: if Nativefier ignored the dest, it will have created "${name}-darwin-*/${name}.app" in $tmp
  [[ -n "$app_path" ]] || app_path="$(find "$tmp" -maxdepth 2 -type d -name "${name}-darwin-*" \
                               -exec find {} -maxdepth 1 -type d -name "*.app" -print \; -quit)"

  if [[ -z "$app_path" ]]; then
    echo "Build succeeded, but .app not found (check Nativefier output)" >&2
    return 1
  fi

  # 6) Install to /Applications or ~/Applications
  local target_system="/Applications/${name}.app"
  local target_user="$HOME/Applications/${name}.app"
  mkdir -p "$HOME/Applications"

  if [[ -w "/Applications" ]]; then
    rm -rf "$target_system"
    mv "$app_path" "$target_system"
    echo "Installed: $target_system"
  else
    rm -rf "$target_user"
    mv "$app_path" "$target_user"
    echo "Installed: $target_user"
  fi

  echo "Launch with: open -a \"$name\""
  # tmp is wiped on function exit
}

# Make brew available in this shell
if [[ -d /opt/homebrew/bin ]]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
elif [[ -d /usr/local/bin ]]; then
  eval "$(/usr/local/bin/brew shellenv)"
fi

# Install webapps
# https://macosicons.com/
# install_webapp "Figma" "https://www.figma.com" "https://cdn.jim-nielsen.com/macos/1024/figma-2021-05-05.png?rf=1024"
install_webapp "GitHub" "https://github.com/shawntz?tab=repositories" "https://github.com/shawntz/dotfiles/raw/refs/heads/master/darwin/install/icns/GitHub.icns"
install_webapp "Gmail" "https://mail.google.com" "https://github.com/shawntz/dotfiles/raw/refs/heads/master/darwin/install/icns/Gmail.icns"
install_webapp "Compose" "https://mail.google.com/mail/?view=cm&fs=1" "https://github.com/shawntz/dotfiles/raw/refs/heads/master/darwin/install/icns/Compose.icns"
install_webapp "Google Calendar" "https://calendar.google.com" "https://github.com/shawntz/dotfiles/raw/refs/heads/master/darwin/install/icns/Calendar.icns"
install_webapp "Google Tasks" "https://tasks.google.com" "https://github.com/shawntz/dotfiles/raw/refs/heads/master/darwin/install/icns/Clear.icns"
install_webapp "Google Contacts" "https://contacts.google.com" "https://github.com/shawntz/dotfiles/raw/refs/heads/master/darwin/install/icns/Contacts.icns"
install_webapp "Drive" "https://drive.google.com" "https://github.com/shawntz/dotfiles/raw/refs/heads/master/darwin/install/icns/Drive.icns"
install_webapp "Gemini" "https://gemini.google.com" "https://github.com/shawntz/dotfiles/raw/refs/heads/master/darwin/install/icns/Gemini.icns"
install_webapp "Google Keep" "https://keep.google.com" "https://github.com/shawntz/dotfiles/raw/refs/heads/master/darwin/install/icns/Keep-alt.icns"
install_webapp "Google Meet" "https://meet.google.com" "https://github.com/shawntz/dotfiles/raw/refs/heads/master/darwin/install/icns/Meet.icns"
install_webapp "Google Messages" "https://messages.google.com/web/conversations" "https://github.com/shawntz/dotfiles/raw/refs/heads/master/darwin/install/icns/Messages.icns"
install_webapp "Google Photos" "https://photos.google.com" "https://github.com/shawntz/dotfiles/raw/refs/heads/master/darwin/install/icns/Photos.icns"
install_webapp "Google Docs" "https://docs.new" "https://github.com/shawntz/dotfiles/raw/refs/heads/master/darwin/install/icns/Docs.icns"
install_webapp "Google Sheets" "https://sheets.new" "https://github.com/shawntz/dotfiles/raw/refs/heads/master/darwin/install/icns/Sheets.icns"
install_webapp "Google Slides" "https://slides.new" "https://github.com/shawntz/dotfiles/raw/refs/heads/master/darwin/install/icns/Slides.icns"
install_webapp "YouTube" "https://youtube.com" "https://github.com/shawntz/dotfiles/raw/refs/heads/master/darwin/install/icns/YouTube.icns"
install_webapp "YouTube Music" "https://music.youtube.com" "https://github.com/shawntz/dotfiles/raw/refs/heads/master/darwin/install/icns/YouTubeMusic.icns"
install_webapp "Stanford Canvas" "https://canvas.stanford.edu" "https://github.com/shawntz/dotfiles/raw/refs/heads/master/darwin/install/icns/Canvas.icns"
install_webapp "Reddit" "https://reddit.com" "https://github.com/shawntz/dotfiles/raw/refs/heads/master/darwin/install/icns/Reddit.icns"
install_webapp "Paperpile" "https://app.paperpile.com" "https://github.com/shawntz/dotfiles/raw/refs/heads/master/darwin/install/icns/Paperpile.icns"
install_webapp "New York Times" "https://www.nytimes.com" "https://github.com/shawntz/dotfiles/raw/refs/heads/master/darwin/install/icns/NYTimes.icns"
install_webapp "Bluesky" "https://www.bsky.app" "https://github.com/shawntz/dotfiles/raw/refs/heads/master/darwin/install/icns/Bluesky.icns"
install_webapp "Twitter" "https://www.x.com" "https://github.com/shawntz/dotfiles/raw/refs/heads/master/darwin/install/icns/Twitter.icns"

