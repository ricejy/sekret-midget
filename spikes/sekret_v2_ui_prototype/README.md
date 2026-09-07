# Sekret v2 UI prototype

> THROWAWAY PROTOTYPE — this is not production Flutter code.

Question: **Which information hierarchy best balances general chat, explicit source provenance, a useful Knowledge Base catalogue, and restrained privacy controls on iPhone?**

The prototype contains three structurally different variants of the complete three-tab shell. State is fictional, local to the browser tab, and never persisted.

## Run

From the repository root:

```sh
python3 -m http.server 4173 --directory spikes/sekret_v2_ui_prototype
```

Then open <http://127.0.0.1:4173/?variant=A&tab=chat>.

Use the floating arrow control or the keyboard Left/Right arrows to switch variants. Use the in-phone tab bar to compare Chat, Knowledge Base, and Settings within each variant.

## Variants

- **A — Native Focus:** familiar iOS hierarchy with a quiet navigation bar, open transcript, and compact controls.
- **B — Context Shelf:** makes mode and selected knowledge unusually prominent in a persistent top shelf.
- **C — Quiet Workspace:** groups the current activity into soft surfaces and makes the composer the visual anchor.
