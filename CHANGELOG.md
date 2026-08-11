# Changelog

## [Unreleased]

## [0.1.1] - 2026-07-19

### Added

- DocC documentation for all three modules, published to GitHub Pages as one combined site with
  `MediaAgent` as the entry point, plus getting-started articles for `MediaAgent` and `MediaStore`.
- An installation section in the README, pointing at a released tag.
- LICENSE and the standard CI workflows.

### Changed

- Doc comments rewritten for quality across the public API; the README split into English and
  Japanese.

## [0.1.0] - 2026-06-08

First release. Gives an AI agent the images and charts it needs to show someone, and keeps the
bytes locally so the references outlive the URLs they came from.

### Added

- `MediaStore`: a session-scoped store that validates image bytes by magic bytes and an ImageIO
  decode before writing them, deduplicates by SHA-256, versions filenames on collision, and hands
  back `media://` references that survive a change of container directory.
- `MediaAgentTools`: image generation, image and video search, chart rendering, and YouTube
  reference tools. Capabilities whose provider is not configured are absent from the toolkit
  rather than failing when called.
- `MediaAgent`: the visualizer agent's system prompt, agent card and tool set, all derived from
  one set of enabled tool identifiers so they cannot disagree about what the agent can do.
- A `language` parameter on the system prompt.
