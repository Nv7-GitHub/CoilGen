%This script shows the flex PCB gradient coils of halbach_flex_pcb_gradient_set.m
%in 3D with CoilGen's plotting functions. The coils are the copper read back
%from the .kicad_pcb files (both layers, all links), re-simulated with
%CoilGen, so the views and field errors are those of the boards as built.
%Run halbach_flex_pcb_gradient_set.m first; it saves the results next to
%the boards.
%
%CoilGen frame (as in the plots): B0 = z, bore along x.
%Magnet frame: x_magnet = z, y_magnet = -y, z_magnet = x.


clc; clear all;

if ispc
cd('..\');
else
cd('../');
end
addpath(fullfile(pwd,'plotting'));

board_folder=fullfile(pwd,'KiCad_flex_PCBs','halbach_45mT_gradient_set');
coil_names={'Z_gradient_bore_axis','Y_gradient','X_gradient_B0_axis'};

close all;
for coil_ind=1:numel(coil_names)
coil_name=coil_names{coil_ind};
load(fullfile(board_folder,coil_name,[coil_name '_coilgen_pcb.mat']),'coil_layouts');
coil_title=strrep(coil_name,'_',' ');
plot_coil_track_with_resulting_bfield(coil_layouts,1,coil_title); % 3D copper with the resulting field
plot_slit_seam(coil_layouts,1); % red: seam where the rolled board's edges meet
plot_3D_current_density(coil_layouts,1,coil_title);
plot_slit_seam(coil_layouts,1);
plot_2D_contours_with_sf(coil_layouts,1,coil_title);
plot_various_error_metrics(coil_layouts,1,coil_title);
plot_resulting_gradient(coil_layouts,1,coil_title);
end
