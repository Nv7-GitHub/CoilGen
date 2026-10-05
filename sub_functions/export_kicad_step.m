function step_file=export_kicad_step(pcb_file,varargin)
%Export the 3D model of a board as STEP with KiCad's command line tool:
%board body, copper tracks and silkscreen, without component models. Pads
%(solder pads, net ties) and vias are left out by default ('include_pads',
%'include_vias'); kicad-cli exports vias together with the tracks, so they
%are removed from a temporary copy of the board. The board is exported flat, as KiCad has no notion of
%the rolled flex PCB.
%
%STEP files of these boards are large (about 90-125 MB with all copper),
%so by default the .step is also zipped (<board>.step.zip, about 20 MB),
%which is the version kept in git.
%
%Regenerate the STEP whenever the .kicad_pcb changes (the example
%halbach_flex_pcb_gradient_set.m does this after every export).

parser=inputParser;
addParameter(parser,'zip',true,@islogical);
addParameter(parser,'include_pads',false,@islogical);
addParameter(parser,'include_vias',false,@islogical);
addParameter(parser,'kicad_cli','',@ischar);
parse(parser,varargin{:});
opt=parser.Results;

cli=find_kicad_cli(opt.kicad_cli);
if isempty(cli)
warning('kicad-cli not found: STEP export of %s skipped.',pcb_file);
step_file='';
return;
end
[folder,name]=fileparts(pcb_file);
step_file=fullfile(folder,[name '.step']);
%kicad-cli rewrites the .kicad_pro in its own format when it loads the
%board; keep the file as exported
pro_file=fullfile(folder,[name '.kicad_pro']);
pro_text='';
if isfile(pro_file), pro_text=fileread(pro_file); end
source_file=pcb_file;
if ~opt.include_vias
%copy of the board without vias (in the same folder, so relative paths in
%the board still resolve)
source_file=fullfile(folder,['~' name '_step_export.kicad_pcb']);
board_text=regexprep(fileread(pcb_file),'\t\(via\n.*?\n\t\)\n','');
fid=fopen(source_file,'w'); fwrite(fid,board_text); fclose(fid);
end
args={'pcb','export','step','--force','--no-components','--include-tracks','--include-silkscreen'};
if opt.include_pads, args{end+1}='--include-pads'; end
[status,output]=run_kicad_cli(cli,[args {'-o',step_file,source_file}],300);
if ~strcmp(source_file,pcb_file)
delete(source_file);
temp_prl=fullfile(folder,['~' name '_step_export.kicad_prl']); %kicad-cli writes local settings for the copy
if isfile(temp_prl), delete(temp_prl); end
end
restore_text(pro_file,pro_text);
if status~=0 || ~isfile(step_file)
error('STEP export of %s failed:\n%s',pcb_file,output);
end
if opt.zip
zip(fullfile(folder,[name '.step.zip']),[name '.step'],folder);
end
end


function restore_text(file,text)
if isempty(text), return; end
fid=fopen(file,'w'); fwrite(fid,text); fclose(fid);
end
