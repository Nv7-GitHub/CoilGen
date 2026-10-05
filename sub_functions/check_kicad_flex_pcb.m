function check=check_kicad_flex_pcb(pcb_file,varargin)
%Independent checks of a flex PCB written by export_kicad_flex_pcb, run on
%the .kicad_pcb file itself (so they also cover edits made in KiCad):
%
% drc          KiCad DRC with the rules of the .kicad_pro next to the board
%              (kicad-cli): shorts and clearance between nets (every turn
%              is its own net), unconnected items (series chain J1-J2),
%              edge clearance, via/drill sizes, silkscreen.
% same_net     smallest copper gap between parts of the same net that are
%              far apart along the track; the KiCad DRC does not check
%              clearance within a net, so a turn touching itself would go
%              unnoticed.
% tracks       smallest and largest track width in the file.
% fab          the file against the limits of a manufacturer profile
%              ('fab_profile'): track width, design clearance, vias, edge.
% width_field  optional ('coil_result'): field of the board with every
%              track split into filaments across its width compared with
%              thin wires along the track centres (the model of the
%              re-simulation), i.e. whether the wide tracks change the field.

parser=inputParser;
addParameter(parser,'fab_profile','',@ischar);
addParameter(parser,'coil_result',[],@isstruct); %CoilGen result of the coil (e.g. from import_kicad_flex_pcb)
addParameter(parser,'num_filaments',7,@isnumeric);
addParameter(parser,'kicad_cli','',@ischar);
parse(parser,varargin{:});
opt=parser.Results;

txt=fileread(pcb_file);
seg=regexp(txt,'\(segment\s*\(start ([-\d.]+) ([-\d.]+)\)\s*\(end ([-\d.]+) ([-\d.]+)\)\s*\(width ([\d.]+)\)\s*\(layer "([FB])\.Cu"\)\s*\(net (\d+)\)','tokens');
num=cellfun(@(t) str2double(t([1:5 7])),seg,'UniformOutput',false); num=vertcat(num{:});
layer_b=cellfun(@(t) t{6}=='B',seg)';

%% KiCad DRC
check.drc=run_kicad_drc(pcb_file,opt.kicad_cli);

%% Track widths and same-net clearance
check.tracks.num_segments=size(num,1);
check.tracks.min_width_mm=min(num(:,5));
check.tracks.max_width_mm=max(num(:,5));
check.same_net.min_gap_mm=same_net_gap(num,layer_b);

%% Manufacturer limits
if ~isempty(opt.fab_profile)
fab=jsondecode(fileread(opt.fab_profile));
f=fab.fab_limits; d=fab.design;
via=regexp(txt,'\(via\s*\(at [-\d.]+ [-\d.]+\)\s*\(size ([\d.]+)\)\s*\(drill ([\d.]+)\)','tokens');
via=cellfun(@str2double,vertcat(via{:}));
items={'min track width',check.tracks.min_width_mm,f.min_track_width_mm; ...
       'same-net gap',check.same_net.min_gap_mm,f.min_clearance_mm; ...
       'via diameter',min(via(:,1)),f.min_via_diameter_mm; ...
       'via drill',min(via(:,2)),f.min_via_drill_mm; ...
       'design clearance',d.clearance_mm,f.min_clearance_mm; ...
       'design edge clearance',d.edge_clearance_mm,f.min_copper_to_edge_mm};
check.fab=struct('item',items(:,1),'value',items(:,2),'limit',items(:,3));
for i=1:numel(check.fab), check.fab(i).ok=check.fab(i).value>=check.fab(i).limit-1e-9; end
end

%% Field of the full-width tracks
if ~isempty(opt.coil_result)
check.width_field=width_field_check(txt,num,layer_b,opt.coil_result,opt.num_filaments);
end
end


function drc=run_kicad_drc(pcb_file,kicad_cli)
drc=struct('ran',false,'violations',NaN,'unconnected',NaN,'by_type',struct());
candidates={kicad_cli,'kicad-cli','/opt/homebrew/bin/kicad-cli','/usr/local/bin/kicad-cli', ...
    '/Applications/KiCad/KiCad.app/Contents/MacOS/kicad-cli','C:\Program Files\KiCad\bin\kicad-cli.exe'};
