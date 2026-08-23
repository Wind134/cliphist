# Maintainer: Ping <ping@users.noreply.github.com>
# Builds the Flutter + Rust-core stack (post-migration).
# Layout mirrors the fastforge deb: the app bundle lives in /opt/cliphist/
# with a /usr/bin/cliphist symlink, and the privileged evdev helper sits next
# to it (the polkit policy authorizes exactly that path).

pkgname=cliphist
pkgver=2.0.10
pkgrel=2
pkgdesc="Wayland clipboard history manager with per-item paste injection (Flutter + Rust core)"
arch=('x86_64')
url="https://github.com/Wind134/cliphist"
license=('MIT')
depends=('gtk3' 'libayatana-appindicator' 'libevdev' 'polkit' 'wayland' 'systemd-libs')
makedepends=('cargo' 'flutter' 'cmake' 'ninja' 'clang' 'pkgconf' 'libevdev' 'systemd-libs')
options=('!lto')
conflicts=('cliphist-bin')
source=("${pkgname}-${pkgver}.tar.gz::${url}/archive/refs/tags/v${pkgver}.tar.gz")
sha256sums=('e08d443a6770faeb8c6b5eb393f2c533d94713caebf79bd77edcaf7573cf2519')

build() {
  cd "$srcdir/cliphist-${pkgver}"
  # 1. Privileged evdev helper (standalone binary, plan 3.1).
  cargo build --release --locked --manifest-path rust/evdev-helper/Cargo.toml
  # 2. Flutter app (FRB crate builds via Cargokit inside `flutter build`).
  cd flutter
  flutter build linux --release
}

check() {
  local rustlib="$srcdir/cliphist-${pkgver}/flutter/build/linux/x64/release/bundle/lib/librust_lib_cliphist.so"

  # dart-sys compiles dart_api_dl.c into the Rust cdylib. Arch's global C LTO
  # can silently leave these symbols unresolved, which only fails at runtime.
  if readelf --dyn-syms --wide "$rustlib" | grep -q 'UND.*Dart_'; then
    echo "error: unresolved Dart API DL symbols in $rustlib" >&2
    return 1
  fi
  readelf --syms --wide "$rustlib" | grep -q 'Dart_InitializeApiDL'
  readelf --syms --wide "$rustlib" | grep -q 'Dart_CurrentIsolate_DL'
}

package() {
  cd "$srcdir/cliphist-${pkgver}"
  local bindir="$pkgdir/opt/cliphist"
  install -d "$bindir"

  # Flutter release bundle (app binary + lib/ + data/).
  cp -a flutter/build/linux/x64/release/bundle/. "$bindir/"

  # Privileged evdev helper next to the main binary, plus its polkit policy.
  install -Dm755 rust/evdev-helper/target/release/cliphist-evdev-helper \
    "$bindir/cliphist-evdev-helper"
  install -Dm644 flutter/assets/polkit/com.ping.cliphist.policy \
    "$pkgdir/usr/share/polkit-1/actions/com.ping.cliphist.policy"

  # PATH entry.
  install -d "$pkgdir/usr/bin"
  ln -s /opt/cliphist/cliphist "$pkgdir/usr/bin/cliphist"

  # Icons.
  install -Dm644 flutter/assets/icon/app.png \
    "$pkgdir/usr/share/icons/hicolor/512x512/apps/cliphist.png"
  install -Dm644 flutter/assets/icon/icon.png \
    "$pkgdir/usr/share/icons/hicolor/32x32/apps/cliphist.png"

  # Desktop entry.
  install -Dm644 /dev/stdin "$pkgdir/usr/share/applications/cliphist.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=ClipHist
Comment=Clipboard history manager
Exec=/usr/bin/cliphist
Icon=cliphist
Categories=Utility;
Terminal=false
StartupNotify=true
DESKTOP
}
