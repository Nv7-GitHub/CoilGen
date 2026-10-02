<div id="top"></div>

## **IMPORTANT BUG FIX REGARDING FIELD SCALE IN "plot_various_error_metrics" PLOT - PLEASE UPDATE!**

 <img src="./Documentation/CoilGen_Image.png" width="300">

<!-- ABOUT THE PROJECT -->

The CoilGen Project is a community-based tool for the generation of coil Layouts within the MRI/NMR environment. It is based on a boundary element method and generates an interconnected non-overlapping wire-tracks on 3D support structures. The focus of this work is post processing.

The user must specify a target field (e.g., bz(x,y,z)=y for a constant gradient in the y-direction) and a surface mesh geometry (e.g., a cylinder defined in an .stl file). The code then generates a coil layout in the form of a non-overlapping, interconnected wire trace to achieve the desired field.

## pyCoilGen: A Python Implementation
The author has supported the creation of **pyCoilGen**, a translation of this CoilGen Project to Python. The code is available on [GitHub](https://github.com/kev-m/pyCoilGen) and
documentation is available on [ReadTheDocs](https://pycoilgen.readthedocs.io/).


A full description is given in the following publication: https://onlinelibrary.wiley.com/doi/10.1002/mrm.29294



<!-- GETTING STARTED -->
## Getting Started

Check the documentation to get started



### Installation

1. Download and extract the file of the CoilGen repository
2. Run one of the examples in the folder "Examples"

The project requires MATLAB and optionally FastHenry2 for calculation of the coil inductance.  The MATLAB version should not be older than 2020A.


### Flex PCB export for KiCad

Cylindrical coils can be built as rolled 2-layer flex PCBs:
- **Slit-cylinder design:** the coil is designed on a cylinder with an axial slit (`'create slit cylinder mesh'`), so no track crosses the seam of the rolled board.
- **Export:** `export_kicad_flex_pcb` writes a KiCad board with both layers in series, variable-width traces and design rules, so KiCad's DRC checks every turn.
- **Re-simulation:** `import_kicad_flex_pcb` reads the board back and re-simulates the manufactured copper with CoilGen. The result works with the plotting functions.

See [Documentation/KiCad_flex_PCB_export.md](Documentation/KiCad_flex_PCB_export.md). The examples are:
- `Examples/halbach_flex_pcb_gradient_set.m`, which designs, exports, checks and re-simulates a 3-axis gradient set for a small Halbach magnet;
- `Examples/view_flex_pcb_coils.m`, which shows that set in 3D.


### Algorithm overview

![plot](./Documentation/flow_chart_algorithm_revised.png)






<!-- LICENSE -->
## License

 See `LICENSE.txt` for more information.

<p align="right">(<a href="#top">back to top</a>)</p>



<!-- CONTACT -->
## Contact

Philipp Amrein, Github User: Philipp-MR 

Project Link: [https://github.com/Philipp-MR/CoilGen]

<p align="right">(<a href="#top">back to top</a>)</p>


## Citation

For citation of this work, please refer to the following publication:
https://onlinelibrary.wiley.com/doi/10.1002/mrm.29294
https://doi.org/10.1002/mrm.29294

<p align="right">(<a href="#top">back to top</a>)</p>
