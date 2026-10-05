"""STEP model of a flex PCB from export_kicad_flex_pcb, rolled onto its cylinder.

Usage:
    python rolled_flex_pcb_step.py board.kicad_pcb [-o board.step] [--frame 0 0 1 0 -1 0 1 0 0]
                                   [--tolerance 0.02] [--pads] [--kicad-python PATH]

The board outline, the copper of both layers (tracks and net ties; pads with
--pads, vias never) and the silkscreen (lines and text) are read with KiCad's
own Python module, merged per layer and wrapped onto the cylinder the board
was designed on. The STEP has one colored body per layer:

    Board    0.2 mm polyimide tube (solid), with the feed tab
    F.Cu     copper on the outside of the board
    B.Cu     copper on the inside of the board
    F.SilkS  silkscreen on top of F.Cu (B.SilkS if the board has any)

As in KiCad's own STEP export, the copper and silkscreen sit on the faces of
the board body (centred on the middle of the copper stackup). They are
surfaces (at the height of the copper top and the silkscreen top), which
keeps the file at about 20 MB per board; solids would be about 4x larger.
Outlines are simplified to --tolerance (mm); the design clearance is 0.15 mm.

The cylinder comes from the board's title block ('CoilGen mapping' and
'CoilGen cylinder', written by export_kicad_flex_pcb). Coordinates are in the
CoilGen frame (mm), or in frame*CoilGen with --frame (3x3 matrix, row by row).

Needs a Python with cadquery-ocp, shapely and numpy (Python <= 3.13 for the
cadquery-ocp wheels), plus KiCad 8 or later for its Python module 'pcbnew'
(this script runs itself under KiCad's Python for that part).
"""

import argparse
import glob
import json
import math
import os
import re
import subprocess
import sys
import tempfile


# ---------------------------------------------------------------------------
# Part 1: read the merged layer polygons (runs under KiCad's Python)

def extract_layers(pcb_file, out_file, include_pads):
    import pcbnew
    board = pcbnew.LoadBoard(pcb_file)
    max_error = 2000  # nm, arc approximation of round track ends and text strokes

    def add(item, poly_set, layer):
        if isinstance(item, pcbnew.PCB_TEXT):
            if item.IsVisible():
                item.TransformTextToPolySet(poly_set, 0, max_error, pcbnew.ERROR_INSIDE)
        else:
            item.TransformShapeToPolygon(poly_set, layer, 0, max_error, pcbnew.ERROR_INSIDE)

    def polygons(poly_set):
        poly_set.Simplify()
        result = []
        for i in range(poly_set.OutlineCount()):
            rings = [poly_set.Outline(i)] + [poly_set.Hole(i, h) for h in range(poly_set.HoleCount(i))]
            result.append([[[ring.CPoint(k).x * 1e-6, ring.CPoint(k).y * 1e-6] for k in range(ring.PointCount())]
                           for ring in rings])
        return result

    data = {}
    for name in ('F.Cu', 'B.Cu', 'F.SilkS', 'B.SilkS'):
        layer = board.GetLayerID(name)
        poly_set = pcbnew.SHAPE_POLY_SET()
        for track in board.GetTracks():
            if track.Type() != pcbnew.PCB_VIA_T and track.IsOnLayer(layer):
                add(track, poly_set, layer)
        for drawing in board.GetDrawings():
            if drawing.IsOnLayer(layer):
                add(drawing, poly_set, layer)
        for footprint in board.GetFootprints():
            for item in list(footprint.GraphicalItems()) + [footprint.Reference(), footprint.Value()]:
                if item.IsOnLayer(layer):
                    add(item, poly_set, layer)
            if include_pads:
                for pad in footprint.Pads():
                    if pad.IsOnLayer(layer):
                        add(pad, poly_set, layer)
        data[name] = polygons(poly_set)
    poly_set = pcbnew.SHAPE_POLY_SET()
    board.GetBoardPolygonOutlines(poly_set, False)
    data['Edge.Cuts'] = polygons(poly_set)
    with open(out_file, 'w') as f:
        json.dump(data, f)