cli='';
for c=candidates
if isempty(c{1}), continue; end
[status,~]=system(['"' c{1} '" version']);
if status==0, cli=c{1}; break; end
end
if isempty(cli)
warning('kicad-cli not found: KiCad DRC skipped.');
return;
end
report_file=[tempname '.json'];
[~,~]=system(sprintf('"%s" pcb drc --format json --severity-all -o "%s" "%s"',cli,report_file,pcb_file)); %output captured: kicad-cli prints font warnings
rep=jsondecode(fileread(report_file));
delete(report_file);
drc.ran=true;
violations=[];
if isfield(rep,'violations'), violations=rep.violations; end
drc.violations=numel(violations);
drc.unconnected=0;
if isfield(rep,'unconnected_items'), drc.unconnected=numel(rep.unconnected_items); end
for i=1:numel(violations)
if iscell(violations), v=violations{i}; else, v=violations(i); end
key=matlab.lang.makeValidName(v.type);
if isfield(drc.by_type,key), drc.by_type.(key)=drc.by_type.(key)+1; else, drc.by_type.(key)=1; end
end
end


function gap=same_net_gap(num,layer_b)
%smallest gap between copper of the same net (and layer) that is far apart
%along the track; tracks are sampled every 0.05 mm
gap=inf;
key=num(:,6)*10+layer_b;
for k=unique(key)'
ss=num(key==k,:);
pts=[]; wd=[]; arc=[]; s0=0;
for r=1:size(ss,1)
len=hypot(ss(r,3)-ss(r,1),ss(r,4)-ss(r,2));
t=linspace(0,1,max(2,ceil(len/0.05)+1))';
pts=[pts; ss(r,1)+(ss(r,3)-ss(r,1))*t, ss(r,2)+(ss(r,4)-ss(r,2))*t]; %#ok<AGROW>
wd=[wd; repmat(ss(r,5),numel(t),1)]; %#ok<AGROW>
arc=[arc; s0+len*t]; %#ok<AGROW>
s0=s0+len;
end
[idx,dist]=rangesearch(pts,pts,4.5);
for i=1:numel(idx)
j=idx{i}; d=dist{i};
far=abs(arc(j)'-arc(i))>3*d+wd(j)'+wd(i)+1;
if any(far)
gap=min(gap,min(d(far)-(wd(j(far))'+wd(i))/2));
end
end
end
end


function res=width_field_check(txt,num,layer_b,coil_result,num_filaments)
map=regexp(txt,'CoilGen mapping: x0=([-\d.]+) y0=([-\d.]+) layer_gap=([\d.]+)','tokens','once');
map=str2double(map);
p=coil_result.input_data.slit_cylinder_mesh_parameter_list;
r=p(2)*1e3; rot=calc_3d_rotation_matrix_by_vector(p(5:7)',p(8)); th0=p(9)+p(10)/(2*p(2));
tc=coil_result.target_field.coords;
b_thin=zeros(3,size(tc,2)); b_wide=b_thin;
for i=1:size(num,1)
a=[num(i,1)-map(1); map(2)-num(i,2)]; b=[num(i,3)-map(1); map(2)-num(i,4)];
len=norm(b-a); if len<1e-6, continue; end
r_layer=r-layer_b(i)*map(3);
nrm=[-(b(2)-a(2)); b(1)-a(1)]/len;
b_thin=b_thin+segment_field(a,b,r_layer,r,rot,th0,tc);
for k=1:num_filaments
off=((k-0.5)/num_filaments-0.5)*num(i,5)*nrm;
b_wide=b_wide+segment_field(a+off,b+off,r_layer,r,rot,th0,tc)/num_filaments;
end
end
fit_mat=[tc' ones(size(tc,2),1)];
c_thin=fit_mat\b_thin(3,:)'; c_wide=fit_mat\b_wide(3,:)';
span=max(fit_mat*c_thin)-min(fit_mat*c_thin);
res.gradient_thin_mT_per_m_per_A=norm(c_thin(1:3))*1e3;
res.gradient_wide_mT_per_m_per_A=norm(c_wide(1:3))*1e3;
res.gradient_change_percent=(norm(c_wide(1:3))/norm(c_thin(1:3))-1)*100;
res.max_field_change_percent_of_span=max(abs(b_wide(3,:)-b_thin(3,:)))/span*100;
end


function b_field=segment_field(a,b,r_layer,r,rot,th0,pts)
%field of a straight board segment mapped onto the cylinder (1 A)
num=max(1,ceil(norm(b-a)/0.5));
q=a+(b-a).*linspace(0,1,num+1);
th=th0+q(1,:)/r;
v=rot*[r_layer*cos(th); r_layer*sin(th); q(2,:)]/1e3;
mu=1e-7; b_field=zeros(3,size(pts,2));
for i=1:size(v,2)-1
dl=v(:,i+1)-v(:,i); r1=pts-v(:,i); r2=pts-v(:,i+1);
cr=cross(repmat(dl,1,size(pts,2)),r1);
b_field=b_field+cr.*(mu*(dl'*r1./vecnorm(r1)-dl'*r2./vecnorm(r2))./max(sum(cr.^2,1),1e-30));
end
end
