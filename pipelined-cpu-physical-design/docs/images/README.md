# Screenshots

`scripts/make_report.py` looks for these exact filenames and places each one in
its own section of the generated report, with the caption written for it. A
missing file is skipped silently, so the report is always complete and grows
better as these arrive.

| File | What to capture | Why it earns its place |
|---|---|---|
| `die-routed.png` | The whole routed core, all layers visible | The one image that makes "I laid out a chip" concrete |
| `die-zoom.png` | A few rows zoomed until individual cells are legible | Shows what a standard cell row physically *is* |
| `die-critical-path.png` | The worst setup path highlighted across the die | Pairs with the timing section, and shows the adder chain crossing the core |
| `die-modules.png` | Cells coloured by RTL module | Proves the register file dominates the area, visually |
| `clock-tree.png` | The synthesised clock tree | Pairs with the CTS explanation |
| `congestion.png` | Routing congestion map | Shows where the router struggled, and why utilisation matters |

## Capturing them

All of these are GUI views. Run Innovus **without** `-no_gui`, restore the
final database, then use the layout window.

```
innovus
restoreDesign enc/06_final.enc.dat pipelined_cpu_core
```

**The `.dat` matters.** `restoreDesign` takes the session *directory*, not the
`.enc` script file sitting next to it. Passing the file gives you
`IMPSYT-7338 ... could not be located`, which sounds like the database is
missing and never is.

Menu paths move between versions, so treat the names below as what to look for
rather than as an exact route.

- **Whole die**: `fit` in the console, then the camera icon or
  `File > Save Image`. Prefer saving from the tool over an OS screenshot: it
  renders at a higher resolution than the window.
- **Zoom detail**: `zoomBox` with a small region, or zoom until the cell
  outlines and their metal1 rails resolve.
- **Critical path**: the Timing Debug view. Report the path first, then
  highlight it, so the drawn path is provably the one in
  `reports/40_final_setup.rpt`.
- **Module colouring**: the Amoeba or module view in the display control
  panel, which colours instances by the hierarchy they came from.
- **Clock tree**: the CCOpt clock tree debugger.
- **Congestion**: the congestion map layer in the display controls, after
  routing.

## Two things worth doing while the GUI is open

1. **Turn layers off one at a time.** Hiding signal routing leaves the power
   grid alone, and that is a clearer picture of the ring and straps than
   anything with metal2 drawn over it.
2. **Save the images at a width of at least 1600 px.** They are placed 6
   inches wide in the report, so anything smaller looks soft in print.