def find_kicad_python():
    candidates = sorted(glob.glob('/Applications/KiCad/KiCad.app/Contents/Frameworks/Python.framework/Versions/*/bin/python3'))
    candidates += glob.glob(r'C:\Program Files\KiCad\*\bin\python.exe')
    candidates += ['/usr/bin/python3', '/usr/local/bin/python3']
    for c in candidates:
        if os.path.isfile(c) and subprocess.run([c, '-c', 'import pcbnew'], capture_output=True).returncode == 0:
            return c
    return None


# ---------------------------------------------------------------------------
# Part 2: wrap the polygons onto the cylinder and write the STEP

COLORS = {  # RGB 0..1
    'Board': (0.86, 0.66, 0.22),    # yellow polyimide coverlay
    'F.Cu': (0.80, 0.42, 0.24),
    'B.Cu': (0.80, 0.42, 0.24),
    'F.SilkS': (0.95, 0.95, 0.95),
    'B.SilkS': (0.95, 0.95, 0.95),
}
SILK_THICKNESS = 0.01  # mm


def read_board_parameters(pcb_file):
    text = open(pcb_file, encoding='utf-8').read()
    m = re.search(r'CoilGen mapping: x0=([-\d.]+) y0=([-\d.]+) layer_gap=([\d.]+)', text)
    c = re.search(r'CoilGen cylinder: radius=([\d.]+) th0=([-\d.]+) rot_axis=([-\d.e]+) ([-\d.e]+) ([-\d.e]+) rot_angle=([-\d.e]+)', text)
    if not m or not c:
        sys.exit(f'{pcb_file} has no CoilGen mapping/cylinder in its title block (export it with export_kicad_flex_pcb).')
    thickness = re.search(r'\(general\s*\(thickness ([\d.]+)\)', text)
    copper = re.search(r'\(layer "F\.Cu"\s*\(type "copper"\)\s*\(thickness ([\d.]+)\)', text)
    return dict(x0=float(m[1]), y0=float(m[2]), layer_gap=float(m[3]),
                radius=float(c[1]), th0=float(c[2]), rot_axis=[float(c[i]) for i in (3, 4, 5)], rot_angle=float(c[6]),
                board_thickness=float(thickness[1]) if thickness else 0.2,
                copper_thickness=float(copper[1]) if copper else 0.035)


