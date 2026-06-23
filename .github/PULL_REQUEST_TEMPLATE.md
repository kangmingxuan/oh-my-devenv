## Summary

<!-- What changes and why? Keep this short and operational. -->

- Scope:
  - [ ] Shell assets or templates (`dot_*`, `dot_*/*.tmpl`)
  - [ ] Bootstrap scripts (`.chezmoiscripts/*`, `bootstrap/scripts/*`)
  - [ ] Runtime / ecosystem manifests (`bootstrap/manifests/ecosystem/*`, `dot_config/mise/*`)
  - [ ] Documentation (`README.md`, `docs/*`, `CHANGELOG.md`)
  - [ ] GitHub workflow / repository metadata (`.github/*`, `.pre-commit-config.yaml`)
  - [ ] Other (describe below)

## Validation

- [ ] `bash bootstrap/scripts/run-smoke-tests.sh` passes locally
- [ ] `pre-commit run --all-files` passes locally
- [ ] GitHub Actions is green on this branch

## Notes

- [ ] No secrets, personal identifiers, or host-specific values are introduced into the baseline
- [ ] User-visible behavior changes are reflected in `README.md`, `docs/*`, or `CHANGELOG.md`

<!-- Optional: highlight risky areas, review order, or follow-up work. -->
