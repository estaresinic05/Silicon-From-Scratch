# Content License

Copyright (c) 2026 Elliot Staresinic. All rights reserved.

This repository exists so that people can clone the designs and build them.
The designs are free to use. The writing around them, and the name, are not.

## What the MIT License covers

Everything you would run, simulate, synthesize or place and route is under the
MIT License in [`LICENSE`](LICENSE):

- the Verilog RTL and testbenches in every `rtl/` and `sim/` directory, for the
  ALU, the single-cycle CPU, the pipelined CPU and the physical design variant;
- the Makefiles and simulation setup;
- the Genus and Innovus Tcl flow, the Python helpers, and everything else under
  `scripts/`;
- the generated timing, area, power, DRC and LEC reports under `results/`.

Take them, modify them, teach with them, ship them, with attribution as the
MIT License requires.

## What is all rights reserved

The written and visual material is **not** licensed for reuse, and no
permission is granted by its presence in a public repository:

- **The reports.** The design verification reports and the physical design
  report under the `docs/` directories, in every format they appear in.
- **The README prose**, in this file's siblings at the root and in each
  project, including the project descriptions, the explanation of the flow,
  and the ordering of the curriculum.
- **The figures.** The architecture drawings, the die and layout images, and
  the waveform screenshots under `docs/` and `waveforms/`.
- **The name and branding.** "Silicon From Scratch", the logos under `docs/`,
  and the visual identity. Silicon From Scratch is a trademark of Elliot
  Staresinic. You may not use the name or logo to describe your own work,
  course, product or repository, or in any way that suggests endorsement or
  affiliation.

You may link to anything here, quote short passages of the reports or READMEs
for commentary with attribution and a link, and cite the work. You may not
republish the reports or figures, present the written material as your own,
or bundle it into a paid course without written permission.

## Third-party material

The physical design flow targets the FreePDK45 process design kit and the
NanGate 45 nm open cell library, each under its own license, and neither is
redistributed here. The Cadence tools the flow drives are licensed separately
by Cadence. The open-source simulators the RTL projects run on are named in
the README and belong to their authors.

## Permission

For anything the section above does not allow, ask. Open an issue on this
repository or contact the author through the GitHub profile
[estaresinic05](https://github.com/estaresinic05).
