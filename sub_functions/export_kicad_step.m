function step_file=export_kicad_step(pcb_file,varargin)
%Export the 3D model of a board as STEP with KiCad's command line tool:
%board body, copper (tracks, pads, vias) and silkscreen, without
%component models. The board is exported flat, as KiCad has no notion of
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
[status,output]=system(sprintf('"%s" pcb export step --force --no-components --include-tracks --include-pads --include-silkscreen -o "%s" "%s"', ...
    cli,step_file,pcb_file));
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
