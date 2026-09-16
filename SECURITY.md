# Security Policy

Porto reads local socket information, launches bounded local tools, connects to
explicitly enabled SSH profiles, and can send signals to validated local or
remote process targets. Treat command-injection, stale-target signaling,
credential exposure, sandbox or Gatekeeper bypasses, and unintended network
activity as security-sensitive.

## Reporting a vulnerability

Please do not publish vulnerability details, SSH output, private-key paths,
hostnames, or reproduction credentials in a public issue.

Use GitHub's private vulnerability reporting form:

<https://github.com/wehyn/porto/security/advisories/new>

Include the affected commit or release, reproduction steps that do not contain
secrets, the expected behavior, and the observed impact. The repository
maintainer must enable GitHub private vulnerability reporting before that form
can receive reports.

## Supported versions

The `main` branch is the actively maintained development version. A tagged
release is supported until a newer release supersedes it, unless its release
notes say otherwise.

## Update security

Porto's release builds periodically check the Sparkle appcast over HTTPS. The
stable feed is the GitHub latest-release appcast, and Sparkle verifies signed
feed and archive metadata before an update is installed. The standard Sparkle
UI asks the user before downloading and installing; automatic checking is not
silent authorization to install software.

The Sparkle Ed25519 private key is a release secret. Keep it offline and in the
designated secret store, pass it to appcast generation through standard input,
and never commit, print, upload, or place it in an app bundle. The public key
may be embedded in `Info.plist`. If the private key is suspected to be
compromised, stop publishing updates with it, preserve relevant release and
workflow evidence, rotate or replace the update trust configuration through a
reviewed release, and notify users through the repository's trusted release
channels.

Report suspicious releases, appcasts, update prompts, signature failures, or
unexpected update archives through the private vulnerability reporting form
above. Include the affected version and URLs, but do not include private keys,
credentials, or sensitive host information. Sparkle archive signing is
separate from Apple's code signing and notarization; Porto remains
unsigned/unnotarized and must not bypass Gatekeeper.
