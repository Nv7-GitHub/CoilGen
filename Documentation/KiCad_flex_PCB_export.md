# Flex PCB gradient coils with CoilGen and KiCad

This guide covers the full workflow for building CoilGen coils as rolled 2-layer flex PCBs:

1. Design the coil on a cylinder with a slit (the seam of the rolled board).
2. Export it as a KiCad board with both copper layers in series, design rules included.
3. Check the board: KiCad's DRC, plus a same-net check the DRC can't do.
4. Read the board back into CoilGen and re-simulate the copper that will actually be made.
5. Look at the coils in 3D with CoilGen's plotting functions.
6. Build and align the coils.

The worked example is a 3-axis gradient set for a 45 mT Halbach magnet: `Examples/halbach_flex_pcb_gradient_set.m`. It runs steps 1–4 for all three coils.

| File | Purpose |
|---|---|
| `sub_functions/build_slit_cylinder_mesh.m` | Cylinder mesh with an axial slit (`'create slit cylinder mesh'`). |
| `sub_functions/export_kicad_flex_pcb.m` | CoilGen result → `.kicad_pcb` + `.kicad_pro`. |
| `sub_functions/import_kicad_flex_pcb.m` | `.kicad_pcb` → CoilGen result, re-evaluated with CoilGen's own field routines. |
| `sub_functions/strip_coilgen_result.m` | Keeps only the fields the plotting functions need, so a result can be saved compactly. |
| `Examples/halbach_flex_pcb_gradient_set.m` | Designs, exports, checks and re-simulates the Halbach gradient set. |
| `Examples/view_flex_pcb_coils.m` | 3D views and field plots of the re-simulated boards. |
| `KiCad_flex_PCBs/halbach_45mT_gradient_set/` | One KiCad project folder per coil, `coil_summary.txt` for the set. |

## Coordinate frames

CoilGen always optimizes the field component along its own `z` axis, so that axis has to be the main-field (B0) direction. In a Halbach magnet B0 runs across the bore, so the coil cylinder is rotated 90° about `y`. Its axis then lies along CoilGen's `x`.

| Magnet | CoilGen |
|---|---|
| `x` (B0; left → right looking down the bore) | `z` |
| `y` (down, looking down +z with +x to the right) | `-y` |
| `z` (down the bore) | `x` |

Each coil is the gradient of B0 along one magnet axis:
- the Z coil gives dBx/dz;
- the Y coil gives dBx/dy;
- the X coil gives dBx/dx.

CoilGen's plots use the CoilGen frame.

On the board, `x` is the arc length around the circumference and `y` is the axial position (+axial points up on the board). `F.Cu` is the outside of the rolled cylinder.

## 1. Design on a slit cylinder

When the rolled board closes into a tube, its two edges meet at a seam, and no track can cross it. The coil is therefore designed on a cylinder with a narrow axial slit. CoilGen never lets current cross a mesh boundary, so the optimizer itself keeps the seam free of current.

```matlab
coil_out=CoilGen( ...
    'field_shape_function','x', ...
    'coil_mesh_file','create slit cylinder mesh', ...
    'slit_cylinder_mesh_parameter_list',[length radius 60 40 0 1 0 pi/2 slit_angle slit_width], ...
    'surface_is_cylinder_flag',false, ...
    'skip_postprocessing',true, ...   % the exporter builds the wiring itself
    ... );                            % target region, levels, regularization as usual
```

`slit_cylinder_mesh_parameter_list` takes the same values as `cylinder_mesh_parameter_list`, plus two more:
- **`slit_angle`:** the slit centre in radians, as `atan2(y,x)` *before* the rotation is applied.
- **`slit_width`:** the arc width kept free of current, in meters (3 mm in the example).

**Where to put the slit.** Run the closed-cylinder design first, then take the angle where the largest `|stream_function|` along the axial line is smallest. In the example:
- **Z and Y:** both have such a line, at 1.5% and 0.4% of the peak, so the slit costs nothing.
- **X:** its best line still carries 23% of the peak, but the slit design kept the efficiency of the closed one.

Note that `CoilGen` removes `sub_functions` from the path when it returns. Run `addpath('sub_functions')` before calling the exporter or importer.

