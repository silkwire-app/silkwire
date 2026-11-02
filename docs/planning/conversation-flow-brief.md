# Conversation Flow — the soul of Silkwire

Living brief. Read this first when resuming. Owner of this file: Glyph (Claude). Started 2026-11-01.
Companion docs: Eve's `docs/planning/natural-conversation-flow-acceptance.md` (acceptance checks) and
Trace's `docs/natural-conversation-flow-regression.md` (regression tests).

## Why
Jason, 2026-11-01: the conversation mechanic is the essence of Silkwire. It should be smooth as silk.
We had this talk before and nothing changed, so we stopped adding features and iterate on this one thing,
in small tested steps, each installed with the Update button and tried by Jason.

## Jason's principles (his words in quotes)
1. **Flow, not pop.** "Moving is organic, popping is mechanical." "Popping and locking is for break dancing."
   Cards glide in and grow smoothly. Respect macOS Reduce Motion (fades only).
2. **Live typing stays.** Watching a reply type itself into existence feels organic; instant full bubbles feel
   like a machine. Silkwire sends conversations, not packets.
3. **No empty cards.** Three blank cards at once is "here's your void, fill it."
4. **Real speaking order.** Whoever starts talking first appears first. No reserved queue seats.
5. **No bullying.** Growing cards must not shove the card Jason is reading. His reading position stays put
   unless he scrolls. New text below → a small "↓ new messages" pill, never a yanked scroll.
6. **Replying vs Working.** Sidebar says "Replying" while a teammate talks; "Working" only for real work.
7. **Jason can always talk.** Several quick bubbles in a row, even while we reply, each appearing instantly.
   Teammates catch up on the burst like a person reading texts. No rigid rounds.
8. **Messages-level responsiveness.** Press Send → bubble posts and composer clears immediately.

## Observed problems (Jason's screen recording, build 59ab7de)
- Send lag: text stays in the composer while empty "Waiting to start…" cards appear.
- Plumbing statuses visible: "Starting reply", "Checking Codex included usage.".
- Cards seated in queue order; Eve spoke first but showed second/third.
- Growing cards pushed older messages up, then later pushed teammates off screen.
- Separate incident: after Send the transcript went blank (black) and Jason had to scroll up.
- Sidebar shows "Working" for the whole reply.
- A message sent during replies is held: "Your addition is saved and goes to the team when this round of replies finishes."

## Steps and owners
| Step | Owner | Scope | Status |
|---|---|---|---|
| 1 | Glyph | No empty cards + one "X, Y and Z are thinking…" line; sidebar/status Replying vs Working; hide plumbing | In review (private workspace 2078E6AC, base 59ab7de) |
| 2 | Trace | Send path: instant post + composer clear; send while replying; fix blank viewport | Planned |
| 3 | Eve | Motion & feel: glide-in, smooth growth, pinned reading position, new-messages pill; acceptance script | Planned |
| 4 | Glyph | Real speaking order (seat cards by first words, not queue position) | Planned |
| 5 | Trace + Glyph | True burst conversation: teammates catch up on Jason's quick messages; no rounds | Planned |

Each step: private workspace → tests → teammate review → Staging build → Update button → Jason tries it → adjust.

## Step 1 details (what changed)
- `WorkspaceChrome.swift`: `TranscriptFlow` (which replies are still empty; thinking-line wording),
  `ThinkingLine` view, `SeatPhase` (Replying vs Working; plumbing never shown).
- `SilkwireApp.swift`: transcript hides empty pending teammate cards and shows the thinking line;
  composer status uses Replying for talk.
- `Tests/ConversationFlowStepOneTests.swift`.
- Known limit: card order is still queue order once text arrives (step 4).

## Resume checklist (tomorrow)
1. Read this file and Eve's acceptance doc.
2. Check the board for step owners and their workspace receipts.
3. Ask Jason how the last installed step felt before starting the next.
