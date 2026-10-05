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

%manufacturer: stackup, design rules and limits (JLCPCB flex, 2 layers, 1 oz, 25 um PI, 0.2 mm)
fab_profile=fullfile(pwd,'KiCad_flex_PCBs','fab_profiles','jlcpcb_flex_2layer_1oz_25um_0p2mm.json');
fab=jsondecode(fileread(fab_profile));

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
    'fab_profile',fab_profile);

%% 3D model (STEP) of the board: board body, copper and silkscreen
%regenerated with every export so it always matches the .kicad_pcb;
%<coil>.step.zip is the version kept in git
export_kicad_step(pcb_file);

%% Re-simulate the manufactured copper with CoilGen
%read the board file back (J1 to J2), use it as the wire path of the coil
%and evaluate the field with CoilGen's own routines
[pcb_layouts.(coil_name).out,pcb_check]=import_kicad_flex_pcb(coil_out,pcb_file,'copper_thickness',fab.stackup.copper_thickness_mm);
report.pcb_check=pcb_check;
%compact result of the re-simulation for the 3D views (view_flex_pcb_coils.m)
coil_layouts=struct('out',strip_coilgen_result(pcb_layouts.(coil_name).out)); %#ok<NASGU>
save(fullfile(coil_folder,[coil_name '_coilgen_pcb.mat']),'coil_layouts','-v7');

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
fprintf(out_id,'Track width min/mean/max [mm] and smallest gap within a net (not checked by the KiCad DRC):\n');
for i=1:numel(names)
r=results.(names{i});
fprintf(out_id,'%-22s %.2f / %.2f / %.2f   same-net gap %.3f mm\n',names{i},r.min_track_width_mm,r.mean_track_width_mm,r.max_track_width_mm,r.min_same_net_gap_mm);
end
fprintf(out_id,'V_L assumes a ramp time of %.0f us to the target gradient; L is a filament estimate (+-15%%).\n',rise_time*1e6);
fprintf(out_id,'\nCoilGen re-simulation of the copper read back from the .kicad_pcb files (J1 to J2):\n');
fprintf(out_id,'%-22s %9s %9s %8s %16s %16s %10s\n','coil','gradient','std','R','err layout [%]','err ideal [%]','J1->J2');
fprintf(out_id,'%-22s %9s %9s %8s %16s %16s %10s\n','','[mT/m/A]','[mT/m/A]','[Ohm]','max / mean','max / mean','polarity');
for i=1:numel(names)
c=results.(names{i}).pcb_check; e=c.error_vals;
polarity={'reversed','as design'};
fprintf(out_id,'%-22s %9.2f %9.3f %8.2f %7.2f / %5.2f %8.2f / %5.2f %10s\n',names{i},c.mean_gradient_mT_per_m_per_A,c.std_gradient_mT_per_m_per_A, ...
    c.resistance_ohm,e.max_rel_error_layout_vs_target,e.mean_rel_error_layout_vs_target, ...
    e.max_rel_error_unconnected_contours_vs_target,e.mean_rel_error_unconnected_contours_vs_target,polarity{1+c.current_J1_to_J2_matches_design});
end
fprintf(out_id,'err: deviation from the target field relative to its maximum; ideal = the same turns as closed loops on both layers.\n');
fprintf(out_id,'\nManufacturer check against %s:\n',fab.name);
for i=1:numel(names)
fc=results.(names{i}).fab_check;
failed={fc(~[fc.ok]).item};
if isempty(failed), status='all limits met'; else, status=['NOT MET: ' strjoin(failed,', ')]; end
fprintf(out_id,'%-22s %s (min track %.2f mm, board %.1f x %.1f mm)\n',names{i},status,results.(names{i}).min_track_width_mm,results.(names{i}).board_size_mm);
end
fprintf(out_id,'Resistance tolerance from the +-%.0f%% track width tolerance: about %+.0f%% / %+.0f%%.\n',fab.fab_limits.track_width_tolerance*100, ...
    (1/(1+fab.fab_limits.track_width_tolerance)-1)*100,(1/(1-fab.fab_limits.track_width_tolerance)-1)*100);
end
fclose(fid);


%% Plot the re-simulated boards (MATLAB desktop only)
if usejava('desktop')
addpath(fullfile(pwd,'plotting'));
for i=1:numel(names)
coil_layouts=pcb_layouts.(names{i});
coil_title=strrep(names{i},'_',' ');
plot_coil_track_with_resulting_bfield(coil_layouts,1,coil_title);
plot_slit_seam(coil_layouts,1); % red: seam where the rolled board's edges meet
plot_various_error_metrics(coil_layouts,1,coil_title);
plot_resulting_gradient(coil_layouts,1,coil_title);
end
end