## 2. Export to KiCad

```matlab
report=export_kicad_flex_pcb(coil_out,'my_coil.kicad_pcb','title','My coil', ...
    'positive_gradient',[1;0;0], 'axis_marks',{[0;0;-1],'-X LEFT'; [0;0;1],'+X RIGHT'}, 'axial_label','+Z into bore');
```

What the exporter builds:

- **Series 2-layer spirals.** Each group of nested contour loops becomes one spiral. It goes inwards on `F.Cu`, through one via inside the innermost turn, and back out on `B.Cu`. Both layers carry every turn, so the efficiency per ampere doubles compared with one layer.
- **No crossovers.** Each turn is opened over `cut_width`. The step to the next turn first crosses to that turn's opening, then follows the turn's own removed section into its start, so steps never run alongside a turn.
- **Inner via.** Each group's via is placed inside its innermost turn, as close to the opening as the clearances allow. Inner turns with no room for it are dropped and reported.
- **Routing channel.** The spirals open towards a copper-free axial band: a free band between the groups (the centre of the Z coil) or a margin beyond the end of the coil (X and Y). The groups are linked in series there on `F.Cu`, and a return trace runs back on `B.Cu` directly under the links. Each group's output continues right next to its input. Together this leaves no net circumferential current and almost no field from the wiring.
- **Feed tab.** A tab sits at the seam, with `J1` on `F.Cu` and `J2` on `B.Cu` directly behind it (a coaxial feed). With `positive_gradient` set, the pads are labelled `+`/`-` so that current into the `+` pad gives a positive gradient.
- **Variable trace width.** Each turn is cut into pieces of at most 1 mm, and each piece is made as wide as the space allows, up to `max_track_width`. The limits are:
  - the clearance to the neighbouring turns, which widen by the same rule;
  - the clearance to all fixed-width copper (steps, leads, links, ties, vias, pads);
  - the board edge;
  - the turn's own other parts where it comes back close to itself (narrow tips). Here the trace may even go below the base width.

  In the example this halves the resistance.
- **One net per turn.** Each turn on each layer is its own net, and consecutive turns are joined by KiCad net-tie footprints (`CoilGen:NetTie_Turn`). The DRC can therefore check the clearance between every pair of turns.
- **Silkscreen.** `axis_marks` draws an axial `F.SilkS` line where the rolled coil faces a given direction (for aligning it in the magnet). `axial_label` adds arrows for the axial direction.
- **Project file.** The design rules go into the `.kicad_pro` next to the board: clearance, edge clearance, via and drill sizes.
- **Coordinate mapping.** The board-to-cylinder mapping is written into the title block (`CoilGen mapping: ...`), which the importer uses.

Exporter options (lengths in mm):

| Option | Default | Meaning |
|---|---|---|
| `track_width` | auto | Base trace width. Auto uses the smallest turn spacing minus the clearance. |
| `variable_width`, `max_track_width` | true, 4 | Widen each turn to the locally available space. |
| `clearance` | 0.15 | Copper clearance. Also written into the `.kicad_pro`. |
| `cut_width` | 6 | Length of the opening in each turn, where the spiral steps to the next turn. |
| `via_diameter`, `via_drill` | 0.6, 0.3 | Inner and link vias. |
| `edge_clearance` | 0.3 | Copper-to-edge clearance rule. |
| `seam_gap` | 0.5 | Gap between the two board edges at the seam once rolled. |
| `end_margin` | 1.5 | Board extension beyond the ends of the coil surface. |
| `tab_length`, `pad_size` | 6, 2.5 | Feed tab and solder pads. |
| `copper_thickness` | 0.035 | Used for the resistance (1 oz = 0.035). |
| `layer_gap` | 0.1 | `F.Cu`–`B.Cu` distance, used for the field check. |
| `title`, `net_prefix` | | Board title and prefix for the net names. |
| `calc_inductance` | true | Filament (Neumann) inductance estimate. |
| `axis_marks` | {} | `{direction (3x1, coil frame), label; ...}`: alignment lines on `F.SilkS`. |
| `axial_label` | '' | Label with an arrow for the +axial board direction. |
| `positive_gradient` | [] | Gradient direction (3x1, coil frame) that counts as positive; sets the pad polarity labels. |

