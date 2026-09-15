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
