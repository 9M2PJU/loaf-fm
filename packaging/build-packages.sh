#!/usr/bin/env bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$DIR/packaging/dist"
BIN="$DIR/target/debug/loaf"

if [ ! -f "$BIN" ]; then
    echo "Binary not found at $BIN"
    exit 1
fi

mkdir -p "$DIST"

echo "1. Staging standalone tarball..."
TAR_STAGE="$DIR/packaging/tarball/loaf-v0.2.0-linux-x86_64"
mkdir -p "$TAR_STAGE/bin" "$TAR_STAGE/share/applications" "$TAR_STAGE/share/icons"

cp "$BIN" "$TAR_STAGE/bin/loaf"
cp "$DIR/packaging/assets/loaf-run" "$TAR_STAGE/loaf"
cp "$DIR/packaging/assets/install.sh" "$TAR_STAGE/install.sh"
cp "$DIR/packaging/assets/uninstall.sh" "$TAR_STAGE/uninstall.sh"
cp "$DIR/packaging/assets/loaf.desktop" "$TAR_STAGE/share/applications/loaf.desktop"
cp -r "$DIR/packaging/assets/icons/hicolor" "$TAR_STAGE/share/icons/"

strip "$TAR_STAGE/bin/loaf"
# A binary built inside Nix points at the Nix store loader and libraries;
# switch to the standard ones so the packages run on other distributions.
patchelf --set-interpreter /lib64/ld-linux-x86-64.so.2 --remove-rpath "$TAR_STAGE/bin/loaf"
tar -czf "$DIST/loaf-v0.2.0-linux-x86_64.tar.gz" -C "$DIR/packaging/tarball" loaf-v0.2.0-linux-x86_64
cp "$TAR_STAGE/bin/loaf" "$DIST/loaf-v0.2.0-linux-x86_64"

echo "2. Building Debian package..."
DEB_STAGE="$DIR/packaging/deb/build/loaf_0.2.0_amd64"
mkdir -p "$DEB_STAGE/DEBIAN" "$DEB_STAGE/usr/bin" "$DEB_STAGE/usr/share/applications" "$DEB_STAGE/usr/share/icons"
cp "$DIR/packaging/deb/control" "$DEB_STAGE/DEBIAN/control"
cp "$TAR_STAGE/bin/loaf" "$DEB_STAGE/usr/bin/loaf"
cp "$DIR/packaging/assets/loaf.desktop" "$DEB_STAGE/usr/share/applications/loaf.desktop"
cp -r "$DIR/packaging/assets/icons/hicolor" "$DEB_STAGE/usr/share/icons/"
dpkg-deb --root-owner-group --build "$DEB_STAGE" "$DIST/loaf_0.2.0_amd64.deb"

echo "3. Building Arch package..."
ARCH_STAGE="$DIR/packaging/arch/build/pkg"
mkdir -p "$ARCH_STAGE/usr/bin" "$ARCH_STAGE/usr/share/applications" "$ARCH_STAGE/usr/share/icons"
cp "$DIR/packaging/arch/.PKGINFO" "$ARCH_STAGE/.PKGINFO"
cp "$TAR_STAGE/bin/loaf" "$ARCH_STAGE/usr/bin/loaf"
cp "$DIR/packaging/assets/loaf.desktop" "$ARCH_STAGE/usr/share/applications/loaf.desktop"
cp -r "$DIR/packaging/assets/icons/hicolor" "$ARCH_STAGE/usr/share/icons/"
(cd "$ARCH_STAGE" && tar --zstd --owner=0 --group=0 --numeric-owner -cf "$DIST/loaf-0.2.0-1-x86_64.pkg.tar.zst" .PKGINFO usr)

echo "4. Building RPM package..."
RPM_TOP="$DIR/packaging/rpm/build"
mkdir -p "$RPM_TOP/BUILD" "$RPM_TOP/RPMS" "$RPM_TOP/SOURCES" "$RPM_TOP/SPECS" "$RPM_TOP/SRPMS" "$RPM_TOP/DB"
mkdir -p "$RPM_TOP/SOURCES/packaging"
cp -r "$DIR/packaging/assets" "$RPM_TOP/SOURCES/packaging/"
cp "$DIR/README.md" "$RPM_TOP/SOURCES/"
mkdir -p "$RPM_TOP/SOURCES/target/release"
cp "$TAR_STAGE/bin/loaf" "$RPM_TOP/SOURCES/target/release/loaf"
rpmbuild -bb --nodeps --define "_topdir $RPM_TOP" --define "_dbpath $RPM_TOP/DB" --define "_prebuilt 1" --define "_sourcedir $RPM_TOP/SOURCES" "$DIR/packaging/rpm/loaf.spec"
find "$RPM_TOP/RPMS" -name "*.rpm" -exec cp {} "$DIST/" \;

echo "All distribution packages created successfully in $DIST!"
