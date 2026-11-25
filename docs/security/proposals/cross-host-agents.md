# Proposal: agents across hosts, and images from the owner's devices

Status: proposal. Feature 1 is not built and waits for the owner's decisions below. Feature 2
reuses what exists and is built as described in its section.

Two requests:

1. An agent's tools (`pane_*`, `tab_new`, `cmd_run`, `agent_*`) should reach every tab and pane
   the owner has, on other hosts too. Today they act only on the host the agent runs on.
2. The owner, on an iPad, iPhone or another Mac, should be able to hand an image (a screenshot,
   a photo) to an agent on a host. Only if it can be done securely.

Terms: host A runs the agent; host B is another host the owner paired. "The app" is any owner
device (paired in `devices.json`), never a guest connection.

## Invariants this must keep

Quoted from the threat models:

- "Own panes only, without asking. An agent types into, runs in and closes the panes it (or its
  workers) opened; never its own pane [...], never another session's." (agent-terminal.md)
- "The user's panes need the owner's yes, for one exact action. [...] The owner's signed answer
  releases only the waiting call, which does exactly that." (agent-terminal.md)
- "Only the owner answers. Guests never get the request and their `Decide` is refused and
  audited, whatever roles they hold." (agent-terminal.md)
- "Passwords are the user's. Input is refused at a password prompt before asking and again
  right before typing." (agent-terminal.md)
- "Event stream. Agents see only their own session's events." (agent-terminal.md)
- "Every device on [`devices.json`] is a full owner, with a shell as the user." and "Driver means
  a shell." (transport-identity.md)
- "The grant is checked on every ctl message, input frame, workspace request and stream"
  (ARCHITECTURE D18), and "Revoking a grant also covers every chain that passes through it."
- "A host is not trusted with this device" and "A guest connection (someone else's host) never
  announces the browser capability." (apple-client.md)
- "The same user is fully trusted. Every process running as the user can read `hook.token`, the
  iroh key and the grant store." (host-local.md)
- "A sketch sent to an agent pastes only a path the daemon wrote, escaped, without Enter."
  (transport-identity.md)

The last but one matters most for feature 1: anything host A's daemon holds, an agent on A
with a shell can read. A credential for B kept on A is a credential for B in the agent's hands.

## Feature 1: agents reaching other hosts

### What an attacker gets today

An agent with a shell on A and the user's SSH key for B can already do anything on B. That is
outside Gudo and is the bar not to lower further: whatever we build must give an injected agent
less than that, and must not make it easier.

### Option A: the app relays, the owner approves on the device

The agent calls a tool with `host: "<name>"`. A's daemon sends the request to its connected
owner devices (a new `ServerCtl` push, offered only to clients announcing a new `Caps` bit).
The app checks that B is a host it is paired with as owner, that the owner turned on "Agents on
A may reach B", shows the request, and on Allow performs it on B over its own connection to B.
B runs it as a terminal-tool call made by an owner device on behalf of `(A, pane)`. The result
goes back to A the same way.

- **Who authenticates whom.** Unchanged: the app is an owner on A and on B, each over its own
  iroh connection with its device key. A and B never talk to each other and hold nothing of
  each other.
- **A compromised host A** (or an injected agent on it) can only ask. Every request is shown on
  the owner's device and names A, the agent and the exact action. It cannot act on B while no
  owner device is connected, or when the owner says no. It can flood requests: cap at one open
  request per agent pane and a per-host rate limit, as drive asks do.
- **A prompt-injected agent** gets what the owner approves. Mutating actions (type, run, open,
  close, prompt another agent) need a yes per action ("Allow once") or, named as wider, "for
  this pane until it closes", exactly as drive asks on one host. Reads (list, read a pane) need
  one yes per agent and host, ending when the agent's pane closes. Data read from B flows to
  A's agent, which may send it to its model provider: the read prompt says so.
- **Revocation.** Turn off the per-host switch on the device, or unpair either host. Nothing is
  left on A or B to revoke.
- **Audit.** A records each request and the device's signed answer. B records the action under
  the owner device's principal with `on_behalf_of: (A daemon id, pane)`. The device records
  nothing beyond its settings.
