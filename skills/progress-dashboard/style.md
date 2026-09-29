# Sam's dashboard style (chosen 2026-09-27 from a reference screenshot)

- Theme: dark. Background #0b0b0e, cards #121216 with 1px #24242c borders, 10px radius.
- Density: dense but calm. 14px Inter/system text, 13px muted secondary lines, no shadows, no gradients.
- Accent: one violet, #8b7cf6, for progress bars, the in-progress row and counts.
- Status pills: dot + label on a tinted background. Green done, violet in progress, grey to do,
  amber "Using default", red blocked.
- Layout: header (task title, one meta line with context, Started, Running, Updated · ago, status pill
  top right), a single strip of stat tiles, then Tasks on the left and Questions / Blockers /
  Deliverables stacked on the right.

The renderer in assets/index.html already implements this. Change it only when Sam asks for a
different style, and update this file in the same edit.
