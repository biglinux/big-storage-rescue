#!/bin/bash
# Build every translated resource from locale/*.po:
#   - big-storage-rescue/usr/share/locale/<lang>/LC_MESSAGES/big-storage-rescue.mo (scripts)
#   - the .desktop files and the polkit policy, merged from locale/templates
# The generated files are committed: the PKGBUILD only copies big-storage-rescue/.
# Languages are listed in locale/LINGUAS.
# DEST=DIR writes the results into another tree (used by tests).
set -e
cd "$(dirname "$0")/.."
dest="${DEST:-big-storage-rescue}"
for po in locale/*.po; do
    lang="$(basename "$po" .po)"
    dir="$dest/usr/share/locale/$lang/LC_MESSAGES"
    mkdir -p "$dir"
    msgfmt --check -o "$dir/big-storage-rescue.mo" "$po"
done

mkdir -p "$dest/usr/share/applications" "$dest/usr/share/big-storage-rescue" "$dest/usr/share/kio/servicemenus" \
    "$dest/usr/share/polkit-1/actions"
desktop() { # TEMPLATE OUTPUT
    # Name, GenericName, Comment and Keywords are default keywords; long
    # options only (older gettext has no short -k for msgfmt)
    msgfmt --desktop --keyword=X-KDE-Submenu \
        --template "locale/templates/$1" -d locale -o "$dest/$2"
}
desktop org.biglinux.big-storage-rescue.desktop.in usr/share/applications/org.biglinux.big-storage-rescue.desktop
# Not started by default: the application copies it to the autostart folder
# of the person who turns the notifier on
desktop big-storage-rescue-notifier.desktop.in usr/share/big-storage-rescue/big-storage-rescue-notifier.desktop
desktop big-storage-rescue-servicemenu.desktop.in usr/share/kio/servicemenus/big-storage-rescue.desktop
# msgfmt writes BCP 47 tags (pt-BR, zh-Hans-CN with the script); polkit
# matches POSIX locale names (pt_BR, then pt), which is also what the policy
# always used
policy="$dest/usr/share/polkit-1/actions/org.biglinux.big-storage-rescue.policy"
# locale/its holds the polkit ITS rules, for systems without polkit (CI)
GETTEXTDATADIRS="$PWD/locale${GETTEXTDATADIRS:+:$GETTEXTDATADIRS}" \
    msgfmt --xml --template locale/templates/org.biglinux.big-storage-rescue.policy.in -d locale -o "$policy"
sed -i -E -e 's/xml:lang="([a-z]{2,3})-[A-Z][a-z]{3}-([A-Z]{2})"/xml:lang="\1_\2"/g' \
    -e 's/xml:lang="([a-z]{2,3})-([A-Z]{2})"/xml:lang="\1_\2"/g' "$policy"
