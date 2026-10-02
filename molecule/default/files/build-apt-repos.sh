#!/bin/sh
# Builds two signed, flat apt repositories under $1 — "deb822" and "legacy",
# one per kind of source the role writes — each holding one tiny package that
# exists nowhere else, plus the armored key they are signed with.
set -eu

root=$1
GNUPGHOME=$(mktemp -d)
export GNUPGHOME
trap 'gpgconf --kill gpg-agent; rm -rf "$GNUPGHOME"' EXIT

gpg --batch --pinentry-mode loopback --passphrase '' \
    --quick-gen-key 'Molecule test repository <molecule@example.invalid>' default default never

for repo in deb822 legacy; do
    pkg="molecule-$repo-probe"
    build=$(mktemp -d)
    mkdir -p "$build/DEBIAN" "$build/usr/share/$pkg" "$root/$repo"
    cat > "$build/DEBIAN/control" <<EOF
Package: $pkg
Version: 1.0
Architecture: all
Maintainer: Molecule <molecule@example.invalid>
Description: Probe for the $repo apt source of the linux role tests
EOF
    echo "$repo" > "$build/usr/share/$pkg/source"
    dpkg-deb --root-owner-group --build "$build" "$root/$repo/${pkg}_1.0_all.deb"
    rm -rf "$build"

    # Release is written elsewhere first so that it does not list itself.
    cd "$root/$repo"
    apt-ftparchive packages . > Packages
    apt-ftparchive release . > "$GNUPGHOME/Release"
    mv "$GNUPGHOME/Release" Release
    gpg --batch --yes --clearsign --output InRelease Release
    cd - > /dev/null
done

# Written last: prepare.yml skips this script once the key exists.
gpg --armor --export > "$root/molecule.asc"
