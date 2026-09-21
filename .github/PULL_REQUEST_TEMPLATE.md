## Summary

<!-- What changes and why? Keep this short and operational. -->

- Scope:
  - [ ] Shell assets or templates (`dot_*`, `dot_*/*.tmpl`)
  - [ ] Bootstrap scripts (`.chezmoiscripts/*`, `bootstrap/scripts/*`)
  - [ ] Runtime / ecosystem manifests (`bootstrap/manifests/ecosystem/*`, `xdg_config/mise/*`)
  - [ ] Documentation (`README.md`, `docs/*`, `CHANGELOG.md`)
  - [ ] GitHub workflow / repository metadata (`.github/*`, `.pre-commit-config.yaml`)
  - [ ] Other (describe below)

## Validation

Select checks using `CONTRIBUTING.md`, "Local Validation." Use pass, fail, not
run, or not applicable, and include a reason for anything other than pass.

- Smoke suite: `<pass | fail | not run | not applicable — reason>`
- Pre-commit: `<pass | fail | not run | not applicable — reason>`
- macOS full preflight: `<pass | fail | not run | not applicable — reason>`
- GitHub Actions: `<pass | fail | not run — reason>`

## Notes

- [ ] No secrets, personal identifiers, or host-specific values are introduced into the baseline
- [ ] User-visible behavior changes are reflected in `README.md`, `docs/*`, or `CHANGELOG.md`

<!-- Optional: highlight risky areas, review order, or follow-up work. -->
