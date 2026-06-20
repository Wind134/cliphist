pkgname=cliphist
pkgver=1.0.0
pkgrel=2
pkgdesc="Clipboard history manager with per-item paste injection"
arch=('x86_64')
url="https://github.com/ping/cliphist"
license=('MIT')
depends=('webkit2gtk-4.1' 'gtk3' 'libsoup3' 'libappindicator-gtk3')
makedepends=('cargo' 'npm')
conflicts=('cliphist-bin')

build() {
  cd "$srcdir/cliphist"
  npm install
  cargo build --release --manifest-path src-tauri/Cargo.toml
}

package() {
  cd "$srcdir/cliphist"
  install -Dm755 src-tauri/target/release/tauri-app "$pkgdir/usr/bin/cliphist"
  install -Dm644 src-tauri/icons/128x128.png "$pkgdir/usr/share/icons/hicolor/128x128/apps/cliphist.png"
  install -Dm644 src-tauri/icons/48x48.png "$pkgdir/usr/share/icons/hicolor/48x48/apps/cliphist.png"
  install -Dm644 src-tauri/icons/32x32.png "$pkgdir/usr/share/icons/hicolor/32x32/apps/cliphist.png"
  install -Dm644 src-tauri/com.ping.cliphist.policy "$pkgdir/usr/share/polkit-1/actions/com.ping.cliphist.policy"
  install -Dm644 /dev/stdin "$pkgdir/usr/share/applications/cliphist.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=ClipHist
Comment=Clipboard history manager
Exec=/usr/bin/cliphist
Icon=cliphist
Categories=Utility;
Terminal=false
DESKTOP
}
