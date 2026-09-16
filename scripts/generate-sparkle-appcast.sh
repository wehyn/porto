#!/bin/zsh
set -euo pipefail

usage_error() {
    print -u2 -- "error: $1"
    exit 1
}

[[ $# -eq 1 ]] || usage_error "expected exactly one staging directory"

: "${SPARKLE_TOOLS_DIR:?error: SPARKLE_TOOLS_DIR is required}"
: "${SPARKLE_DOWNLOAD_URL_PREFIX:?error: SPARKLE_DOWNLOAD_URL_PREFIX is required}"

tools_dir="${SPARKLE_TOOLS_DIR:A}"
prefix="$SPARKLE_DOWNLOAD_URL_PREFIX"
staging_dir="$1"

[[ -d "$tools_dir" ]] || usage_error "Sparkle tools directory is missing"
generate_appcast="$tools_dir/generate_appcast"
[[ -f "$generate_appcast" && -x "$generate_appcast" ]] || usage_error "executable generate_appcast is missing"
[[ -d "$staging_dir" && ! -L "$staging_dir" ]] || usage_error "staging directory is invalid"
[[ "$prefix" == https://* && "$prefix" == */ ]] || usage_error "SPARKLE_DOWNLOAD_URL_PREFIX must be an https:// URL ending in /"

typeset -a archive_paths=()
for archive in "$staging_dir"/Porto-*-macOS-universal.zip(N); do
    [[ -f "$archive" && ! -L "$archive" ]] && archive_paths+=("$archive")
done
(( ${#archive_paths} > 0 )) || usage_error "no regular Porto universal ZIP archive found"

for entry in "$staging_dir"/*(N); do
    name="${entry:t}"
    [[ "$name" == appcast.xml || "${archive_paths[(r)$entry]-}" == "$entry" ]] || usage_error "staging directory contains an unsupported entry"
done

if [[ -e "$staging_dir/appcast.xml" || -L "$staging_dir/appcast.xml" ]]; then
    [[ -f "$staging_dir/appcast.xml" && ! -L "$staging_dir/appcast.xml" ]] || usage_error "appcast.xml is not a regular file"
    rm -f -- "$staging_dir/appcast.xml"
fi

private_key="$(cat)"
[[ -n "$private_key" ]] || usage_error "private key stdin is empty"

if ! printf '%s' "$private_key" | "$generate_appcast" "$staging_dir" --ed-key-file - --download-url-prefix "$prefix" >/dev/null 2>/dev/null; then
    usage_error "generate_appcast failed"
fi

for entry in "$staging_dir"/*(N); do
    name="${entry:t}"
    [[ "$name" == appcast.xml || "${archive_paths[(r)$entry]-}" == "$entry" ]] || usage_error "generate_appcast wrote an unsupported staging entry"
done

appcast="$staging_dir/appcast.xml"
[[ -s "$appcast" && -f "$appcast" && ! -L "$appcast" ]] || usage_error "generate_appcast did not produce a non-empty appcast.xml"
xmllint --noout "$appcast" >/dev/null 2>/dev/null || usage_error "appcast.xml is not valid XML"

signature_xpath='count(//*[local-name()="item"]//*[local-name()="enclosure"][@*[local-name()="edSignature" and namespace-uri()="http://www.andymatuschak.org/xml-namespaces/sparkle" and string-length(normalize-space(.)) > 0]])'
signature_count="$(xmllint --xpath "$signature_xpath" "$appcast" 2>/dev/null)" || usage_error "could not inspect appcast release signatures"
[[ "$signature_count" != 0 ]] || usage_error "appcast has no signed release enclosure"

url_xpath='//*[local-name()="item"]//*[local-name()="enclosure"][@url]/@url'
urls="$(xmllint --xpath "$url_xpath" "$appcast" 2>/dev/null)" || usage_error "could not inspect appcast enclosure URLs"
[[ -n "$urls" ]] || usage_error "appcast has no release enclosure URL"
[[ "$urls" == *"$prefix"* ]] || usage_error "appcast release URL does not contain the configured prefix"

print -- "Sparkle appcast generated: $appcast"
