# Bootstrap swarm

Run the native compiler bootstrap described in `agents/bootstrap.md` using
the gnat skill and its bundled profiles unchanged. This is also a test of
gnat's default workflow; do not supply custom agent instructions.

## Willow-specific context

- Repository: `kkestell/willow`; swarm: `willow-bootstrap`.
- Target branch: `main`. Use merge commits. Commits have a subject and body
  with no attribution trailers.
- Agents run on Linux arm64; the local operator provides the macOS arm64
  validation required by `AGENTS.md`.

`agents/bootstrap.md` defines the design and milestones; `docs/spec.md`
defines language behavior. `AGENTS.md` defines repository conventions and
validation. Keep those requirements in their existing documents.
