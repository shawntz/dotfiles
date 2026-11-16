# shellcheck shell=bash
# ci-keychain.sh, with a fake security: no keychain is made, and the real search list and default
# keychain are never touched.
# Helpers (run, assert_*, use_fakes, make_package, …) come from run.sh.

# The script changes the default keychain when the real security runs it, so every test checks
# that the fake is the one on PATH before it sets CI=true.
# "0 pretend p12" in base64. It starts with the byte 0x30, as a real .p12 file does.
PRETEND_P12="MCBwcmV0ZW5kIHAxMg=="

keychain_fixture() {
    use_fakes security
    [ "$(command -v security)" = "$T/bin/security" ] || fail "the fake security is not first on PATH"
    PKG="$T/pkg"
    make_package "$PKG"
    export KEYCHAIN_PATH="$T/test.keychain-db"
}

security_calls() { awk '$1 == "security" { print $2 }' "$FAKE_LOG" | tr '\n' ','; }

test_keychain_refuses_to_run_outside_ci() {
    keychain_fixture
    run env -u CI SIGNING_P12="$PRETEND_P12" SIGNING_P12_PASSWORD=secret "$PKG/scripts/ci-keychain.sh" create
    assert_status 1
    assert_contains "$ERR" "only runs on a CI runner"
    assert_eq "" "$(security_calls)" "security calls"
}

test_keychain_create_imports_the_certificate_and_makes_the_keychain_the_default() {
    keychain_fixture
    run env CI=true SIGNING_P12="$PRETEND_P12" SIGNING_P12_PASSWORD=secret "$PKG/scripts/ci-keychain.sh" create
    assert_status 0
    assert_eq "create-keychain,set-keychain-settings,unlock-keychain,import,set-key-partition-list,list-keychains,list-keychains,default-keychain," \
        "$(security_calls)" "security calls, in order"
    local log
    log="$(cat "$FAKE_LOG")"
    assert_contains "$log" "-k $KEYCHAIN_PATH -f pkcs12 -P secret -T /usr/bin/codesign -T /usr/bin/security"
    assert_contains "$log" "security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "
    assert_contains "$log" "security list-keychains -d user -s $KEYCHAIN_PATH"
    assert_contains "$log" "security default-keychain -d user -s $KEYCHAIN_PATH"
    assert_eq "$KEYCHAIN_PATH" "$OUT" "stdout"
    assert_not_contains "$ERR$OUT" "secret" "what the script prints"
}

test_keychain_create_needs_the_certificate_and_its_password() {
    keychain_fixture
    run env CI=true SIGNING_P12_PASSWORD=secret "$PKG/scripts/ci-keychain.sh" create
    assert_status 1
    assert_contains "$ERR" "SIGNING_P12 is empty"
    run env CI=true SIGNING_P12="$PRETEND_P12" "$PKG/scripts/ci-keychain.sh" create
    assert_status 1
    assert_contains "$ERR" "SIGNING_P12_PASSWORD is empty"
    # "hello" in base64, then text that is not base64 at all: neither is a .p12 file.
    local value
    for value in aGVsbG8= 'not base64 !!'; do
        run env CI=true SIGNING_P12="$value" SIGNING_P12_PASSWORD=secret "$PKG/scripts/ci-keychain.sh" create
        assert_status 1
        assert_contains "$ERR" "SIGNING_P12 does not decode to a .p12 file"
    done
    assert_eq "" "$(security_calls)" "security calls"
}

test_keychain_delete_removes_only_a_keychain_that_is_there() {
    keychain_fixture
    run env CI=true "$PKG/scripts/ci-keychain.sh" delete
    assert_status 0
    assert_contains "$ERR" "there is no $KEYCHAIN_PATH to delete"
    assert_eq "" "$(security_calls)" "security calls"
    : >"$KEYCHAIN_PATH"
    run env CI=true "$PKG/scripts/ci-keychain.sh" delete
    assert_status 0
    assert_contains "$(cat "$FAKE_LOG")" "security delete-keychain $KEYCHAIN_PATH"
}
