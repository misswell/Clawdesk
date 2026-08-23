# Releasing Clawdesk

Clawdesk releases are published by `.github/workflows/release.yml`.

The workflow accepts a `v<version>` tag, reads the matching version from
`Resources/Info.plist`, runs the tests, builds arm64 and x86_64 binaries,
signs them with Developer ID, notarizes and staples the app, then uploads
`Clawdesk-<version>-macos.zip` to a GitHub Release.

The repository release setup has five non-password secrets configured locally
from the Developer ID identity. The only value that must be entered manually
in GitHub is `APPLE_APP_SPECIFIC_PASSWORD` under Settings → Secrets and
variables → Actions. It is the app-specific password created at
<https://account.apple.com/account/manage>, not the normal Apple ID password.

After that secret is present, the release process can create a new patch tag;
the workflow performs all signing, notarization, verification, and upload
steps. Existing tags and releases are never overwritten.
