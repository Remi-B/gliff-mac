# 10 — implement-displays-and-reconnection

Status: planned. Dependencies: [08](../render-full-chroma-metal/README.md),
[09](../implement-remote-input/README.md).

## Outcome

Make a real remote session usable across display changes, link loss, sleep/wake
and app lifecycle transitions without stale video, input or child processes.

## Work

- [ ] Support mirror selection and private/headless mode through upstream server
  options and handshake output/session information. Follow actual server behavior
  rather than inventing new wire commands. Persist display mode with host metadata.
- [ ] Debounce resize/fullscreen/Retina changes and send valid headless geometry.
  Mirror mode preserves remote dimensions and fits the view. Handle remote output
  removal, scale-only/fps-only configuration changes and server downscaling.
- [ ] Add bounded reconnect backoff with cancellation. Retry recoverable link/setup
  errors; surface fatal protocol/capability/auth failures without endless retries.
  Distinguish user disconnect from temporary network loss.
- [ ] Start each reconnect with a new generation, fresh handshake/decoder state,
  capability evaluation and correct input release. Reject callbacks from old SSH,
  session, decoder and display instances.
- [ ] Handle sleep/wake and network changes, background/foreground and window close.
  Bound queued input and avoid replaying old keystrokes after reconnect. Re-establish
  clipboard offers only under task 11's current ownership policy.
- [ ] Verify SSH teardown removes headless outputs server-side. Ensure cancellation
  waits for workers/decoders and reaps the child even if a peer stalls.
- [ ] Keep statistics for phase, retries, stream/chroma, decode delay and queue
  pressure without logging desktop contents. Multi-session UI polish can follow,
  but lifecycle and active-owner state must already be per-session.

## Deliverables and acceptance

- Real mirror/headless tests include fullscreen, repeated resizing, Retina display
  moves and remote geometry changes with correct input alignment.
- Disconnect, process kill, stalled peer, network drop and sleep/wake recover or
  present actionable errors; manual stop/quit cancels backoff immediately.
- Repeated connection cycles leave no orphan SSH processes, headless outputs,
  retained native buffers, pressed input or stale callbacks.
- Replay tests exercise configuration changes between compressed input and delayed
  decoded output, including late main/aux pairs across reconnect generations.
