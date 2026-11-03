# Jev

Jev is TypeSafe's System One model. It is **not** a text generator: it cannot emit YAML, JSON plans or free-form action descriptions. It answers *typed questions about state* and returns values with calibrated probabilities:

- **Choice** — pick one option from a closed set → `{ choice, probabilities, confidence }`
- **Score** — rate against ordered levels → `{ score, legend, confidence }`
- **Noul** — yes/no → probability that it's yes

So **Swift code enumerates the candidate actions** (from the flattened element list) and Jev only *chooses among them* and *judges whether the goal is met*. Decomposition rule from the docs: many small atomic questions, batched into one request, composed in code — not one sprawling question.

## One step

As built in `JevAgent.step()`:

1. `ScreenInspector.readScreen()` → the driver's read, flattened to `[UIElement]`.
2. Candidates = `elements.filter(\.isActionable)`. Code enumerates them as `e0…eN`; Jev never sees a free-form action space.
3. One request, two or three questions: `next_element` (Choice over the candidates plus `ninguno`, `scroll_abajo` and `scroll_arriba`), `goal_reached` (Noul), and — only when the instruction contains literal text to type — `text_to_type` (Choice over strings extracted from the instruction by regex, never generated).

   The two scroll options matter more than they look: candidates are only the **visible** elements, so without them an off-screen target strands the loop. They belong in the same Choice rather than a separate question — it is one decision, not two. They do not map to an element, so `element(for:)` only accepts `eN` keys.
4. Code gates on the numbers: act above `minimumConfidence` 0.6, declare success above `goalThreshold` 0.5, hand the decision to the user otherwise, and stop at `maxSteps` 10.
5. Destructive gate, only for an element tap chosen with confidence in [0.6, 0.9): a second request asks a `destructive` Noul about that one element (delete, discard unsaved changes, send, pay, sign out, reset). At `destructiveRisk` 0.5 or more the tap needs `destructiveConfidence` 0.9, so the step stops with `needsUser` and `heldForRisk` set. A rating request that fails counts as destructive. At 0.9 confidence or more no rating is asked: the tap already clears the destructive bar. Scrolls are never rated. It is a second request because the element is only known after the first one answers.
6. Dense screens: above `maxCandidates` 60 actionable elements, `next_element` offers the regions instead (`r0…rN`, each with its count and five sample captions), and choosing one is a step that only looks: `drilledRegion` is set and later steps offer that region's elements plus `ver_todo`, which gives the whole window back. A region that empties or goes away also gives it back.
7. The tap goes through `ScreenInspector.tap(_:seenIn:)` with the reading Jev decided on. If the screen changed up to that element while Jev was thinking, the step ends as `screenChanged` and the run goes on with a fresh read; it does not count as an error.

Never act on a low-confidence Choice. A "dead end" Noul was sketched originally and never built; add it only if a real flow needs it.

## API

No Swift SDK exists (Python and JavaScript only). Call the HTTP endpoint directly with `URLSession`:

```
POST https://api.typesafe.ai/v1/systemone
Authorization: Bearer $TYPESAFE_API_KEY
Content-Type: application/json

{ "state": "...", "model": "jev-latest", "questions": { "<name>": { "type": "choice|score|noul", "instructions": "...", "criteria": ... } } }
```

Docs: https://docs.typesafe.ai/llms.txt is the index — fetch it first, then the specific `.md` page. Relevant: `/api.md`, `/primitives.md`, `/confidence.md`, `/patterns/fan-out.md`, `/patterns/confidence-routing.md`, `/model-jaggedness/jev-1.13.md`.

The key comes from https://console.typesafe.ai/keys and reaches the MCP as `TYPESAFE_API_KEY` in its environment: the Fingertip app keeps it in the Keychain and passes it when it registers the server (`claude mcp add … -e TYPESAFE_API_KEY=…`).
