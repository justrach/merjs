#!/bin/sh

set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT INT TERM

payload='mock mer binary'
if command -v sha256sum >/dev/null 2>&1; then
    checksum_tool=$(command -v sha256sum)
    checksum=$(printf '%s' "$payload" | sha256sum | sed 's/ .*//')
else
    checksum_tool=$(command -v shasum)
    checksum=$(printf '%s' "$payload" | shasum -a 256 | sed 's/ .*//')
fi
checksum_tool_name=$(basename "$checksum_tool")

case "$(uname -s):$(uname -m)" in
    Darwin:arm64|Darwin:aarch64) asset=mer-macos-aarch64 ;;
    Darwin:x86_64|Darwin:amd64) asset=mer-macos-x86_64 ;;
    Linux:arm64|Linux:aarch64) asset=mer-linux-aarch64 ;;
    Linux:x86_64|Linux:amd64) asset=mer-linux-x86_64 ;;
    *) echo "unsupported test platform" >&2; exit 1 ;;
esac

make_mocks() {
    mock_dir=$1
    mkdir -p "$mock_dir"
    for name in uname mktemp chmod mkdir mv rm grep sed; do
        ln -s "$(command -v "$name")" "$mock_dir/$name"
    done
    cat > "$mock_dir/curl" <<'EOF'
#!/bin/sh
url=
output=
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o) shift; output=$1 ;;
        http://*|https://*) url=$1 ;;
    esac
    shift
done
case "$url" in
    *checksums.txt)
        case "$MOCK_MODE" in
            checksum-download-fail)
                printf '%s\n' partial > "$output"
                exit 22
                ;;
            missing) printf '%s  other-asset\n' "$MOCK_CHECKSUM" > "$output" ;;
            malformed) printf '%s  %s\n' malformed "$MOCK_ASSET" > "$output" ;;
            mismatch) printf '%064d  %s\n' 0 "$MOCK_ASSET" > "$output" ;;
            success|no-tool) printf '%s  %s\n' "$MOCK_CHECKSUM" "$MOCK_ASSET" > "$output" ;;
        esac
        ;;
    *) printf '%s' "$MOCK_PAYLOAD" > "$output" ;;
esac
EOF
    chmod +x "$mock_dir/curl"
}

assert_clean_failure() {
    mode=$1
    with_tool=$2
    case_dir="$test_root/$mode"
    mock_dir="$case_dir/bin"
    mkdir -p "$case_dir/tmp" "$case_dir/install"
    make_mocks "$mock_dir"
    if [ "$with_tool" = yes ]; then
        ln -s "$checksum_tool" "$mock_dir/$checksum_tool_name"
    fi

    if PATH="$mock_dir" TMPDIR="$case_dir/tmp" MER_INSTALL_DIR="$case_dir/install" \
        MOCK_MODE="$mode" MOCK_CHECKSUM="$checksum" MOCK_ASSET="$asset" \
        MOCK_PAYLOAD="$payload" /bin/sh "$root/scripts/install-mer.sh" \
        > "$case_dir/output" 2>&1; then
        echo "installer unexpectedly succeeded for $mode" >&2
        exit 1
    fi
    test ! -e "$case_dir/install/mer"
    test -z "$(find "$case_dir/tmp" -mindepth 1 -print -quit)"
}

assert_clean_failure no-tool no
assert_clean_failure checksum-download-fail yes
assert_clean_failure missing yes
assert_clean_failure malformed yes
assert_clean_failure mismatch yes

success_dir="$test_root/success"
make_mocks "$success_dir/bin"
mkdir -p "$success_dir/tmp" "$success_dir/install"
ln -s "$checksum_tool" "$success_dir/bin/$checksum_tool_name"
PATH="$success_dir/bin" TMPDIR="$success_dir/tmp" MER_INSTALL_DIR="$success_dir/install" \
    MOCK_MODE=success MOCK_CHECKSUM="$checksum" MOCK_ASSET="$asset" \
    MOCK_PAYLOAD="$payload" /bin/sh "$root/scripts/install-mer.sh" \
    > "$success_dir/output" 2>&1
test "$(cat "$success_dir/install/mer")" = "$payload"
test -x "$success_dir/install/mer"
test -z "$(find "$success_dir/tmp" -mindepth 1 -print -quit)"

echo "install-mer shell tests passed"
