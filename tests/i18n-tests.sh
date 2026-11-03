#!/bin/bash
# shellcheck disable=SC2016,SC2317,SC2329  # bash -c '...$1' snippets and helpers called through check()
# Internationalization tests: the catalog is complete and up to date, the
# generated resources match their templates, messages keep their printf
# placeholders, and the scripts pick the right language at run time
# (English source, pt_BR, fallback for untranslated languages and entries).
#
# Usage: tests/i18n-tests.sh

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
cd "$REPO" || exit 2

PASS=0 FAIL=0 FAILED=()
check() {
    local msg="$1"; shift
    if "$@"; then PASS=$((PASS + 1)); printf '  \033[32m✓\033[0m %s\n' "$msg"
    else FAIL=$((FAIL + 1)); FAILED+=("$msg"); printf '  \033[31m✗\033[0m %s\n' "$msg"; fi
}
begin() { echo "— $1"; }
WORK="$(mktemp -d)"
trap 'rm -rf -- "${WORK:?}"' EXIT

msgids() { msgcat --no-wrap "$1" 2>/dev/null | sed -n 's/^msgid "\(.*\)"$/\1/p' | grep -v '^$' | sort -u; }
export -f msgids

echo "========================================="
echo "Internationalization tests"
echo "========================================="

begin "catalog"
POT="$WORK/fresh.pot" bash locale/update-pot.sh
check "locale/big-storage-rescue.pot is up to date with the code (run locale/update-pot.sh)" \
    bash -c 'diff <(msgids "$1") <(msgids "$2")' _ "$WORK/fresh.pot" locale/big-storage-rescue.pot