- **App closed.** Nothing happens until an owner device connects. The request waits 120 s (as a
  drive ask), with a push to the owner ("Claude on A wants to run `npm test` on B"); opening
  the app relays it. The owner's Mac app, usually open, covers the common case.
- **Guests and shared sessions.** Requests go to owner devices only, never a guest's. A guest
  who prompts or drives A's agent can steer it to ask: the prompt names that guest ("asked
  while bob is driving"), like askpass. A host the device joined as a guest is never a target.
- **Relay exposure.** None new: both legs are the existing end-to-end encrypted connections.
- **Invariants.** All kept. On B, panes the remote agent opens are tracked as owned by
  `(A, pane)` so "own panes only" holds per agent; the user's panes on B go through B's drive ask
  (answered by the owner, who is the one approving anyway); password prompts on B are refused by
  B. The one new thing is a host asking the device to act elsewhere ("a host is not trusted with
  this device"): hence off by default, per pair of hosts, and every action visible.

### Option B: host-to-host pairing as a scoped guest

B's owner issues a grant chain (`crates/grants`) to A's daemon key, scoped to a session, tab or
pane, with roles (Viewer, Prompter, Driver). A's daemon dials B as a guest and forwards tool
calls. This is what the "Cross-host tools" sketch in DAEMON.md §9 describes.

- **Who authenticates whom.** B verifies A's key and the chain on every message (§6.2).
- **A compromised host A** holds a live credential for B. Since the same user is fully trusted
  on A, any process on A, the agent's own shell included, can read `daemon.key` and use the
  grant directly, without the daemon and without any prompt. With Driver it has a shell on B
  ("Driver means a shell"); with Prompter it can steer B's agents, which may run with bypassed
  permissions. Compromise of A becomes compromise of B: lateral movement by design.
- **A prompt-injected agent** can open panes on B and run in them without asking, since panes it
  opens are its own. B's drive asks protect only the user's panes on B.
- **Revocation.** Good: revoke the grant on B, effective at once.
- **Audit.** Good: B audits under the guest principal and grant id.
- **App closed.** Works. That is its one real advantage, and the reason it is dangerous.
- **Guests.** A is itself a guest on B, so B's guest rules apply (no browser, no askpass,
  no answering approvals).
- **Relay exposure.** A new long-lived connection A to B through the relay (metadata only).
- **Invariants.** Formally kept, but it turns "the same user is fully trusted" on A into "trusted
  on B too", which no current invariant allows.

### Option C: SSH

The agent, or A's daemon, runs `ssh B gudo ...` with the user's keys. No scoping, no approval,
no Gudo audit, and it works only where SSH reaches. It is what an agent can already do on its
own. Gudo should not build on it or make it easier.

### Choice

**Option A.** It adds no standing credential and no new trust edge between hosts, every action is
visible to the owner, guests are out by construction, and revocation is a switch on the device.
Its limit (an owner device must be connected) is the security property we want: an agent never
acts on another host while nobody is there to see it.

Narrowest defaults: off; per pair of hosts (A to B, not B to A); verbs `read` (pane_list,
pane_read, pane_wait), `open` (tab_new, pane_split, agent_spawn), `input` (pane_send, cmd_run,
agent_prompt) and `close`, each a separate switch, only `read` on when the owner first enables
a pair; mutating verbs always asked per action or "for this pane"; never `events_wait`
fan-out across hosts; everything audited on both hosts.

### Verdict

**Needs owner decisions.** Not built. Questions:

1. Option A (relay through the app, owner present) over B (hosts trust each other, works
   unattended)? Recommended: A.
2. Is "nothing happens while no owner device is connected" acceptable? Recommended: yes; the
   Mac app is usually open.
3. Reads: one yes per agent and host (recommended), or per call?
4. May a remote agent open panes on B and then run in them without asking each time, as it can
   on its own host? Recommended: no; on another host every input is asked, "for this pane" the
   widest answer.
5. Which devices may relay: any owner device (recommended), or only the Mac?

## Feature 2: images from the owner's devices to an agent

### What exists

Most of this is already built and already inside the trust model:

