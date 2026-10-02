# Flex PCB export for KiCad

`export_kicad_flex_pcb` turns a CoilGen design into a 2-layer flex PCB. The board is rolled into a cylinder to form the coil, and the export includes the KiCad design rules so you can run DRC on it. This guide covers how the export works, how to run it, and how to build the coils. The worked example is a 3-axis gradient set for a small Halbach magnet.

## What the exporter does

1. **Coil on a slit cylinder.** The coil is designed on a cylinder with a narrow axial slit (`'create slit cylinder mesh'`). CoilGen forbids current from crossing a mesh boundary, so no track ever crosses the seam of the rolled PCB. Put the slit where the stream function of the closed-cylinder design is close to zero, and it costs almost no efficiency.
2. **Two layers in series.** Each group of nested contour loops becomes one 2-layer spiral. It spirals inwards on `F.Cu`, goes through one via inside the innermost turn, and spirals back out on `B.Cu`. Both layers carry the full pattern, which doubles the efficiency per ampere compared with one layer. Each step to the next turn is routed through the turn's opening (`cut_width`), so no extra layer is needed for crossovers.
3. **Routing channel.** The spirals are opened towards a copper-free axial band. This is either a free band between the groups (for example the centre of a longitudinal gradient coil) or a margin added beyond the end of the coil. In the channel, the groups are linked in series on `F.Cu`. A return trace runs back on `B.Cu` directly under the links to the feed tab, so the links carry no net circumferential current and add almost no field error.
4. **Feed tab.** A small tab sticks out at the seam, with `J1` on `F.Cu` and `J2` on `B.Cu` directly behind it, which makes the feed coaxial. Fold the tab outwards when the board is rolled.
5. **Full DRC coverage.** Every turn is its own net, and consecutive turns are joined with KiCad net-tie footprints. KiCad's DRC therefore checks the clearance between all turns, not only between groups. The `.kicad_pro` written next to the board holds the design rules: clearance, edge clearance, via and drill sizes.
6. **Verification.** The exported copper is checked against the target field with Biot-Savart: both layers, every link, and the subdivided tracks on the cylinder surface. The report gives efficiency, linearity, resistance and an inductance estimate.

Board coordinates: `x` is the arc length around the circumference and `y` is the axial position (pointing up). `F.Cu` is the outside of the rolled cylinder.

## Running the example

```matlab
cd Examples
halbach_flex_pcb_gradient_set
```

The script designs three gradient coils for a 45 mT Halbach magnet: main field along `x`, bore along `z`, 100 mm bore, 40 mm DSV. The coils are rolled at 65, 67.5 and 70 mm diameter and are 120 mm long. The script writes the boards and a summary to `KiCad_flex_PCBs/halbach_45mT_gradient_set/`.

CoilGen always optimizes the field component along its own z axis. To use it with a Halbach magnet, the coil cylinder is rotated so its axis lies along CoilGen's `x`, and the main field lies along CoilGen's `z`. The mapping to the magnet frame is written at the top of the script.

Results (1 oz copper, 0.15 mm clearance, inductance from a filament estimate ±15%, voltage across the inductance for a 100 µs ramp):

| Coil | Diameter | Track | Turns (both layers) | Efficiency | Non-linearity over 40 mm DSV | R | L | Current for target | V (R) | V (L) | Peak power |
|---|---|---|---|---|---|---|---|---|---|---|---|
| Z (bore axis), 28 mT/m | 65 mm | 0.70 mm | 72 | 7.35 mT/m/A | 0.69 % | 9.2 Ω | 71 µH | 3.8 A | 35 V | 2.7 V | 134 W |
| Y, 12 mT/m | 67.5 mm | 0.95 mm | 72 | 19.5 mT/m/A | 0.71 % | 9.8 Ω | 142 µH | 0.61 A | 6.0 V | 0.9 V | 3.7 W |
| X (B0 axis), 12 mT/m | 70 mm | 0.85 mm | 72 | 18.9 mT/m/A | 0.18 % | 10.7 Ω | 143 µH | 0.64 A | 6.8 V | 0.9 V | 4.3 W |

Renders of the top side (`F.Cu`):

![Z gradient](kicad_flex_Z_gradient_bore_axis.png)
![Y gradient](kicad_flex_Y_gradient.png)
![X gradient](kicad_flex_X_gradient_B0_axis.png)

Check all three boards with KiCad's DRC from the command line:

```bash
cd KiCad_flex_PCBs/halbach_45mT_gradient_set
for f in *.kicad_pcb; do kicad-cli pcb drc --severity-all -o "${f%.kicad_pcb}_drc.rpt" "$f"; done
```

## Using it for your own coil

```matlab
coil_out=CoilGen( ...
    'field_shape_function','y', ...
    'coil_mesh_file','create slit cylinder mesh', ...
    'slit_cylinder_mesh_parameter_list',[length radius 60 40 rot_x rot_y rot_z rot_angle slit_angle slit_width], ...
    'surface_is_cylinder_flag',false, ...
    'skip_postprocessing',true, ...   % the exporter builds the spirals itself
    ... );                            % target region, levels, regularization as usual
addpath('sub_functions');             % CoilGen removes it from the path when it returns
report=export_kicad_flex_pcb(coil_out,'my_coil.kicad_pcb','title','My coil');
```

`slit_cylinder_mesh_parameter_list` takes the same values as `cylinder_mesh_parameter_list`, plus two more:
- **`slit_angle`:** the slit centre in radians, as `atan2(y,x)` *before* the rotation is applied.
- **`slit_width`:** the arc width kept free of current, in meters.

To find a good slit angle, run the closed-cylinder design first. Then take the angle where the maximum of `|stream_function|` along the axial line is smallest.

Exporter options (lengths in mm):

| Option | Default | Meaning |
|---|---|---|
| `track_width` | auto | Trace width. Auto uses the smallest turn spacing minus the clearance. |
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

The `report` contains the efficiency (and gradient vector) in mT/m/A, the non-linearity, the trace length, the resistance, the inductance, the turns per group, the number of dropped loops, the channel geometry and the board size.

## Building the coils

- Roll each board with `F.Cu` outside. The two seam edges meet with a `seam_gap` gap, and no track crosses the seam.
- Fold the feed tab outwards. Solder the coil leads to `J1` (outside) and `J2` (inside). Twist the leads.
- Nest the three coils: Z (65 mm) inside, then Y (67.5 mm), then X (70 mm). Line up the axial centres. Keep track of the orientation of each board relative to the magnet: the seam position follows the slit angle used for that coil.
- The design-rule values in the `.kicad_pro` (0.15 mm clearance, 0.3 mm edge clearance, 0.6/0.3 mm vias) are typical of flex fabs. Check them against your manufacturer before ordering.

## Limitations

- Only single-part coils designed on a `'create slit cylinder mesh'` surface are supported.
- When a loop contains more than one nested set of loops, only the largest branch is kept, and the others are dropped with a warning. These are small loops that can't be reached on two layers. In the Y coil above, 4 small loops were dropped. The field check includes this, and the coil's non-linearity is still 0.71 %.
- Inner turns with no room for the via are dropped and counted in `report.dropped_loops`.
- The inductance is an estimate (±15%), not a FastHenry result. Inter-layer capacitance, and so the self-resonance, isn't calculated. Measure the self-resonance once the coil is built, and check it is well away from your RF frequency.