The `report` holds:
- the efficiency and gradient vector (mT/m/A) and the non-linearity, from Biot-Savart on the exported copper (both layers, links, subdivided onto the cylinder);
- the resistance and the track width minimum, mean and maximum;
- the smallest same-net gap;
- the inductance estimate, the turns per group and the number of dropped loops.

## 3. Check the board

**KiCad DRC.** It doesn't need a schematic, because every net is defined in the board file. It checks:
- **shorts:** copper of different nets touching;
- **clearance:** between all nets, so between all turns;
- **continuity:** that every net is connected, so the series chain from J1 to J2 has no breaks;
- edge clearance, and via and drill sizes.

```bash
cd KiCad_flex_PCBs/halbach_45mT_gradient_set
for f in */*.kicad_pcb; do kicad-cli pcb drc --severity-all -o "${f%.kicad_pcb}_drc.rpt" "$f"; done
```

**Same-net clearance.** KiCad doesn't check clearance *within* a net. A turn that came too close to itself (in a narrow tip, for example) would short part of the turn without any DRC error. The exporter narrows turns where this would happen and reports the smallest same-net gap (`report.min_same_net_gap_mm`). It warns when the gap is below the clearance.

All three example boards pass the DRC with 0 violations and 0 unconnected items. Their same-net gaps are ≥ 0.15 mm.

## 4. Re-simulate the manufactured copper

```matlab
[pcb_out,pcb_check]=import_kicad_flex_pcb(coil_out,'my_coil.kicad_pcb');
```

The importer reads the board file itself (tracks, vias, net ties, pads) and follows the copper from `J1` to `J2`. It stops with an error if the chain branches, breaks, or leaves copper unused. It maps the path back onto the cylinder: `F.Cu` outside, `B.Cu` one `layer_gap` inside. The path then becomes the coil's `wire_path`, and CoilGen's own `evaluate_field_errors` and `calculate_gradient` evaluate it.

Because the board file is read, the result reflects the copper as it will be made, including any edits done in KiCad.

**Like-for-like comparison.** Both layers carry every turn, so the ideal reference is the same turns as closed loops on *both* layers. The importer adds the second-layer copy of the contour loops and halves the contour step, so that each ampere in the board counts as two steps of the stream function. The error metrics then compare like with like:
- **`layout`:** the board copper, against the target field;
- **`unconnected contours`:** the ideal closed turns on both layers, against the target field.

`pcb_out` has the same fields as a CoilGen result, so the functions in `plotting` work on it. `pcb_check` holds the number of segments, ties and vias, the copper length, the resistance from the actual trace widths, the gradient (mean and spread over the target region), CoilGen's error values, and whether current from J1 to J2 has the design polarity.

## 5. View the coils in 3D

`halbach_flex_pcb_gradient_set.m` saves a compact copy of each re-simulated result next to its board (`<coil>_coilgen_pcb.mat`, about 3 MB). To open the 3D views and field plots of all three coils without rerunning the design, run this in the MATLAB desktop:

```matlab
cd Examples
view_flex_pcb_coils
```

![Z coil, copper read back from the board, with the resulting field](coilgen_pcb_3d_Z_gradient_bore_axis.png)

The views show the actual PCB copper: the spirals with their steps between turns, the link ring and the seam gap. The field shown is the one this copper produces in the target region. Rotate the views with the rotate tool in the figure toolbar.

## Example results

All values are for 1 oz copper and 0.15 mm clearance, with variable trace width up to 4 mm. The inductance is a filament estimate (±15%), and V (L) is the voltage across it for a 100 µs ramp.

