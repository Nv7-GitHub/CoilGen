%This script generates a 3-axis gradient set for a small Halbach magnet as
%2-layer flex PCBs for KiCad: 45 mT, 100 mm bore, 40 mm DSV, coils rolled
%at 65 / 67.5 / 70 mm diameter. Each coil is designed on a cylinder with an
%axial slit so that no track crosses the seam of the rolled flex PCB.
%
%Frame of the magnet: B0 along x (Halbach), bore along z.
%CoilGen optimizes the z-component of the field, so the CoilGen frame has
%B0 = z_cg and the bore along x_cg (cylinder rotated by 90deg around y):
%   x_magnet = z_cg,  y_magnet = -y_cg,  z_magnet = x_cg


clc; clear all;

if ispc
cd('..\');
else
cd('../');
end
addpath(fullfile(pwd,'sub_functions'));

output_folder=fullfile(pwd,'KiCad_flex_PCBs','halbach_45mT_gradient_set');
if ~exist(output_folder,'dir'), mkdir(output_folder); end

coil_length=0.12;           % in meter
target_region_radius=0.02;  % 40 mm DSV
slit_width=0.003;           % in meter; arc length kept free of current at the seam

%       name                     CoilGen shape  radius [m]  slit center [deg]  target [mT/m]  positive gradient (CoilGen frame)
coils={'Z_gradient_bore_axis',  'x',           0.0325,     90,                28,            [1;0;0]; ...   % +dBx/dz
       'Y_gradient',            'y',           0.03375,    270,               12,            [0;-1;0]; ...  % +dBx/dy (y_magnet = -y_cg)
       'X_gradient_B0_axis',    'z',           0.035,      115,               12,            [0;0;1]};      % +dBx/dx

%silkscreen marks for aligning the rolled coils in the magnet: looking down
%the bore (+z), B0 points from left (-x) to right (+x); directions in the CoilGen frame
axis_marks={[0;0;-1], '-X LEFT (looking down +Z)'; ...
            [0;0;1],  '+X RIGHT (looking down +Z)'};

rise_time=100e-6;  % assumed gradient ramp time for the driver voltage

results=struct();
for coil_ind=1:size(coils,1)
[coil_name,shape,radius,slit_center,target_gradient,positive_gradient]=coils{coil_ind,:};

%% Run the algorithm
coil_out=CoilGen(...
    'field_shape_function',shape,... % definition of the target field
    'coil_mesh_file','create slit cylinder mesh', ...
    'slit_cylinder_mesh_parameter_list',[coil_length radius 60 40 0 1 0 pi/2 deg2rad(slit_center) slit_width], ...
    'surface_is_cylinder_flag',false, ...
    'target_region_radius',target_region_radius,...
    'target_region_resolution',10,...
    'set_roi_into_mesh_center',true, ...
    'levels',20, ... % the number of potential steps that determines the later number of windings
    'pot_offset_factor',0.25, ...
    'min_loop_signifcance',1, ...
    'tikonov_reg_factor',1000, ...
    'skip_postprocessing',true, ... % the spirals are built by the PCB exporter
    'plot_flag',false, ...
    'save_stl_flag',false, ...
    'skip_inductance_calculation',true, ...
    'output_directory',output_folder);

%% Export the 2-layer series flex PCB
addpath(fullfile(pwd,'sub_functions')); % CoilGen removes it from the path
coil_folder=fullfile(output_folder,coil_name); % one KiCad project folder per coil
if ~exist(coil_folder,'dir'), mkdir(coil_folder); end
pcb_file=fullfile(coil_folder,[coil_name '.kicad_pcb']);
report=export_kicad_flex_pcb(coil_out,pcb_file, ...
    'title',strrep(coil_name,'_',' '), ...
    'axis_marks',axis_marks, ...
    'axial_label','+Z into bore', ...
    'positive_gradient',positive_gradient, ...
    'clearance',0.15, ...
    'copper_thickness',0.035, ...
    'via_diameter',0.6, ...
    'via_drill',0.3);

%% Driver requirements
current=target_gradient/report.efficiency_mT_per_m_per_A;
report.target_gradient_mT_per_m=target_gradient;
report.current_A=current;
report.resistive_voltage_V=current*report.resistance_ohm;
report.inductive_voltage_V=report.inductance_H*current/rise_time;
report.peak_power_W=current^2*report.resistance_ohm;
results.(coil_name)=report;
end

%% Summary (printed and written next to the boards)
summary_file=fullfile(output_folder,'coil_summary.txt');
fid=fopen(summary_file,'w');
for out_id=[1 fid]
fprintf(out_id,'\n%-22s %7s %6s %9s %8s %7s %8s %7s %7s %8s %8s\n','coil','track','turns','eff','nonlin','R','L','I','V_R','V_L', 'P_peak');
fprintf(out_id,'%-22s %7s %6s %9s %8s %7s %8s %7s %7s %8s %8s\n','','[mm]','','[mT/m/A]','[%]','[Ohm]','[uH]','[A]','[V]','[V]','[W]');
names=fieldnames(results);
for i=1:numel(names)
r=results.(names{i});
fprintf(out_id,'%-22s %7.2f %6d %9.2f %8.2f %7.2f %8.1f %7.2f %7.1f %8.1f %8.1f\n',names{i},r.track_width_mm,sum(r.turns_per_group)*2, ...
    r.efficiency_mT_per_m_per_A,r.nonlinearity_percent,r.resistance_ohm,r.inductance_H*1e6,r.current_A, ...
    r.resistive_voltage_V,r.inductive_voltage_V,r.peak_power_W);
end
fprintf(out_id,'V_L assumes a ramp time of %.0f us to the target gradient; L is a filament estimate (+-15%%).\n',rise_time*1e6);
end
fclose(fid);
