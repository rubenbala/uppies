#!/bin/sh
# Installs Uppies for this user, from the folder this script is in:
#
#   ./install.sh               the app into ~/.local/lib/uppies, `uppies` on the
#                              PATH (~/.local/bin), and Uppies in the desktop's
#                              application menu
#   ./install.sh --uninstall   removes all of that again; your data
#                              (~/.local/share/uppies) is left alone
#
# Nothing needs root. build.jai copies this script into the release tarball.

set -eu

APP_ID=au.net.ruben.uppies
DATA_HOME=${XDG_DATA_HOME:-$HOME/.local/share}
case $DATA_HOME in /*) ;; *) DATA_HOME=$HOME/.local/share ;; esac
LIB_DIR=$HOME/.local/lib/uppies
BIN_DIR=$HOME/.local/bin
DESKTOP_FILE=$DATA_HOME/applications/$APP_ID.desktop
ICON_DIR=$DATA_HOME/icons/hicolor
SOURCE=$(cd "$(dirname "$0")" && pwd)

refresh_menus() {
    # Desktops that cache their menus and icons look again; harmless where
    # these tools aren't installed.
    command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database -q "$DATA_HOME/applications" || true
    command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -q -t "$ICON_DIR" || true
}

if [ "${1:-}" = "--uninstall" ]; then
    rm -rf "$LIB_DIR"
    [ -L "$BIN_DIR/uppies" ] && rm -f "$BIN_DIR/uppies"
    rm -f "$DESKTOP_FILE"
    for icon in "$ICON_DIR"/*/apps/$APP_ID.png; do rm -f "$icon"; done
    refresh_menus
    echo "Uppies is uninstalled. Your data is still in $DATA_HOME/uppies; delete that folder to remove it too."
    exit 0
fi

if [ ! -x "$SOURCE/uppies" ]; then
    echo "install.sh: run it from the folder it came in, beside the uppies executable." >&2
    exit 1
fi

# The executable and what it reads (data/ beside it), replacing an earlier
# version.
rm -rf "$LIB_DIR"
mkdir -p "$LIB_DIR" "$BIN_DIR"
cp "$SOURCE/uppies" "$LIB_DIR/uppies"
chmod 755 "$LIB_DIR/uppies"
[ -d "$SOURCE/data" ] && cp -R "$SOURCE/data" "$LIB_DIR/data"
for file in LICENSE THIRD_PARTY.md FTL.TXT; do
    [ -f "$SOURCE/$file" ] && cp "$SOURCE/$file" "$LIB_DIR/$file"
done
ln -sf "$LIB_DIR/uppies" "$BIN_DIR/uppies"

# The icon at every size, and the menu entry. StartupWMClass is the
# window's WM_CLASS, so the window and its launcher are known to be one app.
for dir in "$SOURCE"/icons/hicolor/*; do
    size=$(basename "$dir")
    mkdir -p "$ICON_DIR/$size/apps"
    cp "$dir/apps/$APP_ID.png" "$ICON_DIR/$size/apps/$APP_ID.png"
done
mkdir -p "$(dirname "$DESKTOP_FILE")"
cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Type=Application
Name=Uppies
GenericName=Banking
Comment=A desktop app for your Up bank accounts
Exec=$LIB_DIR/uppies
Icon=$APP_ID
Terminal=false
Categories=Office;Finance;
Keywords=Up;bank;money;transactions;budget;
StartupNotify=true
StartupWMClass=Uppies
EOF
refresh_menus

echo "Uppies is installed: open it from your applications menu, or run uppies."
case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) echo "($BIN_DIR is not on your PATH, so the menu or $LIB_DIR/uppies it is.)" ;;
esac