def build_step(pcb_file, layers, out_file, frame, tolerance):
    import numpy as np
    from shapely.geometry import Polygon
    from shapely.geometry.polygon import orient
    from OCP.gp import gp_Ax1, gp_Ax3, gp_Dir, gp_Dir2d, gp_GTrsf, gp_Mat, gp_Pnt, gp_Pnt2d, gp_Trsf, gp_XYZ
    from OCP.Geom import Geom_CylindricalSurface
    from OCP.Geom2d import Geom2d_Line
    from OCP.GeomAbs import GeomAbs_Intersection
    from OCP.BRep import BRep_Builder
    from OCP.BRepBuilderAPI import BRepBuilderAPI_MakeEdge, BRepBuilderAPI_MakeFace, BRepBuilderAPI_MakeWire, BRepBuilderAPI_Transform
    from OCP.BRepCheck import BRepCheck_Analyzer
    from OCP.BRepLib import BRepLib
    from OCP.BRepOffset import BRepOffset_MakeOffset, BRepOffset_Skin
    from OCP.ShapeFix import ShapeFix_Face
    from OCP.TopoDS import TopoDS_Compound, TopoDS_Shell
    from OCP.TopLoc import TopLoc_Location
    from OCP.TCollection import TCollection_ExtendedString
    from OCP.TDataStd import TDataStd_Name
    from OCP.TDocStd import TDocStd_Document
    from OCP.XCAFDoc import XCAFDoc_DocumentTool, XCAFDoc_ColorType
    from OCP.Quantity import Quantity_Color, Quantity_TOC_sRGB
    from OCP.STEPCAFControl import STEPCAFControl_Writer
    from OCP.STEPControl import STEPControl_AsIs
    from OCP.Interface import Interface_Static
    from OCP.IFSelect import IFSelect_RetDone

    p = read_board_parameters(pcb_file)
    r, x0, y0 = p['radius'], p['x0'], p['y0']
    # radial layout (KiCad style): board body centred on the middle of the
    # copper stackup (F.Cu at r, B.Cu one layer gap inside); copper and silk
    # surfaces where the top of the copper and of the silkscreen would be
    r_mid = r - p['layer_gap'] / 2
    r_in, r_out = r_mid - p['board_thickness'] / 2, r_mid + p['board_thickness'] / 2
    cu = p['copper_thickness']
    surface_radius = {'F.Cu': r_out + cu, 'B.Cu': r_in - cu,
                      'F.SilkS': r_out + cu + SILK_THICKNESS, 'B.SilkS': r_in - cu - SILK_THICKNESS}

    def uv(x, y):
        # board mm -> cylinder parameters (angle, axial position); F side faces outwards
        return gp_Pnt2d(p['th0'] + (x - x0) / r, y0 - y)

    def face_on_cylinder(poly, radius):
        surface = Geom_CylindricalSurface(gp_Ax3(gp_Pnt(0, 0, 0), gp_Dir(0, 0, 1)), radius)
        wires = []
        for ring in [poly.exterior] + list(poly.interiors):
            pts = list(ring.coords)[:-1]
            wire = BRepBuilderAPI_MakeWire()
            for i in range(len(pts)):
                a, b = uv(*pts[i]), uv(*pts[(i + 1) % len(pts)])
                line = Geom2d_Line(a, gp_Dir2d(b.X() - a.X(), b.Y() - a.Y()))  # a helix on the cylinder
                wire.Add(BRepBuilderAPI_MakeEdge(line, surface, 0.0, a.Distance(b)).Edge())
            wires.append(wire.Wire())
        make = BRepBuilderAPI_MakeFace(surface, wires[0], True)
        for w in wires[1:]:
            make.Add(w)
        face = make.Face()
        BRepLib.BuildCurves3d_s(face)
        fix = ShapeFix_Face(face)
        fix.Perform()
        return fix.Face()

    def thicken(face, thickness):
        offset = BRepOffset_MakeOffset()
        offset.Initialize(face, thickness, 1e-4, BRepOffset_Skin, False, False, GeomAbs_Intersection, True)
        offset.MakeOffsetShape()
        if not offset.IsDone() or not BRepCheck_Analyzer(offset.Shape()).IsValid():
            raise RuntimeError('thickening the board failed')
        return offset.Shape()

    # CoilGen frame (rotation of the cylinder), then the optional output frame
    rot = gp_Trsf()
    rot.SetRotation(gp_Ax1(gp_Pnt(0, 0, 0), gp_Dir(*p['rot_axis'])), p['rot_angle'])
    to_frame = gp_Trsf()
    if frame is not None:
        f = np.array(frame, dtype=float).reshape(3, 3)
        if abs(np.linalg.det(f) - 1) > 1e-6 or not np.allclose(f @ f.T, np.eye(3), atol=1e-6):
            sys.exit('--frame must be a rotation matrix')
        to_frame.SetValues(*f[0], 0, *f[1], 0, *f[2], 0)
    placement = to_frame.Multiplied(rot)

    shapes = {}
    for name, key in (('Board', 'Edge.Cuts'), ('F.Cu', 'F.Cu'), ('B.Cu', 'B.Cu'), ('F.SilkS', 'F.SilkS'), ('B.SilkS', 'B.SilkS')):
        if not layers.get(key):
            continue
        # board: solid; copper and silk: all faces of a layer in one shell,
        # so that each layer is a single body in the STEP
        builder = BRep_Builder()
        if name == 'Board':
            compound = TopoDS_Compound()
            builder.MakeCompound(compound)
        else:
            compound = TopoDS_Shell()
            builder.MakeShell(compound)
        num_vertices = 0
        for rings in layers[key]:
            poly = Polygon(rings[0], rings[1:])
            if name != 'Board':
                poly = poly.simplify(tolerance)
            poly = orient(poly)
            if poly.is_empty or not poly.is_valid:
                continue
            num_vertices += len(poly.exterior.coords) + sum(len(h.coords) for h in poly.interiors)
            if name == 'Board':
                shape = thicken(face_on_cylinder(poly, r_in), r_out - r_in)
            else:
                shape = face_on_cylinder(poly, surface_radius[name])
            builder.Add(compound, shape)
        shapes[name] = BRepBuilderAPI_Transform(compound, placement, True).Shape()
        print(f'{name}: {len(layers[key])} outlines, {num_vertices} vertices', flush=True)

    # one named, colored body per layer
    doc = TDocStd_Document(TCollection_ExtendedString('MDTV-XCAF'))
    shape_tool = XCAFDoc_DocumentTool.ShapeTool_s(doc.Main())
    color_tool = XCAFDoc_DocumentTool.ColorTool_s(doc.Main())
    title = os.path.splitext(os.path.basename(pcb_file))[0]
    assembly = shape_tool.NewShape()
    TDataStd_Name.Set_s(assembly, TCollection_ExtendedString(title))
    for name, shape in shapes.items():
        label = shape_tool.AddShape(shape, False)
        TDataStd_Name.Set_s(label, TCollection_ExtendedString(name))
        color = Quantity_Color(*COLORS[name], Quantity_TOC_sRGB)
        color_tool.SetColor(label, color, XCAFDoc_ColorType.XCAFDoc_ColorSurf)
        color_tool.SetColor(label, color, XCAFDoc_ColorType.XCAFDoc_ColorGen)
        component = shape_tool.AddComponent(assembly, label, TopLoc_Location())
        TDataStd_Name.Set_s(component, TCollection_ExtendedString(name))
    shape_tool.UpdateAssemblies()

    writer = STEPCAFControl_Writer()  # set the options after this, it resets them
    Interface_Static.SetCVal_s('write.step.schema', 'AP214IS')
    Interface_Static.SetCVal_s('write.step.unit', 'MM')
    Interface_Static.SetIVal_s('write.surfacecurve.mode', 0)  # 3D curves only: much smaller file
    Interface_Static.SetCVal_s('write.step.product.name', title)
    writer.SetColorMode(True)
    writer.SetNameMode(True)
    writer.Transfer(doc, STEPControl_AsIs)
    if writer.Write(out_file) != IFSelect_RetDone:
        sys.exit(f'writing {out_file} failed')
    print(f'wrote {out_file} ({os.path.getsize(out_file) / 1e6:.1f} MB)')


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('pcb')
    parser.add_argument('-o', '--output', help='STEP file (default: next to the board, <board>.step)')
    parser.add_argument('--frame', type=float, nargs=9, help='3x3 rotation (row by row) from the CoilGen frame to the output frame')
    parser.add_argument('--tolerance', type=float, default=0.02, help='outline simplification of copper and silkscreen, mm')
    parser.add_argument('--pads', action='store_true', help='include the solder pads and net-tie pads')
    parser.add_argument('--kicad-python', help="Python that can import KiCad's pcbnew")
    parser.add_argument('--extract', help=argparse.SUPPRESS)  # internal: run under KiCad's Python
    args = parser.parse_args()
    pcb = os.path.abspath(args.pcb)

    if args.extract:
        extract_layers(pcb, args.extract, args.pads)
        return

    kicad_python = args.kicad_python or find_kicad_python()
    if not kicad_python:
        sys.exit("KiCad's Python (with pcbnew) not found; pass --kicad-python")
    with tempfile.TemporaryDirectory() as tmp:
        layer_file = os.path.join(tmp, 'layers.json')
        cmd = [kicad_python, os.path.abspath(__file__), pcb, '--extract', layer_file] + (['--pads'] if args.pads else [])
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0 or not os.path.isfile(layer_file):
            sys.exit(f'reading {pcb} with KiCad failed:\n{result.stdout}{result.stderr}')
        with open(layer_file) as f:
            layers = json.load(f)
    out = args.output or os.path.splitext(pcb)[0] + '.step'
    build_step(pcb, layers, out, args.frame, args.tolerance)


if __name__ == '__main__':
    main()