for po in locale/*.po; do
    lang="$(basename "$po" .po)"
    check "$lang: compiles (msgfmt --check)" msgfmt --check -o /dev/null "$po"
    check "$lang: no untranslated message" test -z "$(msgattrib --untranslated --no-obsolete "$po" | grep '^msgid' | tail -n +2)"
    check "$lang: no fuzzy (unreviewed) message" test -z "$(msgattrib --only-fuzzy --no-obsolete "$po" | grep '^msgid' | tail -n +2)"
    check "$lang: listed in locale/LINGUAS" grep -qx "$lang" locale/LINGUAS
    check "$lang: no obsolete message left behind (#~)" bash -c '! grep -q "^#~" "$1"' _ "$po"
    check "$lang: every msgid of the template exists in the translation" \
        test -z "$(comm -23 <(msgids locale/big-storage-rescue.pot) <(msgids "$po"))"
    # The same printf directives, in the same order, in msgid and msgstr. %%
    # takes no argument: it may move ("%87" in Turkish), but not go missing
    bad="$(python3 -I - "$po" <<'EOF'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
spec = re.compile(r"%[-+ #0]*[0-9]*(?:\.[0-9]+)?[sdiuxXfc%]")
def args(s):
    return [d for d in spec.findall(s) if d != "%%"]
for mid, mstr in re.findall(r'^msgid "(.*)"\nmsgstr "(.*)"$', text, re.M):
    if mid and mstr and (args(mid) != args(mstr) or spec.findall(mid).count("%%") != spec.findall(mstr).count("%%")):
        print(mid)
EOF
)"
    check "$lang: placeholders (%s, %d) match in every message" test -z "$bad"
    [ -n "$bad" ] && printf '      %s\n' "$bad"
done

begin "generated resources match their templates (run locale/compile.sh)"
DEST="$WORK/gen" bash locale/compile.sh
for f in usr/share/applications/org.biglinux.big-storage-rescue.desktop usr/share/big-storage-rescue/big-storage-rescue-notifier.desktop \
         usr/share/kio/servicemenus/big-storage-rescue.desktop usr/share/polkit-1/actions/org.biglinux.big-storage-rescue.policy; do
    check "$f" cmp -s "$WORK/gen/$f" "big-storage-rescue/$f"
done
check "pt_BR .mo" cmp -s <(msgunfmt "$WORK/gen/usr/share/locale/pt_BR/LC_MESSAGES/big-storage-rescue.mo") \
    <(msgunfmt big-storage-rescue/usr/share/locale/pt_BR/LC_MESSAGES/big-storage-rescue.mo)
for key in Name Comment GenericName Keywords; do
    check "launcher: $key translated" grep -q "^$key\[pt_BR\]=" big-storage-rescue/usr/share/applications/org.biglinux.big-storage-rescue.desktop
done
check "service menu: submenu and actions translated" \
    test "$(grep -c '\[pt_BR\]=' big-storage-rescue/usr/share/kio/servicemenus/big-storage-rescue.desktop)" -eq 6
check "polkit: description and message translated (pt_BR form)" \
    test "$(grep -c 'xml:lang="pt_BR"' big-storage-rescue/usr/share/polkit-1/actions/org.biglinux.big-storage-rescue.policy)" -eq 6
# polkit looks languages up by their POSIX name (zh_CN, not zh-Hans-CN)
check "polkit: every language of locale/LINGUAS, by its POSIX name" \
    bash -c 'while read -r l; do [ "$(grep -c "xml:lang=\"$l\"" "$1")" -eq 6 ] || { echo "      $l"; exit 1; }; done < locale/LINGUAS' _ \
    big-storage-rescue/usr/share/polkit-1/actions/org.biglinux.big-storage-rescue.policy

begin "no user-visible text outside the translation system"
# Exit 1 only: a match (0) fails, and so does an error of grep (2), which prints nothing
check "code and templates are English (no accented letters outside .po/.mo)" \
    bash -c 'LC_ALL=C.UTF-8 grep -rqP --exclude-dir=__pycache__ "[\x{00C0}-\x{024F}]" "$@"; [ "$?" -eq 1 ]' _ big-storage-rescue/usr/bin big-storage-rescue/usr/lib locale/templates locale/*.sh

begin "language chosen at run time"
BM=big-storage-rescue/usr/bin/big-storage-rescue
help_line() { env -i PATH="$PATH" "$@" bash "$BM" --help 2>/dev/null | head -n1; }
check "LANG=C: English" test "$(help_line LANG=C)" = "Usage: big-storage-rescue [OPTION] [DEVICE|FOLDER]"
check "LANG=en_US.UTF-8: English" test "$(help_line LANG=en_US.UTF-8)" = "Usage: big-storage-rescue [OPTION] [DEVICE|FOLDER]"
check "LANG=pt_BR.UTF-8: Portuguese" test "$(help_line LANG=pt_BR.UTF-8)" = "Uso: big-storage-rescue [OPÇÃO] [DISPOSITIVO|PASTA]"
check "language without translation (nl_NL): English" test "$(help_line LANG=nl_NL.UTF-8)" = "Usage: big-storage-rescue [OPTION] [DEVICE|FOLDER]"
check "LANGUAGE=de: German, one of the other catalogs" test "$(help_line LANG=pt_BR.UTF-8 LANGUAGE=de)" = "Aufruf: big-storage-rescue [OPTION] [GERÄT|ORDNER]"
check "LANGUAGE=nl:pt_BR falls back to the next language" \
    test "$(help_line LANG=pt_BR.UTF-8 LANGUAGE=nl:pt_BR)" = "Uso: big-storage-rescue [OPÇÃO] [DISPOSITIVO|PASTA]"
check "errors are translated too" \
    bash -c 'env -i PATH="$PATH" LANG=pt_BR.UTF-8 bash "$1" --bogus 2>&1 | grep -q "opção desconhecida"' _ "$BM"
# bash translates $"..." while parsing a command: a text domain chosen inside
# the same block would come too late (the message stayed English)
if [ "$EUID" -ne 0 ]; then
    check "big-storage-rescue without options, no window and no terminal: the help, translated" \
        bash -c 'env -i PATH="$PATH" LANG=pt_BR.UTF-8 bash "$1" 2>&1 </dev/null | grep -q "^Uso: big-storage-rescue"' _ "$BM"
fi
check "--version translated" bash -c 'env -i PATH="$PATH" LANG=pt_BR.UTF-8 bash "$1" --version | grep -q "revisão:"' _ "$BM"
check "--version: translated labels aligned by characters, not bytes" env LC_ALL=C.UTF-8 bash -c '
    cols="$(env -i PATH="$PATH" LANG=pt_BR.UTF-8 bash "$1" --version | tail -n +2 | while IFS= read -r l; do
        [[ $l =~ ^([^:]*:\ +) ]] && echo "${#BASH_REMATCH[1]}"; done | sort -u | wc -l)"
    [ "$cols" -eq 1 ]' _ "$BM"
check "--doctor translated" bash -c 'env -i PATH="$PATH" LANG=pt_BR.UTF-8 HOME="$HOME" bash "$1" --doctor 2>/dev/null | grep -q "^Resultado: "' _ "$BM"

# A translation that lacks one message: that one stays English, the rest is translated
mkdir -p "$WORK/tree/usr/bin" "$WORK/tree/usr/share/locale/pt_BR/LC_MESSAGES"
cp "$BM" "$WORK/tree/usr/bin/"; cp -r big-storage-rescue/usr/lib "$WORK/tree/usr/"
msgattrib --no-wrap locale/pt_BR.po | python3 -I -c '
import sys
t = sys.stdin.read()
print(t.replace("msgstr \"Uso: big-storage-rescue [OPÇÃO] [DISPOSITIVO|PASTA]\"", "msgstr \"\""))' > "$WORK/partial.po"
msgfmt -o "$WORK/tree/usr/share/locale/pt_BR/LC_MESSAGES/big-storage-rescue.mo" "$WORK/partial.po"
out="$(env -i PATH="$PATH" LANG=pt_BR.UTF-8 bash "$WORK/tree/usr/bin/big-storage-rescue" --help)"
check "incomplete translation: the missing message falls back to English" grep -q "^Usage: big-storage-rescue" <<< "$out"
check "incomplete translation: the others are still translated" grep -q "mostra esta ajuda" <<< "$out"

begin "the terminal manager"
check "--cli --help translated" bash -c 'env -i PATH="$PATH" LANG=pt_BR.UTF-8 bash "$1" --cli --help | grep -q "^Uso: big-storage-rescue --cli \[COMANDO\]"' _ "$BM"
check "--migrate-state translated" bash -c 'env -i PATH="$PATH" LANG=pt_BR.UTF-8 HOME="$2" bash "$1" --migrate-state | grep -q "^Nada do Big-Mount 2.x para trazer.$"' _ "$BM" "$WORK/empty-home"

begin "formatting with Unicode and long values"
# shellcheck source=../big-storage-rescue/usr/lib/big-storage-rescue/cli.sh
BSR_LIB="$REPO/big-storage-rescue/usr/lib/big-storage-rescue" . "$REPO/big-storage-rescue/usr/lib/big-storage-rescue/cli.sh"
BSR_UI="tty"; bsr_ui_init
long="Fotos da Família — viagem ao Japão 東京 2026 ✓ $(printf 'x%.0s' {1..120})"
bsr_doc_new; bsr_doc_kv "Device" "$long"; bsr_doc_render_text
check "long Unicode label is kept whole in the terminal" grep -qF "$long" <<< "$REPLY"
check "long Unicode label is kept whole in dialogs" grep -qF "Fotos da Família — viagem ao Japão 東京" <<< "$(bsr_doc_nul | tr '\0' '\n')"
LANGUAGE=pt_BR LC_ALL=pt_BR.UTF-8 printf -v t $"%s is still in use" "$long"
check "translated format with a Unicode argument" bash -c '[[ $1 == *"Japão"*"em uso" || $1 == *"Japão"*"in use" ]]' _ "$t"

echo ""
echo "========================================="
echo "i18n result: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && printf '  - %s\n' "${FAILED[@]}"
echo "========================================="
exit "$FAIL"
