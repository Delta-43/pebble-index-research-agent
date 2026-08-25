# Contributing

This project documents a real, working self-hosted setup as it's built — issues and PRs that improve
accuracy, add support for other note-taking/sync backends, or simplify a step are welcome.

Before opening a PR:

- Test any Docker Compose / script changes against a real (or throwaway) instance where possible.
- Keep documentation in `docs/` in sync with any behavioral change.
- Avoid adding cloud-only dependencies to the default path — the goal of this project is to stay
  fully self-hostable.
