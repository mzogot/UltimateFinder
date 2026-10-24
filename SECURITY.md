# Security policy

UltimateFinder reads and moves your files, so security reports are taken seriously.

Please **don't** open a public issue for a vulnerability. Report it privately through
[GitHub's security advisories](https://github.com/mzogot/UltimateFinder/security/advisories/new).
You'll get a reply within a few days.

Only the latest release receives fixes. Releases are signed with a Developer ID
(team `854T64H39D`) and notarized by Apple; you can check a download with:

```sh
spctl --assess --type open --context context:primary-signature -v UltimateFinder.dmg
codesign -dvv /Applications/UltimateFinder.app 2>&1 | grep Authority
```
