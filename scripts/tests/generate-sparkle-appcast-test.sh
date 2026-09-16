#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
wrapper="$script_dir/../generate-sparkle-appcast.sh"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

tools_dir="$work_dir/tools"
staging_dir="$work_dir/staging"
mkdir -p "$tools_dir" "$staging_dir"

cat > "$tools_dir/generate_appcast" <<'FAKE'
#!/bin/zsh
set -euo pipefail

args_file="${FAKE_ARGS_FILE:?}"
stdin_file="${FAKE_STDIN_FILE:?}"
printf '%s\0' "$@" > "$args_file"
cat > "$stdin_file"

staging_dir="$1"
prefix=""
while (( $# > 0 )); do
    if [[ "$1" == "--download-url-prefix" ]]; then
        prefix="$2"
        break
    fi
    shift
done

case "${FAKE_OUTPUT_MODE:-valid}" in
    invalid-xml)
        print '<not-appcast>' > "$staging_dir/appcast.xml"
        ;;
    missing-signature)
        print "<?xml version=\"1.0\"?><rss xmlns:sparkle=\"http://www.andymatuschak.org/xml-namespaces/sparkle\"><channel><item><enclosure url=\"${prefix}Porto.zip\" /></item></channel></rss>" > "$staging_dir/appcast.xml"
        ;;
    missing-release-prefix)
        print '<?xml version="1.0"?><rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><enclosure url="https://elsewhere.example/Porto.zip" sparkle:edSignature="signature" /></item></channel></rss>' > "$staging_dir/appcast.xml"
        ;;
    valid)
        print "<?xml version=\"1.0\"?><rss xmlns:sparkle=\"http://www.andymatuschak.org/xml-namespaces/sparkle\"><channel><item><enclosure url=\"${prefix}Porto-1.0-macOS-universal.zip\" sparkle:edSignature=\"signature\" /></item></channel></rss>" > "$staging_dir/appcast.xml"
        ;;
    *)
        exit 64
        ;;
esac
FAKE
chmod +x "$tools_dir/generate_appcast"

prefix="https://downloads.example/porto/"
key='ed25519-test-secret'
archive="$staging_dir/Porto-1.0-macOS-universal.zip"
printf 'archive' > "$archive"

expect_failure() {
    local name="$1"
    shift
    if "$@" >"$work_dir/$name.stdout" 2>"$work_dir/$name.stderr"; then
        print -u2 "expected failure: $name"
        return 1
    fi
}

run_wrapper() {
    env \
        SPARKLE_TOOLS_DIR="$tools_dir" \
        SPARKLE_DOWNLOAD_URL_PREFIX="$prefix" \
        FAKE_ARGS_FILE="$work_dir/args.bin" \
        FAKE_STDIN_FILE="$work_dir/stdin.bin" \
        FAKE_OUTPUT_MODE="${FAKE_OUTPUT_MODE:-valid}" \
        "$wrapper" "$staging_dir"
}

expect_failure missing-tool env \
    SPARKLE_TOOLS_DIR="$work_dir/no-such-tools" \
    SPARKLE_DOWNLOAD_URL_PREFIX="$prefix" \
    "$wrapper" "$staging_dir" </dev/null

expect_failure missing-prefix env \
    SPARKLE_TOOLS_DIR="$tools_dir" \
    -u SPARKLE_DOWNLOAD_URL_PREFIX \
    "$wrapper" "$staging_dir" </dev/null

expect_failure empty-prefix env \
    SPARKLE_TOOLS_DIR="$tools_dir" \
    SPARKLE_DOWNLOAD_URL_PREFIX='' \
    "$wrapper" "$staging_dir" </dev/null

expect_failure non-https-prefix env \
    SPARKLE_TOOLS_DIR="$tools_dir" \
    SPARKLE_DOWNLOAD_URL_PREFIX='http://downloads.example/' \
    "$wrapper" "$staging_dir" </dev/null

mv "$archive" "$work_dir/archive.zip"
expect_failure missing-archive env \
    SPARKLE_TOOLS_DIR="$tools_dir" \
    SPARKLE_DOWNLOAD_URL_PREFIX="$prefix" \
    "$wrapper" "$staging_dir" </dev/null
mv "$work_dir/archive.zip" "$archive"

expect_failure empty-key run_wrapper </dev/null

FAKE_OUTPUT_MODE=invalid-xml expect_failure invalid-xml run_wrapper <<< "$key"
FAKE_OUTPUT_MODE=missing-signature expect_failure missing-signature run_wrapper <<< "$key"
FAKE_OUTPUT_MODE=missing-release-prefix expect_failure missing-release-prefix run_wrapper <<< "$key"

rm -f "$staging_dir/appcast.xml" "$work_dir/args.bin" "$work_dir/stdin.bin"
printf '%s' "$key" | run_wrapper

[[ -s "$staging_dir/appcast.xml" ]]
cmp -s "$work_dir/stdin.bin" <(printf '%s' "$key")
! grep -aF -- "$key" "$work_dir/args.bin"

args_text="$(tr '\0' '\n' < "$work_dir/args.bin")"
print -r -- "$args_text" | grep -Fx -- "$staging_dir"
print -r -- "$args_text" | grep -Fx -- '--ed-key-file'
print -r -- "$args_text" | grep -Fx -- '-'
print -r -- "$args_text" | grep -Fx -- '--download-url-prefix'
print -r -- "$args_text" | grep -Fx -- "$prefix"

print 'generate-sparkle-appcast: all tests passed'
