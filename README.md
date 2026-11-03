# don't get smart trained

An iOS app. It is being built in two stages:

| Folder  | What it is | Status |
|---------|------------|--------|
| `web/`  | **Throwaway** proof of concept, used to test the idea, flows and screens quickly in a browser. It is not meant to ship, and its code will not be reused. | Active |
| `ios/`  | The real app: fully native Swift/SwiftUI, with no cross-platform frameworks (no React Native, Flutter or web views). | Starts when the new Mac arrives |
| `docs/` | Product notes, screens, the data model and the decisions we make along the way. Both versions share these docs, and they are what carries over from web to iOS. | Active |

Everything lives on one `main` branch. Platforms are folders, not branches.

## Web prototype rules
- Optimize for speed of learning, not code quality.
- Design for a phone-sized screen, so it maps cleanly to iOS.
- Write anything worth keeping (decisions, flows, edge cases) in `docs/`, because the code itself gets thrown away.
