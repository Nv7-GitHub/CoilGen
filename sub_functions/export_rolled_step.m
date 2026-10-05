function step_file=export_rolled_step(pcb_file,varargin)
%3D model (STEP) of a flex PCB from export_kicad_flex_pcb, rolled onto the
%cylinder it was designed on: the board body, the copper of both layers and
%the silkscreen, one named and colored body each (Board, F.Cu, B.Cu,
%F.SilkS). Runs rolled_flex_pcb_step.py, which reads the board with KiCad's
%own Python module and builds the geometry with OpenCASCADE.
%
%The board body is a solid; copper and silkscreen are surfaces on its
%faces (as in KiCad's STEP export). Outlines are simplified to 'tolerance'
%(mm). Pads are left out ('include_pads'), vias always. Coordinates are in mm in the CoilGen frame, or frame*CoilGen with
%'frame' (3x3 rotation).
%
%By default the .step is also zipped (<board>.step.zip), which is the
%version kept in git. Regenerate it whenever the .kicad_pcb changes (the
%example halbach_flex_pcb_gradient_set.m does this after every export).
%
%Needs a Python with cadquery-ocp, shapely and numpy: 'python', else the
%environment variable COILGEN_PYTHON, else .venv in the CoilGen folder:
%   python3.12 -m venv .venv
%   .venv/bin/pip install cadquery-ocp shapely numpy

parser=inputParser;
addParameter(parser,'frame',[],@(x) isempty(x) || isequal(size(x),[3 3]));
addParameter(parser,'zip',true,@islogical);
addParameter(parser,'include_pads',false,@islogical);
addParameter(parser,'tolerance',0.02,@isnumeric);
addParameter(parser,'python','',@ischar);
parse(parser,varargin{:});
opt=parser.Results;

python=find_step_python(opt.python);
if isempty(python)
warning(['No Python with cadquery-ocp and shapely found: rolled STEP of %s skipped.\n' ...
    'Set it up with: python3.12 -m venv .venv && .venv/bin/pip install cadquery-ocp shapely numpy'],pcb_file);
step_file='';
return;
end
[folder,name]=fileparts(pcb_file);
step_file=fullfile(folder,[name '.step']);
args={fullfile(fileparts(mfilename('fullpath')),'rolled_flex_pcb_step.py'),pcb_file,'-o',step_file, ...
    '--tolerance',sprintf('%g',opt.tolerance)};
if ~isempty(opt.frame)
args=[args {'--frame'} arrayfun(@(v) sprintf('%.10g',v),reshape(opt.frame',1,[]),'UniformOutput',false)];
end
if opt.include_pads, args{end+1}='--pads'; end
[status,output]=run_kicad_cli(python,args,300);
if status~=0 || ~isfile(step_file)
error('Rolled STEP export of %s failed:\n%s',pcb_file,output);
end
if opt.zip
zip(fullfile(folder,[name '.step.zip']),[name '.step'],folder);
end
end


function python=find_step_python(hint)
root=fileparts(fileparts(mfilename('fullpath')));
candidates={hint,getenv('COILGEN_PYTHON'),fullfile(root,'.venv','bin','python'), ...
    fullfile(root,'.venv','Scripts','python.exe'),'python3'};
python='';
for c=candidates
if isempty(c{1}), continue; end
[status,~]=run_kicad_cli(c{1},{'-c','import OCP, shapely, numpy'},60);
if status==0, python=c{1}; return; end
end
end