| Coil | Diameter | Track min/mean/max | Turns (both layers) | Efficiency | Non-linearity, 40 mm DSV | R | L | Current for target | V (R) | V (L) | Peak power |
|---|---|---|---|---|---|---|---|---|---|---|---|
| Z (bore axis), 28 mT/m | 65 mm | 0.70 / 1.56 / 4.0 mm | 72 | 7.35 mT/m/A | 0.69 % | 4.1 Ω | 71 µH | 3.8 A | 15.8 V | 2.7 V | 60 W |
| Y, 12 mT/m | 67.5 mm | 0.60 / 1.78 / 4.0 mm | 72 | 19.5 mT/m/A | 0.71 % | 5.2 Ω | 142 µH | 0.61 A | 3.2 V | 0.9 V | 2.0 W |
| X (B0 axis), 12 mT/m | 70 mm | 0.85 / 1.80 / 4.0 mm | 72 | 18.9 mT/m/A | 0.18 % | 5.0 Ω | 143 µH | 0.64 A | 3.2 V | 0.9 V | 2.0 W |

CoilGen re-simulation of the copper read back from the boards. The field errors are the deviation from the target field, relative to its maximum; "ideal" means the same turns as closed loops on both layers.

| Coil | Gradient (mean ± spread) | R from board | Field error, board copper (max / mean) | Field error, ideal turns (max / mean) | J1→J2 |
|---|---|---|---|---|---|
| Z | 7.35 ± 0.05 mT/m/A | 4.14 Ω | 1.36 / 0.35 % | 1.32 / 0.29 % | design polarity |
| Y | 19.52 ± 0.26 mT/m/A | 5.20 Ω | 3.34 / 1.05 % | 0.94 / 0.28 % | design polarity |
| X | 18.88 ± 0.05 mT/m/A | 5.04 Ω | 0.58 / 0.18 % | 0.53 / 0.12 % | design polarity |

The wiring adds almost nothing to the Z and X coils. On the Y coil, the extra error comes from 4 small loops that sat as side branches inside other turns. They can't be reached on two layers, so the exporter dropped them (see Limitations).

**Why Z needs the most power.** With the main field across the bore, a gradient along the bore can't use a Maxwell-pair-like layout, so it's built from four saddle-shaped groups. At a fixed gradient the power doesn't depend on the number of turns: fewer turns lower the voltage but raise the current by the same factor. Only these reduce the power:
- more copper: wider traces (as done here) or thicker copper (2 oz halves the resistance again);
- a lower gradient;
- a longer coil.

Renders of the top side (`F.Cu`):

![Z gradient](kicad_flex_Z_gradient_bore_axis.png)
![Y gradient](kicad_flex_Y_gradient.png)
![X gradient](kicad_flex_X_gradient_B0_axis.png)

## 6. Building the coils

- Check the design-rule values in the `.kicad_pro` against your flex manufacturer before ordering: 0.15 mm clearance, 0.3 mm edge clearance, 0.6/0.3 mm vias, minimum trace 0.6 mm.
- Roll each board with `F.Cu` outside. The two seam edges meet with a `seam_gap` gap, and no track crosses the seam.
- Turn each rolled coil so that, looking down the bore in +Z (B0 from left to right):
  - the `-X LEFT` silkscreen line sits at the left side of the bore;
  - the `+X RIGHT` line sits at the right side;
  - the `+Z into bore` arrows point down the bore.
- Fold the feed tab outwards. Solder the leads to `J1` (outside) and `J2` (inside), and twist them. Current into the pad marked `+` gives a positive gradient; on the Y coil that is `J2`.
- Nest the coils: Z (65 mm) inside, then Y (67.5 mm), then X (70 mm). Line up the axial centres.

## Limitations

- Only single-part coils designed on a `'create slit cylinder mesh'` surface are supported.
- When a loop contains more than one nested set of loops, only the largest branch is kept, and the others are dropped with a warning. These small side-branch loops can't be reached on two layers. The re-simulation shows their effect: about 2.4 % more maximum error on the Y coil.
- Inner turns with no room for the via are dropped and counted in `report.dropped_loops`.
- The inductance is an estimate (±15%), not a FastHenry result. The inter-layer capacitance, and so the self-resonance, isn't calculated. Measure the self-resonance once a coil is built, and check it is well away from your RF frequency.
- The importer expects boards written by `export_kicad_flex_pcb`: it needs the mapping in the title block and the `CoilGen:NetTie_Turn` and `CoilGen:SolderPad` footprints. Tracks you edit or add in KiCad are fine, as long as the copper stays one chain from J1 to J2.
