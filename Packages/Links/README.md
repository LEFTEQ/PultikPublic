# Links

The deep links between the apps, built and parsed in one place. Every `pultik://` URL and
every agent-shell session link is made by a builder here and read by a parser here; an app
never writes or splits one by hand.

| Link | Type | Opens |
|---|---|---|
| `pultik://pr/<owner>/<repo>/<n>` | `PultikLink.pr(repo:number:)` | The PR's detail in Pultík's PRs module |
| `pultik://panel/prod/<key>` | `PultikLink.prod(key:)` | Prod with that deployment selected (a prod notification's click) |
| `pultik://panel/<rail>` | `PultikLink.panel(rail:)` | The panel with that rail unfolded (`firing`) |
| `<scheme>://session/<session>` | `SessionLink(scheme:session:)` | The agent shell's canvas on that session's agent |

- `pultik://pr/…` is in the wild (status lines, notifications, PR descriptions), so its
  grammar only ever gains cases. `PultikLink(webURL:)` turns a GitHub PR page into the link
  that opens it in Pultík; `webURL` is the way back.
- A session link's `session` is whatever the caller knows the session by: the shell's agent
  id or name, or the harness's own session id (Claude's `session_id`). The shell resolves it.
- Every value travels as one percent-encoded path segment, so names with spaces, `/` or `%`
  round-trip. Parsing is strict: any page can fire a scheme, so a link only ever selects
  something to look at, and anything malformed is nil.

## Neutral by design

The package names no agent shell. `SessionLink` takes the shell's scheme from the app that
owns its brand: the shell passes its brand file's scheme, and Pultík reads it from its
Info.plist, which its manifest fills from that same file. So the package publishes with
Pultík unchanged.

## Use

```swift
import Links

PultikLink.pr(repo: "octo-org/hello-world", number: 12).url   // pultik://pr/octo-org/hello-world/12
PultikLink(url)                                                // parse; nil when malformed
SessionLink(scheme: scheme, session: "api-7")?.url             // <scheme>://session/api-7
SessionLink(url, scheme: scheme)?.session                      // "api-7"
```

`swift test --package-path Packages/Links` runs the round-trip tests.
