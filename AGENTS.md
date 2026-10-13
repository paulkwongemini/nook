# Nook

Nook is a native Swift/AppKit macOS app. Build and test on macOS; Docker is not used.

## Git identity and GitHub account

- This is a personal project owned by **paulkwongemini**.
- The GitHub repository is `https://github.com/paulkwongemini/nook`.
- Use the following repository-local commit identity for both author and committer:
  - Name: `Paul`
  - Email: `227434338+paulkwongemini@users.noreply.github.com`
- Use the **paulkwongemini** GitHub account for authenticated operations on this repository. Do not use the company account `Paul-DesignPremise`.
- Before committing, verify the effective author and committer with `git var GIT_AUTHOR_IDENT` and `git var GIT_COMMITTER_IDENT`. GitHub CLI login does not determine commit attribution.
- Before an authorized GitHub write, verify the remote and authenticated account. If necessary, use `gh auth switch --hostname github.com --user paulkwongemini` and verify with `gh api user --jq .login`.
- Keep Git identity settings local to this repository; do not change global Git settings.
- Commit, push, and other Git or GitHub writes require an explicit user request. A request to commit does not authorize pushing.

## Development

- Keep source, UI text, and documentation in English. Keep the README brief.
- Build: `bash scripts/build.sh`.
- Test: `bash scripts/test.sh`.
- Camera integration tests: `NOOK_TEST_CAMERA=1 bash scripts/test.sh` (requires installed VLC 3 and FFmpeg; uses generated video and isolated test credentials).
- The camera pilot uses an existing VLC installation. Do not bundle a playback engine unless requested.
- Never commit camera credentials, personal device addresses, VPN configurations, generated media, or app bundles. Camera credentials belong in the user's private local `.env` file or macOS Keychain.
