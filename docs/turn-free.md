# Turn-free Silkwire: plan

Goal (Jason, Nov 2): teammates work autonomously, anyone can chime in any time, several conversations can run side by side, and nobody waits on "turns".

## How it worked before step 2

- One room has one active request (`busy`). While it runs, Jason's new text is queued and delivered when the whole round ends (`queueDraft` / `afterTurn`). (Step 2 replaces this; see below.)
- Open floor sends Jason's message to everyone at once, but nobody sees anyone else's reply in that round.
- Pass lets the team keep going for up to 6 replies without Jason.
- Computer-control tasks continue automatically between replies (`continueTasks`).
- Background builds and tests already run outside the room and post results back.

## Steps

1. **Chime-in (built, claude/turnfree-1).** After an open-floor round Jason started, if at least two teammates gave real replies, each of them gets one short chance to respond to the others. PASS stays hidden. It never chains, never follows Silkwire's own rounds, and Jason's queued message always goes first. Setting: "Let teammates respond to each other afterwards" (on by default, only with open floor).
2. **Talk any time (prototype, claude/turnfree-2).** Replace the single room-wide `busy` with per-teammate state. A message Jason sends mid-round goes immediately to teammates who have finished, and to the rest as soon as they finish. Stop becomes per-teammate.
   - Store: one `Outgoing` record per live message (saving, accepted, the draft it took) replaces `activeRequest`/`accepted`/`sentDraft`. `busy` now means "at least one message is still with the team"; Send stays available while busy. The queue (`queueDraft`/`afterTurn` delivery) is gone; a legacy saved addition still returns to the composer at launch.
   - Room: sends carry `waitForBusy`. A teammate still on an earlier message is marked waiting and started by `pump()` the moment they go idle. Each teammate takes messages one at a time, oldest first. A late start adds replies that finished meanwhile to its context. In turn-taking mode free teammates go first.
   - Stop: the whole-team Stop is unchanged and also cancels waiting messages. A teammate's own Stop (the stop icon beside a working teammate's name) ends their current reply and their running tasks here, and cancels anything waiting for them; everyone else keeps going. A message sent afterwards reaches them.
   - Safety kept: each message is durably saved before dispatch; a composer still showing an unsent message can't send it twice; an unsent message returns to the composer in front of anything typed since; replies to two live messages never trade places across Jason's message, and the transcript still gives one speaker the floor at a time.
   - Automatic rounds (Pass, chime-in, task continuation, job follow-ups) still start only once the room is quiet, so Jason's mid-round message is always answered first.
   - A teammate's Stop also covers messages still being saved: they go only to the other recipients (or, with nobody left, are marked Not sent and return to the composer). A message sent after the Stop reaches them.
   - Known limits: reconnecting one teammate still needs the whole room idle; the completion chime plays only when every live message has completed.
3. **Unprompted updates.** A teammate with a running task or background job can post a short progress or result note into the room on its own when something meaningful happens (job finished, blocker found), instead of waiting for the next prompt. Rate-limited, labelled as from that teammate, never treated as Jason.
4. **Many conversations at once.** Let more than one room have live requests, one connection set per room, with a per-room unread/working badge. Then side-by-side columns (two or three rooms visible at once).
5. **Own space.** Each teammate gets a persistent private workspace and task list that survives restarts, so long work continues while the room stays free for conversation.

Safety stays the same at every step: the ask-first list, private workspaces, receipts for every claim, and no stable upgrade or publish without Jason.
