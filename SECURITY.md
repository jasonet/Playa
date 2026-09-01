# Security Policy

## Supported versions

Security fixes are applied to the latest source revision and the latest published release.

## Reporting a vulnerability

Do not open a public issue for a suspected vulnerability or credential exposure.

Use GitHub's private vulnerability reporting feature for this repository:

1. Open the repository's **Security** tab.
2. Select **Advisories**.
3. Select **Report a vulnerability**.

Include affected versions, impact, reproduction steps, and a minimal proof of concept. Remove API keys, OAuth tokens, model-provider credentials, Apple signing material, and personal data from reports and logs.

## Credential handling

Playa's public source tree must not contain real provider keys, OAuth tokens, Apple developer identities, signing certificates, notarization credentials, or private Sparkle keys. Machine-specific signing values belong in the ignored `Configuration/Signing.local.xcconfig`. Runtime provider credentials are stored only in the user's local application settings and support directory.

If a credential is accidentally committed, revoke or rotate it immediately before removing it from Git history.