- **Send to agent** (DAEMON.md §7.4, `ArtifactRequest::Send`). The app sends a PNG or JPEG to an
  agent pane on the host the user picked, over its own connection; it is kept as an image
  artifact of that session, written to `<state>/artifacts/<session>/send/<id>@<version>.<ext>`
  (0700 state dir, atomic) and its escaped path is pasted into the agent's input without
  Enter. Claude Code and Codex attach it. Audited. Policy: prompter or driver, agent panes only,
  pane in scope; guests are rate limited. Larger images go as a blob (32 MiB cap, PNG or JPEG
  sniffed from the header, 1 GiB store).
- **Reading**: `list_drawings` and `get_drawing` already list and return the session's image
  artifacts to its agents, and only that session's.
- **Entry points**: Mac Option-drop onto an agent pane; dragging a placement onto an agent pane;
  on iPhone and iPad, the chat view's "Upload photo to host…", which re-encodes the photo and
  uploads it through the Files API to `~/Downloads/<Brand>-Attachments/`.

The agent never pulls anything: images move only when the user drops, pastes or picks one.

### Gaps

1. **Metadata.** Bytes from a drop or a file go up as they are: a JPEG's EXIF (GPS position,
   camera, time), XMP and IPTC, a PNG's text and `eXIf` chunks reach the host, the agent and
   its model provider.
2. **No way in on iPhone and iPad** for a terminal agent pane: images dropped from Photos are
   ignored, and the photo picker exists only in the chat view.
3. **Retention.** Deleting the image artifact leaves its send copy in `send/` until the session
   closes.

### Design (built)

- **Strip on the device, and again on the host.** `drawing::strip_metadata` keeps only what
  draws the image: PNG critical chunks, transparency, colour (`gAMA`, `cHRM`, `sRGB`, `iCCP`,
  `sBIT`), `pHYs`, `bKGD` and APNG frames; JPEG frames, tables, JFIF, ICC profile and Adobe
  colour markers, plus the EXIF orientation alone (rebuilt as a minimal EXIF), so a photo is
  not turned on its side. client-core strips before any upload (`send_to_agent`,
  `import_to_pane`, `blob_upload`), so the position never leaves the device; the daemon strips
  what it stores from inline images and what it hands an agent (the send copy and `get_drawing`
  exports), so images from older apps are clean too.
- **The app writes pictures it sends again from their pixels** (ImageIO, orientation applied,
  at most 2048 px on the long side, PNG stays PNG, anything else JPEG, no metadata), as the
  chat view already does for photos.
- **Entry points**: "Send Image to <agent>…" in the pane menu of an agent pane (the photo
  library on iPhone and iPad, a file on the Mac), and on iPhone and iPad an image alone dropped
  on an agent pane is sent to it. The host is the one whose pane the user picked. Viewers get
  no such entry, and the daemon refuses them anyway.
- **Retention**: deleting an image artifact deletes its send copies; closing the session
  deletes everything (as today).
- **No wire change.** The request, roles and storage are the existing ones, so there is no new
  capability bit and nothing for old apps or old daemons to learn: a new app stripping images
  works with any daemon, and a new daemon strips what old apps send.

### Trust model

Within the current one, unchanged: an owner device sends its own content to its own host by an
explicit action, over the existing authenticated connection, through a request already gated
by `policy::check`. Nothing new reaches the device from a host, and no host file is read. The
invariant "a sketch sent to an agent pastes only a path the daemon wrote, escaped, without
Enter" holds as it is.

Guests: a Prompter or Driver on the pane can already send an image (as they can type a prompt),
rate limited and audited; a Viewer cannot; a guest whose scope does not include the pane can
neither send to it nor see the image. Tests pin each.

### Verdict

**Safe to build as designed** (built). Owner decisions, none blocking:

1. Should guests with Prompter keep the right to send images to an agent? Recommended: yes, it
   is the same as typing a prompt, and already rate limited.
2. Pasting an image into an agent pane, or dropping image files on it: decided yes and built
   (DAEMON.md §7.4.1, `PasteImage`): the pictures go to the agent through a per-pane store on
   its host. Panes running no agent paste as before.
3. Retention beyond the session: delete send copies after a fixed age (say 30 days)?
   Recommended: not now; they go with the image or the session.
