function [pcb_out,pcb_report]=import_kicad_flex_pcb(coil_out,pcb_file,varargin)
%Read the copper of a flex PCB written by export_kicad_flex_pcb back into
%CoilGen and re-evaluate the field with CoilGen's own routines.
%
%The board file is parsed (tracks, vias, net ties, solder pads), the copper
%is followed from J1 to J2 as one continuous wire, mapped back onto the
%rolled cylinder (F.Cu outside, B.Cu one layer gap inside) and used as the
%wire path of the coil. Copper that is not part of the J1-J2 chain and
%branches in the chain are reported as errors, so the result is exactly
%what will be manufactured (also after editing the board in KiCad).
%
%The result has the same fields as a CoilGen output, so the functions in
%'plotting' can be used on it. Both layers carry every turn, so the
%unconnected contours are duplicated for the second layer and the contour
%step is halved: the ideal reference is then the same turns on both
%layers, and all error metrics compare like with like.

parser=inputParser;
addParameter(parser,'copper_thickness',0.035,@isnumeric); %mm
addParameter(parser,'resistivity',1.72e-8,@isnumeric); %Ohm*m
parse(parser,varargin{:});
opt=parser.Results;

txt=fileread(pcb_file);

%% Mapping from board coordinates (mm) to the cylinder
map=regexp(txt,'CoilGen mapping: x0=([-\d.]+) y0=([-\d.]+) layer_gap=([\d.]+)','tokens','once');
if isempty(map)
error('%s has no CoilGen mapping in its title block (export it with export_kicad_flex_pcb).',pcb_file);
end
x0=str2double(map{1}); y0=str2double(map{2}); layer_gap=str2double(map{3});
p=coil_out.input_data.slit_cylinder_mesh_parameter_list;
geo.r=p(2)*1e3;
geo.rot=calc_3d_rotation_matrix_by_vector(p(5:7)',p(8));
geo.th0=p(9)+p(10)/(2*p(2));

%% Copper items
edges=struct('a',{},'b',{},'pts',{},'width',{});
layer_code=@(L) double(L=='B')*1e6; %keeps the layers apart when merging endpoints
seg=regexp(txt,'\(segment\s*\(start ([-\d.]+) ([-\d.]+)\)\s*\(end ([-\d.]+) ([-\d.]+)\)\s*\(width ([\d.]+)\)\s*\(layer "([FB])\.Cu"\)','tokens');
for i=1:numel(seg)
t=seg{i}; xy=str2double(t(1:4)); L=t{6};
edges(end+1)=struct('a',[layer_code(L) xy(1:2)],'b',[layer_code(L) xy(3:4)],'pts',{{L,[xy(1:2)' xy(3:4)']}},'width',str2double(t{5})); %#ok<AGROW>
end
num_segments=numel(edges);
ties=regexp(txt,'\(footprint "CoilGen:NetTie_Turn"\s*\(layer "([FB])\.Cu"\).*?\(at ([-\d.]+) ([-\d.]+)\).*?\(fp_line\s*\(start ([-\d.]+) ([-\d.]+)\)\s*\(end ([-\d.]+) ([-\d.]+)\)\s*\(stroke\s*\(width ([\d.]+)\)','tokens');
for i=1:numel(ties)
t=ties{i}; L=t{1}; v=str2double(t(2:8));
pa=v(1:2)+v(3:4); pb=v(1:2)+v(5:6);
edges(end+1)=struct('a',[layer_code(L) pa],'b',[layer_code(L) pb],'pts',{{L,[pa' pb']}},'width',v(7)); %#ok<AGROW>
end
vias=regexp(txt,'\(via\s*\(at ([-\d.]+) ([-\d.]+)\)','tokens');
for i=1:numel(vias)
xy=str2double(vias{i});
edges(end+1)=struct('a',[layer_code('F') xy],'b',[layer_code('B') xy],'pts',{{'V',xy'}},'width',inf); %#ok<AGROW>
end
pads=regexp(txt,'\(footprint "CoilGen:SolderPad"\s*\(layer "([FB])\.Cu"\).*?\(at ([-\d.]+) ([-\d.]+)\).*?\(property "Reference" "(J\d)','tokens');
pad_key=containers.Map();
for i=1:numel(pads)
t=pads{i};
pad_key(t{4}(1:2))=[layer_code(t{1}) str2double(t(2:3))];
end
if ~isKey(pad_key,'J1') || ~isKey(pad_key,'J2')
error('Solder pads J1/J2 not found in %s.',pcb_file);
end

%% Follow the copper from J1 to J2
%endpoints closer than 5 um are the same node (KiCad stores footprint
%items relative to the footprint, which rounds differently)
ends=[vertcat(edges.a); vertcat(edges.b)];
[node_xy,~,ic]=uniquetol(ends,0.005,'ByRows',true,'DataScale',1);
ea=ic(1:numel(edges))'; eb=ic(numel(edges)+1:end)';
layer_names='FB';
keys=arrayfun(@(i) sprintf('%s (%.3f, %.3f)',layer_names(1+(node_xy(i,1)>0)),node_xy(i,2),node_xy(i,3)),1:size(node_xy,1),'UniformOutput',false);
degree=accumarray([ea eb]',1,[numel(keys) 1])';
[~,start]=min(vecnorm(node_xy-pad_key('J1'),2,2));
[~,goal]=min(vecnorm(node_xy-pad_key('J2'),2,2));
branch_nodes=find(degree>2);
if ~isempty(branch_nodes)
error('The copper branches at %d points (e.g. %s); it is not a single series chain.',numel(branch_nodes),keys{branch_nodes(1)});
end
used=false(1,numel(edges));
path_xy=[]; path_layer=''; node=start;
while node~=goal
e=find(~used & (ea==node | eb==node),1);
if isempty(e)
error('The copper chain from J1 ends at %s before reaching J2.',keys{node});
end
used(e)=true;
item=edges(e).pts;
if strcmp(item{1},'V')
next=ea(e)+eb(e)-node; %layer change, same position
continue_layer=keys{next}(1);
path_xy=[path_xy item{2}]; path_layer=[path_layer continue_layer]; %#ok<AGROW>
node=next;
continue;
end
pts=item{2};
if eb(e)==node, pts=fliplr(pts); end
path_xy=[path_xy pts]; path_layer=[path_layer repmat(item{1},1,2)]; %#ok<AGROW>
node=ea(e)+eb(e)-node;
end
num_unused=sum(~used);
if num_unused>0
error('%d copper items are not part of the chain from J1 to J2.',num_unused);
end

%% Map onto the cylinder
s=path_xy(1,:)-x0; a=y0-path_xy(2,:);
r_layer=geo.r-(path_layer=='B')*layer_gap;
dense_s=s(1); dense_a=a(1); dense_r=r_layer(1);
for i=1:numel(s)-1
len=hypot(s(i+1)-s(i),a(i+1)-a(i));
n=max(1,ceil(len/0.5)); t=(1:n)/n;
r_i=r_layer(i+1)*ones(1,n);
if len<1e-9, r_i=r_layer(i+1); t=1; end
dense_s=[dense_s s(i)+(s(i+1)-s(i))*t]; %#ok<AGROW>
dense_a=[dense_a a(i)+(a(i+1)-a(i))*t]; %#ok<AGROW>
dense_r=[dense_r r_i]; %#ok<AGROW>
end
th=geo.th0+dense_s/geo.r;
wire_v=geo.rot*[dense_r.*cos(th); dense_r.*sin(th); dense_a]/1e3;

%% CoilGen evaluation of the manufactured copper
pcb_out=coil_out;
cp=pcb_out.coil_parts(1);
cp.wire_path.v=wire_v;
cp.wire_path.uv=[dense_s; dense_a]/1e3;
%ideal reference: the same turns on both layers
num_loops=numel(cp.contour_lines);
for loop_ind=1:num_loops
q=geo.rot'*cp.contour_lines(loop_ind).v;
q(1:2,:)=q(1:2,:)*(geo.r-layer_gap)/geo.r;
cp.contour_lines(num_loops+loop_ind).v=geo.rot*q;
cp.contour_lines(num_loops+loop_ind).uv=cp.contour_lines(loop_ind).uv;
end
cp.contour_step=cp.contour_step/2;
input=pcb_out.input_data;
input.skip_postprocessing=false;
[cp,field_by_layout,field_by_unconnected_loops,field_layout_per1Amp,field_loops_per1Amp,field_error_vals,opt_current_layout,sf_b_field_1A,target_field_1A]= ...
    evaluate_field_errors(cp,input,coil_out.target_field,coil_out.b_field_opt_sf);
layout_gradient=calculate_gradient(cp,coil_out.target_field,input);

pcb_out.coil_parts=cp;
pcb_out.input_data=input;
pcb_out.potential_step=cp.contour_step;
pcb_out.field_by_layout=field_by_layout;
pcb_out.field_by_unconnected_loops=field_by_unconnected_loops;
pcb_out.field_layout_per1Amp=field_layout_per1Amp;
pcb_out.field_loops_per1Amp=field_loops_per1Amp;
pcb_out.needed_current_layout=opt_current_layout;
pcb_out.b_field_opt_sf_1A=sf_b_field_1A;
pcb_out.target_field_1A=target_field_1A;
pcb_out.error_vals=field_error_vals;
pcb_out.layout_gradient=layout_gradient;

%% Report
seg_len=arrayfun(@(e) norm(diff(e.pts{2},1,2)),edges(1:end-numel(vias)));
seg_w=[edges(1:end-numel(vias)).width];
pcb_report.num_segments=num_segments;
pcb_report.num_net_ties=numel(ties);
pcb_report.num_vias=numel(vias);
pcb_report.copper_length_m=sum(seg_len)/1e3;
pcb_report.resistance_ohm=opt.resistivity*sum(seg_len./seg_w)/(opt.copper_thickness/1e3);
pcb_report.current_J1_to_J2_matches_design=isequal(cp.wire_path.v(:,1),wire_v(:,1));
pcb_report.mean_gradient_mT_per_m_per_A=layout_gradient.mean_gradient_in_target_direction;
pcb_report.std_gradient_mT_per_m_per_A=layout_gradient.std_gradient_in_target_direction;
pcb_report.error_vals=field_error_vals;
end


