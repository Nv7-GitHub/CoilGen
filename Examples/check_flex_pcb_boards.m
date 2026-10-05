%This script runs the independent checks on the flex PCBs written by
%halbach_flex_pcb_gradient_set.m, directly on the .kicad_pcb files:
%KiCad DRC (with the rules in each .kicad_pro), same-net clearance, track
%widths, the manufacturer limits of the fab profile and (optional) the
%effect of the full track widths on the field.
%Run halbach_flex_pcb_gradient_set.m first.


clc; clear all;

if ispc
cd('..\');
else
cd('../');
end
addpath(fullfile(pwd,'sub_functions'));

board_folder=fullfile(pwd,'KiCad_flex_PCBs','halbach_45mT_gradient_set');
fab_profile=fullfile(pwd,'KiCad_flex_PCBs','fab_profiles','jlcpcb_flex_2layer_1oz_25um_0p2mm.json');
coil_names={'Z_gradient_bore_axis','Y_gradient','X_gradient_B0_axis'};
check_width_field=true; % takes a few minutes per board

all_ok=true;
for coil_ind=1:numel(coil_names)
coil_name=coil_names{coil_ind};
pcb_file=fullfile(board_folder,coil_name,[coil_name '.kicad_pcb']);
args={'fab_profile',fab_profile};
if check_width_field
load(fullfile(board_folder,coil_name,[coil_name '_coilgen_pcb.mat']),'coil_layouts');
args=[args {'coil_result',coil_layouts.out}]; %#ok<AGROW>
end
c=check_kicad_flex_pcb(pcb_file,args{:});

fprintf('\n%s\n',coil_name);
if c.drc.ran
fprintf('  KiCad DRC:        %d violations, %d unconnected items\n',c.drc.violations,c.drc.unconnected);
all_ok=all_ok && c.drc.violations==0 && c.drc.unconnected==0;
else
fprintf('  KiCad DRC:        skipped (kicad-cli not found)\n');
end
fprintf('  same-net gap:     %.3f mm\n',c.same_net.min_gap_mm);
fprintf('  track widths:     %.2f .. %.2f mm (%d segments)\n',c.tracks.min_width_mm,c.tracks.max_width_mm,c.tracks.num_segments);
for i=1:numel(c.fab)
ok_text={'NOT MET','OK'};
fprintf('  %-22s %.4f (limit %.4f) %s\n',[c.fab(i).item ':'],c.fab(i).value,c.fab(i).limit,ok_text{1+c.fab(i).ok});
end
all_ok=all_ok && all([c.fab.ok]);
if isfield(c,'width_field')
fprintf('  full-width tracks: gradient %+.2f %%, field change up to %.3f %% of the field span\n', ...
    c.width_field.gradient_change_percent,c.width_field.max_field_change_percent_of_span);
end
end
if all_ok, fprintf('\nAll boards pass.\n'); else, fprintf('\nSOME CHECKS FAILED.\n'); end
