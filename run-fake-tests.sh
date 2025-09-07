bash fake-test-install.sh --keep -v
SANDBOX="$(ls -td "${TMPDIR:-/tmp}"/dotfiles-fake.* 2>/dev/null | head -1)"
open "$SANDBOX/home"
