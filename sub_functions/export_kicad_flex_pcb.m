function report=export_kicad_flex_pcb(coil_out,pcb_file,varargin)
%Export a CoilGen result on a slit cylinder ('create slit cylinder mesh') as a
%2-layer flex PCB for KiCad (.kicad_pcb + .kicad_pro with design rules).
%
%Each loop group becomes a series 2-layer spiral: it spirals in on F.Cu,
%goes through one via inside the innermost turn and spirals out on B.Cu, so
%both layers carry the full winding pattern and the current per turn adds up.
%The spirals are opened towards a copper free axial channel (the end margin
%or a free band between the groups) where the groups are linked in series
%and led to the solder pads J1 (F.Cu) and J2 (B.Cu) on a tab at the seam.
%Every turn has its own net, joined by net-tie footprints, so the KiCad DRC
%checks the clearance between all turns.
%
%Board coordinates: x = arc length along the circumference, y = -axial
%position; F.Cu is the outside of the rolled cylinder.
%
%Lengths in the options are in mm. Returns a report with efficiency,
%resistance, inductance estimate and the geometry used.

parser=inputParser;
addParameter(parser,'track_width',[],@isnumeric); %[] => derived from the minimal turn spacing
addParameter(parser,'clearance',0.15,@isnumeric);
addParameter(parser,'cut_width',6,@isnumeric); %length of the opening in each turn where the spiral steps to the next turn
addParameter(parser,'via_diameter',0.6,@isnumeric);
addParameter(parser,'via_drill',0.3,@isnumeric);
addParameter(parser,'edge_clearance',0.3,@isnumeric);
addParameter(parser,'seam_gap',0.5,@isnumeric); %gap between the two board edges at the seam when rolled
addParameter(parser,'end_margin',1.5,@isnumeric); %board extension beyond the coil surface at the ends
addParameter(parser,'tab_length',6,@isnumeric);
addParameter(parser,'pad_size',2.5,@isnumeric);
addParameter(parser,'copper_thickness',0.035,@isnumeric);
addParameter(parser,'layer_gap',0.1,@isnumeric); %F.Cu to B.Cu distance, used for the field evaluation
addParameter(parser,'resistivity',1.72e-8,@isnumeric); %Ohm*m
addParameter(parser,'title','CoilGen flex coil',@ischar);
addParameter(parser,'net_prefix','',@ischar);
addParameter(parser,'calc_inductance',true,@islogical);
addParameter(parser,'variable_width',true,@islogical); %widen each turn to the locally available space
addParameter(parser,'max_track_width',4,@isnumeric);
%alignment marks on F.SilkS: {direction (3x1, coil frame), label; ...}; an
%axial line is drawn where the cylinder surface faces that direction
addParameter(parser,'axis_marks',{},@iscell);
addParameter(parser,'axial_label','',@ischar); %label for the +axial board direction (board up)
%gradient direction (3x1, coil frame) that counts as positive; the pads are
%then labelled so that current into the '+' pad gives a positive gradient
addParameter(parser,'positive_gradient',[],@isnumeric);
parse(parser,varargin{:});
opt=parser.Results;

in=coil_out.input_data;
if ~strcmp(in.coil_mesh_file,'create slit cylinder mesh')
error('export_kicad_flex_pcb requires a coil designed on a ''create slit cylinder mesh'' surface.');
end
if numel(coil_out.coil_parts)~=1
error('export_kicad_flex_pcb supports a single coil part.');
end
cp=coil_out.coil_parts(1);

%% Geometry of the unrolled slit cylinder (mm)
p=in.slit_cylinder_mesh_parameter_list;
geo.height=p(1)*1e3;
geo.r=p(2)*1e3;
geo.rot=calc_3d_rotation_matrix_by_vector(p(5:7)',p(8));
geo.slit_w=p(10)*1e3;
geo.th0=p(9)+p(10)/(2*p(2)); %angle of the board start edge
geo.c_mesh=geo.r*(2*pi)-geo.slit_w;
ext=(geo.slit_w-opt.seam_gap)/2;
geo.s_left=-ext;
geo.s_right=geo.c_mesh+ext;
geo.a_min=-geo.height/2;
geo.a_max=geo.height/2;

%% Loops in board coordinates, grouped by nesting
loops=cell(1,numel(cp.contour_lines));
for loop_ind=1:numel(cp.contour_lines)
loops{loop_ind}=resample_closed(to_board(cp.contour_lines(loop_ind).v,geo),0.25);
end
[groups,num_dropped]=group_loops(loops);
if num_dropped>0
warning('%d loops nested as side branches inside other groups were dropped.',num_dropped);
end

%minimal spacing between any two turns
all_pts=[]; all_ids=[];
for loop_ind=1:numel(loops)
all_pts=[all_pts loops{loop_ind}]; %#ok<AGROW>
all_ids=[all_ids loop_ind*ones(1,size(loops{loop_ind},2))]; %#ok<AGROW>
end
used=ismember(all_ids,[groups{:}]);
[nn_ids,nn_dist]=knnsearch(all_pts(:,used)',all_pts(:,used)','K',40);
used_ids=all_ids(used);
min_pitch=inf;
for pt_ind=1:size(nn_ids,1)
other=used_ids(nn_ids(pt_ind,:))~=used_ids(pt_ind);
if any(other), min_pitch=min(min_pitch,min(nn_dist(pt_ind,other))); end
end
if isempty(opt.track_width)
step_factor=(opt.cut_width/2)/sqrt((opt.cut_width/2)^2+min_pitch^2); %steps in the opening run diagonally
w=floor((min_pitch*step_factor-opt.clearance-0.05)/0.05)*0.05;
else
w=opt.track_width;
end
if w<=0
error('Turns are too close (%.2f mm) for the clearance of %.2f mm.',min_pitch,opt.clearance);
end
clr=opt.clearance; via_r=opt.via_diameter/2;

%% Routing channel
copper_a=cellfun(@(g) [min(loops{g(1)}(2,:)) max(loops{g(1)}(2,:))],groups,'UniformOutput',false);
copper_a=vertcat(copper_a{:});
channel=choose_channel(copper_a,w,clr,via_r,opt);

%% Spirals per group
group_data=cell(1,numel(groups));
chosen_s=[];
for group_ind=1:numel(groups)
side=channel.side(group_ind); %+1: channel above the group, -1: below
group_loops_2d=loops(groups{group_ind});
x1=select_cut_start(group_loops_2d{1},side,chosen_s,opt.cut_width,geo);
chosen_s(end+1)=x1(1); %#ok<AGROW>
group_data{group_ind}=build_group_spiral(group_loops_2d,x1,w,clr,via_r,opt.cut_width);
group_data{group_ind}.side=side;
end

%% Assemble board: tracks (flow order), net ties, vias, pads
nets={''};
tracks=struct('pts',{},'layer',{},'net',{},'kind',{},'body',{},'loop_id',{});
ties=struct('pa',{},'pb',{},'layer',{},'net_a',{},'net_b',{});
vias=struct('at',{},'net',{});
pads=struct('at',{},'net',{},'name',{},'layer',{},'label',{});

lead_s=cellfun(@(g) min(g.s_in,g.s_out),group_data);
[~,chain]=sort(lead_s);
h_f=channel.h_f; h_ret=channel.h_ret;
d_via=max(via_r,w/2)+w/2+clr+0.1;
tie_len=w+0.25;

%solder pads on the tab at the seam: J1 (F.Cu) feeds the chain, J2 (B.Cu,
%directly behind J1) collects the return trace that runs back under the
%links, so the feed is coaxial and there is no net circumferential current
sl=geo.s_left; sr=geo.s_right; tl=opt.tab_length; ps=opt.pad_size;
j1=[sl-1-ps/2; h_f];
j2=[j1(1); h_ret];
if j1(1)-ps/2<sl-tl+opt.edge_clearance
error('tab_length is too short for the solder pads.');
end

prev_net=[opt.net_prefix 'COIL_A'];
nets{end+1}=prev_net;
pads(end+1)=struct('at',j1,'net',prev_net,'name','J1','layer','F','label','J1');
link_start=j1;

for chain_ind=1:numel(chain)
gd=group_data{chain(chain_ind)};
gname=sprintf('%sG%d',opt.net_prefix,chain_ind);
n=numel(gd.open);
is_last=chain_ind==numel(chain);
if gd.side>0, h_b=channel.h_b_low; else, h_b=channel.h_b_high; end
top_net=@(k) sprintf('%s_T%d',gname,k);
bot_net=@(k) sprintf('%s_B%d',gname,k);
for k=1:n, nets{end+1}=top_net(k); end %#ok<AGROW>
for k=1:n-1, nets{end+1}=bot_net(k); end %#ok<AGROW>
out_net=bot_net(1);
if n==1, out_net=top_net(1); end

%incoming link (F) and tie into the IN lead
in_top=[gd.s_in; h_f];
pa=in_top-[sign(in_top(1)-link_start(1))*tie_len; 0];
tracks(end+1)=struct('pts',[link_start pa],'layer','F','net',prev_net,'kind','link','body',[false false],'loop_id',0); %#ok<AGROW>
ties(end+1)=struct('pa',pa,'pb',in_top,'layer','F','net_a',prev_net,'net_b',top_net(1)); %#ok<AGROW>

%top layer: spiral in
for k=1:n
pts=gd.open{k};
if k==1, pts=[in_top pts]; end %#ok<AGROW>
if k<n
[entry,pa]=trim_path_end(gd.entry{k+1},tie_len);
body=[false(1,double(k==1)) true(1,size(gd.open{k},2)) false(1,size(entry,2)+1)];
tracks(end+1)=struct('pts',[pts entry pa],'layer','F','net',top_net(k),'kind','spiral','body',body,'loop_id',chain_ind*1000+k); %#ok<AGROW>
ties(end+1)=struct('pa',pa,'pb',gd.open{k+1}(:,1),'layer','F','net_a',top_net(k),'net_b',top_net(k+1)); %#ok<AGROW>
else
body=[false(1,double(k==1)) true(1,size(gd.open{k},2)) false];
tracks(end+1)=struct('pts',[pts gd.via],'layer','F','net',top_net(k),'kind','spiral','body',body,'loop_id',chain_ind*1000+k); %#ok<AGROW>
end
end
vias(end+1)=struct('at',gd.via,'net',top_net(n)); %#ok<AGROW>

%bottom layer: spiral out
for k=n:-1:1
pts=gd.open{k};
if k==n, pts=[gd.via pts]; end
if k==n, net_k=top_net(n); else, net_k=bot_net(k); end
if k>1
[entry,pa]=trim_path_end(gd.entry{k-1},tie_len);
body=[false(1,double(k==n)) true(1,size(gd.open{k},2)) false(1,size(entry,2)+1)];
tracks(end+1)=struct('pts',[pts entry pa],'layer','B','net',net_k,'kind','spiral','body',body,'loop_id',chain_ind*1000+k); %#ok<AGROW>
ties(end+1)=struct('pa',pa,'pb',gd.open{k-1}(:,1),'layer','B','net_a',net_k,'net_b',bot_net(k-1)); %#ok<AGROW>
else
%OUT lead to the channel and over to the via right next to the IN lead,
%so the links continue where the current left them
s_via=gd.s_in+d_via;
body=[false(1,double(k==n)) true(1,size(gd.open{k},2)) false false];
tracks(end+1)=struct('pts',[pts [gd.s_out; h_b] [s_via; h_b]],'layer','B','net',net_k,'kind','spiral','body',body,'loop_id',chain_ind*1000+k); %#ok<AGROW>
if ~is_last
vias(end+1)=struct('at',[s_via; h_b],'net',net_k); %#ok<AGROW>
tracks(end+1)=struct('pts',[[s_via; h_b] [s_via; h_f]],'layer','F','net',net_k,'kind','link','body',[false false],'loop_id',0); %#ok<AGROW>
link_start=[s_via; h_f];
else
%last group: return on B.Cu under the links back to J2
tracks(end+1)=struct('pts',[[s_via; h_b] [s_via; h_ret] j2],'layer','B','net',net_k,'kind','link','body',false(1,3),'loop_id',0); %#ok<AGROW>
end
end
end
prev_net=out_net;
end
pads(end+1)=struct('at',j2,'net',prev_net,'name','J2','layer','B','label','J2');
nets=unique(nets,'stable');

%% Board outline with the solder pad tab at the seam
th=ps+2;
tab_a=h_f;
a_lo=min(geo.a_min-opt.end_margin,channel.board_a(1));
a_hi=max(geo.a_max+opt.end_margin,channel.board_a(2));
outline=[sl a_lo; sr a_lo; sr a_hi; sl a_hi; sl tab_a+th/2; sl-tl tab_a+th/2; sl-tl tab_a-th/2; sl tab_a-th/2]';

%% Track widths
%turns are also narrowed where they come close to themselves, which the
%KiCad DRC can't check (same net)
width_opt=opt;
if ~opt.variable_width, width_opt.max_track_width=w; end
tracks=widen_tracks(tracks,ties,vias,pads,w,[sl sr a_lo a_hi],width_opt);
same_net_gap=min_same_net_gap(tracks);
if same_net_gap<opt.clearance-1e-3
warning('Copper of the same net comes within %.3f mm of itself (clearance %.2f mm).',same_net_gap,opt.clearance);
end


%% Evaluate the exported copper
paths_3d={};
for track_ind=1:numel(tracks)
pts=tracks(track_ind).pts;
r_layer=geo.r-(tracks(track_ind).layer=='B')*opt.layer_gap;
paths_3d{end+1}=to_3d(pts,r_layer,geo); %#ok<AGROW>
end
for tie_ind=1:numel(ties)
r_layer=geo.r-(ties(tie_ind).layer=='B')*opt.layer_gap;
paths_3d{end+1}=to_3d([ties(tie_ind).pa ties(tie_ind).pb],r_layer,geo); %#ok<AGROW>
end
target_coords=coil_out.target_field.coords;
b_field=zeros(3,size(target_coords,2));
b_links=zeros(3,size(target_coords,2));
is_link=[strcmp({tracks.kind},'link') false(1,numel(ties))];
for path_ind=1:numel(paths_3d)
b_path=biot_savart_polyline(paths_3d{path_ind},target_coords);
b_field=b_field+b_path;
if is_link(path_ind), b_links=b_links+b_path; end
end
fit_mat=[target_coords' ones(size(target_coords,2),1)];
fit_coeffs=fit_mat\b_field(3,:)';
fitted=fit_mat*fit_coeffs;
b_spirals=b_field(3,:)'-b_links(3,:)';
fit_spirals=fit_mat*(fit_mat\b_spirals);
seg_len=cellfun(@(q) vecnorm(diff(q,1,2)),{tracks.pts},'UniformOutput',false);
total_len=sum(cellfun(@sum,seg_len))+numel(ties)*tie_len;
squares=sum(cellfun(@(l,wd) sum(l./wd),seg_len,{tracks.widths}))+numel(ties)*tie_len/w;

%% Polarity and alignment marks
pad_sign=[1 -1];
if ~isempty(opt.positive_gradient)
pad_sign=pad_sign*sign(fit_coeffs(1:3)'*opt.positive_gradient(:));
end
sign_txt={'-','','+'};
for pad_ind=1:2
pads(pad_ind).label=[pads(pad_ind).name sign_txt{pad_sign(pad_ind)+2}];
end
silk_lines={}; silk_texts=struct('at',{},'angle',{},'text',{},'size',{});
for mark_ind=1:size(opt.axis_marks,1)
q=geo.rot'*opt.axis_marks{mark_ind,1}(:);
s_mark=mod(atan2(q(2),q(1))-geo.th0,2*pi)*geo.r;
if s_mark>geo.c_mesh, s_mark=min(max(s_mark,geo.c_mesh),geo.s_right-1); end
silk_lines{end+1}=[s_mark s_mark; a_lo+1 a_hi-1]; %#ok<AGROW>
for a_txt=[a_lo+4 (a_lo+a_hi)/2+4]
silk_texts(end+1)=struct('at',[s_mark+1.2; a_txt],'angle',90,'text',opt.axis_marks{mark_ind,2},'size',1.5); %#ok<AGROW>
end
end
if ~isempty(opt.axial_label)
for s_txt=[geo.s_left+3 geo.s_right-3]
silk_texts(end+1)=struct('at',[s_txt; a_lo+4],'angle',90,'text',[opt.axial_label ' -->'],'size',1.5); %#ok<AGROW>
end
end
silk_texts(end+1)=struct('at',[geo.s_left+2; tab_a-(ps/2+2.5)],'angle',0, ...
    'text',sprintf('%s outside, %s inside',pads(1).label,pads(2).label),'size',1); %#ok<AGROW>

%% Write KiCad files
board.tracks=tracks; board.ties=ties; board.vias=vias; board.pads=pads; board.nets=nets;
board.outline=outline; board.w=w; board.opt=opt; board.geo=geo; board.channel=channel;
board.silk_lines=silk_lines; board.silk_texts=silk_texts;
write_kicad_pcb(pcb_file,board);
write_kicad_pro(pcb_file,board);

report.track_width_mm=w;
report.min_turn_spacing_mm=min_pitch;
report.num_groups=numel(groups);
report.turns_per_group=cellfun(@(g) numel(g.open),group_data(chain));
report.dropped_loops=num_dropped+sum(cellfun(@(g) g.dropped,group_data));
report.gradient_mT_per_m_per_A=fit_coeffs(1:3)'*1e3;
report.efficiency_mT_per_m_per_A=norm(fit_coeffs(1:3))*1e3;
report.nonlinearity_percent=max(abs(b_field(3,:)'-fitted))/(max(fitted)-min(fitted))*100;
report.nonlinearity_spirals_only_percent=max(abs(b_spirals-fit_spirals))/(max(fit_spirals)-min(fit_spirals))*100;
report.track_length_m=total_len/1e3;
report.resistance_ohm=opt.resistivity*squares/(opt.copper_thickness/1e3);
all_w=[tracks.widths]; all_l=[seg_len{:}];
report.mean_track_width_mm=total_len/squares;
report.max_track_width_mm=max(all_w);
report.min_track_width_mm=min(all_w);
report.min_same_net_gap_mm=same_net_gap;
report.inductance_H=NaN;
if opt.calc_inductance
report.inductance_H=filament_inductance(paths_3d,w,opt.copper_thickness);
end
report.channel=channel;
report.board_size_mm=[max(outline(1,:))-min(outline(1,:)) max(outline(2,:))-min(outline(2,:))];
report.num_nets=numel(nets)-1;
report.num_net_ties=numel(ties);

end


%% ===================== geometry helpers =====================

function pts=to_board(v,geo)
%3D points (m) to board coordinates (mm): s along the circumference, a axial
q=geo.rot'*v*1e3;
th=mod(atan2(q(2,:),q(1,:))-geo.th0,2*pi);
pts=[th*geo.r; q(3,:)];
end

function v=to_3d(pts,r_layer,geo)
%board coordinates (mm) to 3D points (m); straight board segments are
%subdivided so that they follow the cylinder surface
seg=vecnorm(diff(pts,1,2));
num=max(1,ceil(seg/0.5));
dense=pts(:,1);
for i=1:numel(seg)
t=(1:num(i))/num(i);
dense=[dense pts(:,i)+(pts(:,i+1)-pts(:,i)).*t]; %#ok<AGROW>
end
pts=dense;
th=geo.th0+pts(1,:)/geo.r;
q=[r_layer*cos(th); r_layer*sin(th); pts(2,:)];
v=geo.rot*q/1e3;
end

function out=resample_closed(pts,step)
%uniformly resample a closed polyline (first point not repeated)
if norm(pts(:,1)-pts(:,end))<1e-9, pts=pts(:,1:end-1); end
keep=[true vecnorm(diff(pts,1,2))>1e-9];
pts=pts(:,keep);
closed=[pts pts(:,1)];
s=[0 cumsum(vecnorm(diff(closed,1,2)))];
num=max(ceil(s(end)/step),8);
t=linspace(0,s(end),num+1); t(end)=[];
out=interp1(s,closed',t)';
end

function [groups,num_dropped]=group_loops(loops)
%nest the loops; each group is a chain of loops from outer to inner
num_loops=numel(loops);
area=cellfun(@(q) polyarea(q(1,:),q(2,:)),loops);
parent=zeros(1,num_loops);
for i=1:num_loops
best=inf;
for j=1:num_loops
if i~=j && area(j)>area(i) && area(j)<best && inpolygon(loops{i}(1,1),loops{i}(2,1),loops{j}(1,:),loops{j}(2,:))
best=area(j); parent(i)=j;
end
end
end
groups={};
num_dropped=0;
for root=find(parent==0)
chain=root;
while true
children=find(parent==chain(end));
if isempty(children), break; end
%follow the child with the largest nested subtree; drop side branches
subtree_size=arrayfun(@(c) count_subtree(c,parent),children);
[~,best]=max(subtree_size);
num_dropped=num_dropped+sum(subtree_size)-subtree_size(best);
chain(end+1)=children(best); %#ok<AGROW>
end
groups{end+1}=chain; %#ok<AGROW>
end
end

function n=count_subtree(node,parent)
n=1;
for child=find(parent==node)
n=n+count_subtree(child,parent);
end
end

function channel=choose_channel(copper_a,w,clr,via_r,opt)
%find a copper free axial band reachable by all groups; prefer an internal
%band (shorter leads), otherwise the end margin above the coil.
%Levels: h_b_low (B.Cu + vias of the groups below), h_f = h_ret (F.Cu links
%and B.Cu return), h_b_high (B.Cu + vias of the groups above)
num_groups=size(copper_a,1);
half=max(via_r,w/2);
step=half+w/2+clr;
need=2*(clr+half)+2*step;
lo_edges=copper_a(:,2)+w/2;
hi_edges=copper_a(:,1)-w/2;
candidates=[];
for band_lo=sort(lo_edges)'
above=hi_edges(hi_edges>band_lo);
if isempty(above), continue; end
band_hi=min(above);
separated=all(lo_edges<=band_lo+1e-9 | hi_edges>=band_hi-1e-9);
if separated && band_hi-band_lo>=need
candidates=[candidates; band_lo band_hi]; %#ok<AGROW>
end
end
if ~isempty(candidates)
[~,best]=max(candidates(:,2)-candidates(:,1));
band=candidates(best,:);
channel.type='internal';
channel.side=(copper_a(:,2)<=band(1)+1e-9)'*2-1; %+1: group below the band
channel.h_b_low=band(1)+clr+half;
channel.board_a=[inf -inf];
else
channel.type='end';
channel.side=ones(1,num_groups);
channel.h_b_low=max(lo_edges)+clr+half;
end
channel.h_f=channel.h_b_low+step;
channel.h_ret=channel.h_f;
channel.h_b_high=channel.h_f+step;
if strcmp(channel.type,'end')
channel.board_a=[inf channel.h_f+opt.pad_size/2+1.5];
end
end

function x1=select_cut_start(outer,side,chosen_s,cut_width,geo)
%point of the outer turn that faces the channel; spread the leads of
%different groups along the circumference
if side>0, extreme=max(outer(2,:)); facing=outer(2,:)>extreme-0.3;
else, extreme=min(outer(2,:)); facing=outer(2,:)<extreme+0.3; end
cand=outer(:,facing);
cand=cand(:,cand(1,:)>geo.s_left+cut_width+5 & cand(1,:)<geo.s_right-cut_width-5);
if isempty(cand), cand=outer(:,facing); end
center_s=mean(cand(1,:));
min_sep=3*cut_width+4;
score=abs(cand(1,:)-center_s);
for s_other=chosen_s
score(abs(cand(1,:)-s_other)<min_sep)=inf;
end
if all(isinf(score))
dist_other=min(abs(cand(1,:)-chosen_s(:)),[],1);
[~,ind]=max(dist_other);
else
[~,ind]=min(score);
end
x1=cand(:,ind);
end

function gd=build_group_spiral(group_loops_2d,x1,w,clr,via_r,cut_width)
%open each turn at the cut chain and place the via inside the innermost
%turn; inner turns without room for the via are dropped
n=numel(group_loops_2d);
cut=zeros(2,n); t_cut=zeros(1,n);
[cut(:,1),t_cut(1)]=closest_on_loop(group_loops_2d{1},x1);
for k=2:n
[cut(:,k),t_cut(k)]=closest_on_loop(group_loops_2d{k},cut(:,k-1));
end
via=[];
while n>=1
inner_open=open_loop(group_loops_2d{n},t_cut(n),cut_width);
via=find_via(group_loops_2d{n},inner_open,w,clr,via_r);
if ~isempty(via), break; end
n=n-1;
end
if isempty(via)
error('No room for the inner via in a loop group.');
end
gd.open=cell(1,n);
gd.entry=cell(1,n);
for k=1:n
gd.open{k}=open_loop(group_loops_2d{k},t_cut(k),cut_width);
gd.entry{k}=loop_section(group_loops_2d{k},t_cut(k),t_cut(k)+cut_width/2);
end
gd.via=via;
gd.s_in=gd.open{1}(1,1);
gd.s_out=gd.open{1}(1,end);
gd.dropped=numel(group_loops_2d)-n;
end

function via=find_via(loop,inner_open,w,clr,via_r)
%via position inside the innermost turn, as close as possible to the
%opening, with straight stubs to both ends of the turn that stay clear of it
via=[];
s_pt=inner_open(:,1); e_pt=inner_open(:,end);
[gx,gy]=meshgrid(min(loop(1,:)):0.2:max(loop(1,:)),min(loop(2,:)):0.2:max(loop(2,:)));
cand=[gx(:)'; gy(:)'];
cand=cand(:,inpolygon(cand(1,:),cand(2,:),loop(1,:),loop(2,:)));
if isempty(cand), return; end
dense=resample_closed(loop,0.1);
room=min(pdist2(cand',dense'),[],2)';
cand=cand(:,room>=max(via_r,w/2)+w/2+clr+0.05);
if isempty(cand), return; end
[~,order]=sort(vecnorm(cand-(s_pt+e_pt)/2));
for i=order(1:min(400,end))
v=cand(:,i);
if stub_clear(e_pt,v,dense,w,clr) && stub_clear(s_pt,v,dense,w,clr)
via=v; return;
end
end
end

function ok=stub_clear(start_pt,end_pt,dense_loop,w,clr)
len=norm(end_pt-start_pt);
t0=1.5*(w+clr);
if len<=t0, ok=true; return; end
t=t0:0.1:len;
pts=start_pt+(end_pt-start_pt)./len.*t;
ok=all(min(pdist2(pts',dense_loop'),[],2)>=w+clr);
end

function [pt,t]=closest_on_loop(loop,x)
closed=[loop loop(:,1)];
a=closed(:,1:end-1); b=closed(:,2:end);
ab=b-a;
u=max(0,min(1,sum((x-a).*ab,1)./max(sum(ab.^2,1),eps)));
proj=a+ab.*u;
[~,i]=min(vecnorm(proj-x));
pt=proj(:,i);
seg_len=vecnorm(ab);
cum=[0 cumsum(seg_len)];
t=cum(i)+u(i)*seg_len(i);
end

function path=open_loop(loop,t_cut,cut_width)
%open the closed loop around arc position t_cut; the path starts after the
%opening (downstream) and ends before it (upstream), following the current
perimeter=sum(vecnorm(diff([loop loop(:,1)],1,2)));
path=loop_section(loop,t_cut+cut_width/2,t_cut+cut_width/2+perimeter-cut_width);
end

function path=loop_section(loop,t_start,t_end)
%section of the closed loop between the arc positions t_start and t_end
%(t_end-t_start < perimeter), following the loop direction
num=size(loop,2);
s=[0 cumsum(vecnorm(diff([loop loop(:,1)],1,2)))];
perimeter=s(end);
ext_pts=[loop loop loop(:,1)];
ext_s=[s(1:num) s(1:num)+perimeter 2*perimeter];
t_end=mod(t_start,perimeter)+(t_end-t_start);
t_start=mod(t_start,perimeter);
t=[t_start ext_s(ext_s>t_start & ext_s<t_end) t_end];
path=interp1(ext_s,ext_pts',t)';
path=simplify_path(path,0.002);
end

function [head,cut_pt]=trim_path_end(path,len)
%shorten a path by the arc length len; returns the remaining points without
%the new end point and the new end point
seg=vecnorm(diff(path,1,2));
s=[0 cumsum(seg)];
target=max(s(end)-len,0);
cut_pt=interp1(s,path',target)';
head=path(:,s<target);
end

function out=simplify_path(pts,tol)
%remove points lying on the straight line between their neighbours
keep=true(1,size(pts,2));
last=1;
for i=2:size(pts,2)-1
a=pts(:,last); b=pts(:,i+1); c=pts(:,i);
ab=b-a;
d=abs(ab(1)*(c(2)-a(2))-ab(2)*(c(1)-a(1)))/max(norm(ab),eps);
if d<tol && norm(c-a)<5
keep(i)=false;
else
last=i;
end
end
out=pts(:,keep);
end


%% ===================== variable track width =====================

function tracks=widen_tracks(tracks,ties,vias,pads,w,rect,opt)
%widen the turn bodies to the locally available space: each body piece
%(<=1 mm) gets the largest width that keeps the clearance to the other turns
%(which widen by the same rule), to all fixed width copper and to the edge.
%Fixed width: leads, steps between turns, stubs, links, ties, vias, pads.
clr=opt.clearance+0.02; w_max=opt.max_track_width; sample=0.2; %margin for the sampled distances

%widenable copper: one centerline per turn (both layers share it)
wid_pts=[]; wid_loop=[]; wid_arc=[];
seen=[];
for i=1:numel(tracks)
lid=tracks(i).loop_id;
if lid==0 || any(seen==lid), continue; end
seen(end+1)=lid; %#ok<AGROW>
[q,a]=densify(tracks(i).pts(:,tracks(i).body),sample);
wid_pts=[wid_pts q]; wid_loop=[wid_loop lid*ones(1,size(q,2))]; wid_arc=[wid_arc a]; %#ok<AGROW>
end

%fixed copper with its half width
fix_pts=[]; fix_half=[];
for i=1:numel(tracks)
pts=tracks(i).pts; body=tracks(i).body;
for j=1:size(pts,2)-1
if body(j) && body(j+1), continue; end
q=densify(pts(:,j:j+1),sample);
fix_pts=[fix_pts q]; fix_half=[fix_half w/2*ones(1,size(q,2))]; %#ok<AGROW>
end
end
for i=1:numel(ties)
q=densify([ties(i).pa ties(i).pb],sample);
fix_pts=[fix_pts q]; fix_half=[fix_half w/2*ones(1,size(q,2))]; %#ok<AGROW>
end
fix_pts=[fix_pts [vias.at] [pads.at]];
fix_half=[fix_half opt.via_diameter/2*ones(1,numel(vias)) opt.pad_size/sqrt(2)*ones(1,numel(pads))];

%split the body segments into pieces of <=1 mm and collect sample points
pieces=struct('track',{},'pts',{},'width',{},'is_body',{});
q_all=[]; qa_all=[]; ql_all=[]; qp_all=[];
for i=1:numel(tracks)
pts=tracks(i).pts; body=tracks(i).body;
arc0=0;
for j=1:size(pts,2)-1
seg=pts(:,j+1)-pts(:,j); len=norm(seg);
if ~(body(j) && body(j+1))
pieces(end+1)=struct('track',i,'pts',pts(:,j+1),'width',w,'is_body',false); %#ok<AGROW>
continue;
end
num_pieces=max(1,ceil(len/1));
for piece=1:num_pieces
t0=(piece-1)/num_pieces; t1=piece/num_pieces;
t=linspace(t0,t1,max(2,ceil((t1-t0)*len/sample)+1));
pieces(end+1)=struct('track',i,'pts',pts(:,j)+seg*t1,'width',w,'is_body',true); %#ok<AGROW>
q_all=[q_all pts(:,j)+seg.*t]; qa_all=[qa_all arc0+len*t]; %#ok<AGROW>
ql_all=[ql_all tracks(i).loop_id*ones(1,numel(t))]; qp_all=[qp_all numel(pieces)*ones(1,numel(t))]; %#ok<AGROW>
end
arc0=arc0+len;
end
end

%available width at all samples, batched per turn
wq_all=zeros(1,size(q_all,2)); ws_all=wq_all;
for lid=unique(ql_all)
sel=ql_all==lid;
[wq_all(sel),ws_all(sel)]=available_width(q_all(:,sel),qa_all(sel),lid,wid_pts,wid_loop,wid_arc,fix_pts,fix_half,rect,clr,opt.edge_clearance);
end
piece_w=accumarray(qp_all',wq_all',[numel(pieces) 1],@min,inf)';
piece_self=accumarray(qp_all',ws_all',[numel(pieces) 1],@min,inf)';
for k=find([pieces.is_body])
%the base width is clear of all other nets (checked by the DRC); where a
%turn comes close to itself it is narrowed below the base width
width_k=min(max(floor(piece_w(k)/0.05)*0.05,w),w_max);
pieces(k).width=min(width_k,floor(piece_self(k)/0.05)*0.05);
if pieces(k).width<0.1
error('A turn comes too close to itself for a track (%.2f mm available).',piece_self(k));
end
end

%rebuild the tracks; merge collinear pieces of equal width
track_of=[pieces.track];
for i=1:numel(tracks)
pc=pieces(track_of==i);
new_pts=[tracks(i).pts(:,1) [pc.pts]];
widths=[pc.width];
keep=true(1,size(new_pts,2));
for j=2:size(new_pts,2)-1
d1=new_pts(:,j)-new_pts(:,j-1); d2=new_pts(:,j+1)-new_pts(:,j);
collinear=abs(d1(1)*d2(2)-d1(2)*d2(1))<1e-9*norm(d1)*norm(d2)+1e-12 && d1'*d2>0;
if collinear && widths(j-1)==widths(j)
keep(j)=false;
end
end
tracks(i).pts=new_pts(:,keep);
tracks(i).widths=widths(keep(2:end));
end
end

function [wq,w_self]=available_width(q,qa,lid,wid_pts,wid_loop,wid_arc,fix_pts,fix_half,rect,clr,edge_clr)
%largest width at the query points q (arc positions qa on turn lid)
big=1e9;
%other turns widen by the same rule: width <= distance - clearance
others=wid_loop~=lid;
[~,d_other]=knnsearch(wid_pts(:,others)',q','K',1);
c_other=d_other'-clr;
%the same turn where it comes back close to itself (narrow tips, opening)
same=find(wid_loop==lid);
c_same=big*ones(1,size(q,2));
if ~isempty(same)
d=pdist2(q',wid_pts(:,same)');
far=abs(qa'-wid_arc(same))>3*d+0.5;
d(~far)=big;
c_same=min(d,[],2)'-clr;
end
%fixed copper
[idx,d_fix]=knnsearch(fix_pts',q','K',min(8,size(fix_pts,2)));
c_fix=2*(min(d_fix-fix_half(idx),[],2)'-clr);
%board edge
d_edge=min([q(1,:)-rect(1); rect(2)-q(1,:); q(2,:)-rect(3); rect(4)-q(2,:)],[],1);
c_edge=2*(d_edge-edge_clr);
wq=min([c_other; c_fix; c_edge],[],1);
w_self=c_same;
end

function gap=min_same_net_gap(tracks)
%smallest copper gap between parts of the same net (per layer) that are far
%apart along the path; the KiCad DRC does not check clearance within a net
gap=inf;
layers={tracks.layer}; nets={tracks.net};
keys=strcat(layers,'|',nets);
for key=unique(keys)
sel=find(strcmp(keys,key{1}));
pts=[]; wd=[]; arc=[]; s0=0;
for i=sel
p=tracks(i).pts;
for j=1:size(p,2)-1
len=norm(p(:,j+1)-p(:,j));
t=linspace(0,1,max(2,ceil(len/0.05)+1));
pts=[pts p(:,j)+(p(:,j+1)-p(:,j)).*t]; %#ok<AGROW>
wd=[wd tracks(i).widths(j)*ones(1,numel(t))]; %#ok<AGROW>
arc=[arc s0+len*t]; %#ok<AGROW>
s0=s0+len;
end
end
[idx,dist]=rangesearch(pts',pts',4.5);
for i=1:numel(idx)
j=idx{i}; d=dist{i};
far=abs(arc(j)-arc(i))>3*d+wd(j)+wd(i)+1;
if any(far)
gap=min(gap,min(d(far)-(wd(j(far))+wd(i))/2));
end
end
end
end

function [q,arc]=densify(pts,step)
seg=vecnorm(diff(pts,1,2));
s=[0 cumsum(seg)];
if s(end)<1e-9, q=pts(:,1); arc=0; return; end
arc=unique([0:step:s(end) s(end)]);
keep=[true seg>1e-12];
q=interp1(s(keep),pts(:,keep)',arc)';
end


%% ===================== field / inductance =====================

function b=biot_savart_polyline(v,pts)
mu=1e-7;
a=v(:,1:end-1); c=v(:,2:end);
b=zeros(3,size(pts,2));
for i=1:size(a,2)
dl=c(:,i)-a(:,i);
if norm(dl)<1e-12, continue; end
r1=pts-a(:,i); r2=pts-c(:,i);
cr=cross(repmat(dl,1,size(pts,2)),r1);
f=mu*(dl'*r1./vecnorm(r1)-dl'*r2./vecnorm(r2))./max(sum(cr.^2,1),1e-30);
b=b+cr.*f;
end
end

function l_total=filament_inductance(paths_3d,w,t)
%Neumann double sum over ~1.5 mm segments; the mutual terms are regularized
%with the geometric mean distance of the rectangular track cross section
mu0=4*pi*1e-7;
mid=[]; dl=[];
for i=1:numel(paths_3d)
v=paths_3d{i};
s=[0 cumsum(vecnorm(diff(v,1,2)))];
if s(end)<1e-9, continue; end
num=max(1,ceil(s(end)/1.5e-3));
q=interp1(s,v',linspace(0,s(end),num+1))';
mid=[mid (q(:,1:end-1)+q(:,2:end))/2]; %#ok<AGROW>
dl=[dl diff(q,1,2)]; %#ok<AGROW>
end
gmd=0.2235*(w+t)*1e-3;
seg_len=vecnorm(dl);
self=mu0*seg_len/(2*pi).*(log(2*seg_len/gmd)-1);
self(self<0)=0;
num_seg=size(mid,2);
mutual=0;
block=400;
for i0=1:block:num_seg
i1=min(num_seg,i0+block-1);
dx=mid(1,i0:i1)'-mid(1,:); dy=mid(2,i0:i1)'-mid(2,:); dz=mid(3,i0:i1)'-mid(3,:);
dist=sqrt(dx.^2+dy.^2+dz.^2+gmd^2);
dots=dl(:,i0:i1)'*dl;
term=dots./dist;
idx=sub2ind(size(term),1:(i1-i0+1),i0:i1);
term(idx)=0;
mutual=mutual+sum(term(:));
end
l_total=sum(self)+mu0/(4*pi)*mutual;
end


%% ===================== KiCad writers =====================

function write_kicad_pcb(pcb_file,board)
x0=board.opt.tab_length+10-board.geo.s_left;
y0=max(board.outline(2,:))+10;
kx=@(p) p(1)+x0;
ky=@(p) y0-p(2);
net_id=containers.Map(board.nets(2:end),num2cell(1:numel(board.nets)-1));
lay=@(c) [c '.Cu'];
w=board.w;

fid=fopen(pcb_file,'w');
fprintf(fid,'(kicad_pcb\n\t(version 20240108)\n\t(generator "coilgen_export_kicad_flex_pcb")\n\t(generator_version "1.0")\n');
fprintf(fid,'\t(general\n\t\t(thickness 0.11)\n\t\t(legacy_teardrops no)\n\t)\n\t(paper "A3")\n');
fprintf(fid,'\t(title_block\n\t\t(title "%s")\n\t\t(comment 1 "F.Cu is the outside of the rolled cylinder; fold the J1/J2 tab outwards at the seam")\n\t)\n',board.opt.title);
fprintf(fid,['\t(layers\n\t\t(0 "F.Cu" signal)\n\t\t(31 "B.Cu" signal)\n\t\t(36 "B.SilkS" user "B.Silkscreen")\n' ...
    '\t\t(37 "F.SilkS" user "F.Silkscreen")\n\t\t(38 "B.Mask" user)\n\t\t(39 "F.Mask" user)\n\t\t(44 "Edge.Cuts" user)\n' ...
    '\t\t(46 "B.CrtYd" user "B.Courtyard")\n\t\t(47 "F.CrtYd" user "F.Courtyard")\n\t\t(48 "B.Fab" user)\n\t\t(49 "F.Fab" user)\n\t)\n']);
fprintf(fid,'\t(setup\n\t\t(pad_to_mask_clearance 0)\n\t\t(allow_soldermask_bridges_in_footprints no)\n\t)\n');
for net_ind=1:numel(board.nets)
fprintf(fid,'\t(net %d "%s")\n',net_ind-1,board.nets{net_ind});
end

%net ties
for tie_ind=1:numel(board.ties)
tie=board.ties(tie_ind);
L=lay(tie.layer);
fab=[tie.layer '.Fab'];
d=[tie.pb(1)-tie.pa(1); -(tie.pb(2)-tie.pa(2))];
fprintf(fid,'\t(footprint "CoilGen:NetTie_Turn"\n\t\t(layer "%s")\n\t\t(uuid "%s")\n\t\t(at %.4f %.4f)\n',L,new_uuid(),kx(tie.pa),ky(tie.pa));
fprintf(fid,'\t\t(property "Reference" "NT%d"\n\t\t\t(at 0 0 0)\n\t\t\t(layer "%s")\n\t\t\t(hide yes)\n\t\t\t(uuid "%s")\n\t\t\t(effects\n\t\t\t\t(font\n\t\t\t\t\t(size 0.5 0.5)\n\t\t\t\t\t(thickness 0.08)\n\t\t\t\t)%s\n\t\t\t)\n\t\t)\n',tie_ind,fab,new_uuid(),mirror_tag(tie.layer));
fprintf(fid,'\t\t(property "Value" "NetTie"\n\t\t\t(at 0 0 0)\n\t\t\t(layer "%s")\n\t\t\t(hide yes)\n\t\t\t(uuid "%s")\n\t\t\t(effects\n\t\t\t\t(font\n\t\t\t\t\t(size 0.5 0.5)\n\t\t\t\t\t(thickness 0.08)\n\t\t\t\t)%s\n\t\t\t)\n\t\t)\n',fab,new_uuid(),mirror_tag(tie.layer));
fprintf(fid,'\t\t(attr smd exclude_from_pos_files exclude_from_bom)\n\t\t(net_tie_pad_groups "1,2")\n');
fprintf(fid,'\t\t(fp_line\n\t\t\t(start 0 0)\n\t\t\t(end %.4f %.4f)\n\t\t\t(stroke\n\t\t\t\t(width %.4f)\n\t\t\t\t(type solid)\n\t\t\t)\n\t\t\t(layer "%s")\n\t\t\t(uuid "%s")\n\t\t)\n',d(1),d(2),w,L,new_uuid());
fprintf(fid,'\t\t(pad "1" smd circle\n\t\t\t(at 0 0)\n\t\t\t(size %.4f %.4f)\n\t\t\t(layers "%s")\n\t\t\t(net %d "%s")\n\t\t\t(uuid "%s")\n\t\t)\n',w,w,L,net_id(tie.net_a),tie.net_a,new_uuid());
fprintf(fid,'\t\t(pad "2" smd circle\n\t\t\t(at %.4f %.4f)\n\t\t\t(size %.4f %.4f)\n\t\t\t(layers "%s")\n\t\t\t(net %d "%s")\n\t\t\t(uuid "%s")\n\t\t)\n',d(1),d(2),w,w,L,net_id(tie.net_b),tie.net_b,new_uuid());
fprintf(fid,'\t)\n');
end

%solder pads J1/J2
for pad_ind=1:numel(board.pads)
pad=board.pads(pad_ind);
ps=board.opt.pad_size;
L=pad.layer;
fprintf(fid,'\t(footprint "CoilGen:SolderPad"\n\t\t(layer "%s.Cu")\n\t\t(uuid "%s")\n\t\t(at %.4f %.4f)\n',L,new_uuid(),kx(pad.at),ky(pad.at));
fprintf(fid,'\t\t(property "Reference" "%s"\n\t\t\t(at 0 %.3f 0)\n\t\t\t(layer "%s.Fab")\n\t\t\t(uuid "%s")\n\t\t\t(effects\n\t\t\t\t(font\n\t\t\t\t\t(size 1 1)\n\t\t\t\t\t(thickness 0.15)\n\t\t\t\t)%s\n\t\t\t)\n\t\t)\n',pad.label,-(ps/2+1),L,new_uuid(),mirror_tag(L));
fprintf(fid,'\t\t(property "Value" "SolderPad"\n\t\t\t(at 0 0 0)\n\t\t\t(layer "%s.Fab")\n\t\t\t(hide yes)\n\t\t\t(uuid "%s")\n\t\t\t(effects\n\t\t\t\t(font\n\t\t\t\t\t(size 1 1)\n\t\t\t\t\t(thickness 0.15)\n\t\t\t\t)%s\n\t\t\t)\n\t\t)\n',L,new_uuid(),mirror_tag(L));
fprintf(fid,'\t\t(attr smd)\n');
fprintf(fid,'\t\t(pad "1" smd rect\n\t\t\t(at 0 0)\n\t\t\t(size %.4f %.4f)\n\t\t\t(layers "%s.Cu" "%s.Mask")\n\t\t\t(net %d "%s")\n\t\t\t(uuid "%s")\n\t\t)\n',ps,ps,L,L,net_id(pad.net),pad.net,new_uuid());
fprintf(fid,'\t)\n');
end

%silkscreen alignment marks and labels
for line_ind=1:numel(board.silk_lines)
ln=board.silk_lines{line_ind};
fprintf(fid,'\t(gr_line\n\t\t(start %.4f %.4f)\n\t\t(end %.4f %.4f)\n\t\t(stroke\n\t\t\t(width 0.3)\n\t\t\t(type solid)\n\t\t)\n\t\t(layer "F.SilkS")\n\t\t(uuid "%s")\n\t)\n', ...
    kx(ln(:,1)),ky(ln(:,1)),kx(ln(:,2)),ky(ln(:,2)),new_uuid());
end
for text_ind=1:numel(board.silk_texts)
tx=board.silk_texts(text_ind);
fprintf(fid,'\t(gr_text "%s"\n\t\t(at %.4f %.4f %g)\n\t\t(layer "F.SilkS")\n\t\t(uuid "%s")\n\t\t(effects\n\t\t\t(font\n\t\t\t\t(size %g %g)\n\t\t\t\t(thickness %g)\n\t\t\t)\n\t\t\t(justify left)\n\t\t)\n\t)\n', ...
    tx.text,kx(tx.at),ky(tx.at),tx.angle,new_uuid(),tx.size,tx.size,tx.size*0.15);
end

%outline
fprintf(fid,'\t(gr_poly\n\t\t(pts\n');
for i=1:size(board.outline,2)
fprintf(fid,'\t\t\t(xy %.4f %.4f)\n',kx(board.outline(:,i)),ky(board.outline(:,i)));
end
fprintf(fid,'\t\t)\n\t\t(stroke\n\t\t\t(width 0.05)\n\t\t\t(type solid)\n\t\t)\n\t\t(fill none)\n\t\t(layer "Edge.Cuts")\n\t\t(uuid "%s")\n\t)\n',new_uuid());
fprintf(fid,'\t(gr_text "%s"\n\t\t(at %.4f %.4f 0)\n\t\t(layer "F.Fab")\n\t\t(uuid "%s")\n\t\t(effects\n\t\t\t(font\n\t\t\t\t(size 2 2)\n\t\t\t\t(thickness 0.3)\n\t\t\t)\n\t\t\t(justify left)\n\t\t)\n\t)\n', ...
    board.opt.title,kx([board.geo.s_left; 0]),y0-max(board.outline(2,:))-3,new_uuid());

%tracks
for track_ind=1:numel(board.tracks)
tr=board.tracks(track_ind);
pts=tr.pts;
for i=1:size(pts,2)-1
if norm(pts(:,i+1)-pts(:,i))<1e-6, continue; end
fprintf(fid,'\t(segment\n\t\t(start %.4f %.4f)\n\t\t(end %.4f %.4f)\n\t\t(width %.4f)\n\t\t(layer "%s")\n\t\t(net %d)\n\t\t(uuid "%s")\n\t)\n', ...
    kx(pts(:,i)),ky(pts(:,i)),kx(pts(:,i+1)),ky(pts(:,i+1)),tr.widths(i),lay(tr.layer),net_id(tr.net),new_uuid());
end
end

%vias
for via_ind=1:numel(board.vias)
v=board.vias(via_ind);
fprintf(fid,'\t(via\n\t\t(at %.4f %.4f)\n\t\t(size %.4f)\n\t\t(drill %.4f)\n\t\t(layers "F.Cu" "B.Cu")\n\t\t(net %d)\n\t\t(uuid "%s")\n\t)\n', ...
    kx(v.at),ky(v.at),board.opt.via_diameter,board.opt.via_drill,net_id(v.net),new_uuid());
end
fprintf(fid,')\n');
fclose(fid);
end

function tag=mirror_tag(layer)
if layer=='B', tag=sprintf('\n\t\t\t\t(justify mirror)'); else, tag=''; end
end

function write_kicad_pro(pcb_file,board)
[folder,name]=fileparts(pcb_file);
o=board.opt;
pro.board.design_settings.defaults.board_outline_line_width=0.05;
pro.board.design_settings.rules.min_clearance=o.clearance;
pro.board.design_settings.rules.min_copper_edge_clearance=o.edge_clearance;
pro.board.design_settings.rules.min_track_width=0.1;
pro.board.design_settings.rules.min_via_diameter=o.via_diameter;
pro.board.design_settings.rules.min_via_annular_width=(o.via_diameter-o.via_drill)/2;
pro.board.design_settings.rules.min_through_hole_diameter=o.via_drill;
pro.board.design_settings.rules.min_hole_clearance=0.2;
pro.board.design_settings.rules.min_hole_to_hole=0.25;
pro.board.design_settings.rule_severities.lib_footprint_issues='ignore';
pro.board.design_settings.rule_severities.lib_footprint_mismatch='ignore';
pro.board.design_settings.rule_severities.silk_over_copper='ignore';
pro.board.design_settings.rule_severities.silk_overlap='ignore';
cls=struct('name','Default','clearance',o.clearance,'track_width',board.w,'via_diameter',o.via_diameter, ...
    'via_drill',o.via_drill,'microvia_diameter',0.3,'microvia_drill',0.1,'diff_pair_gap',0.25, ...
    'diff_pair_via_gap',0.25,'diff_pair_width',0.2,'wire_width',6,'bus_width',12,'line_style',0, ...
    'schematic_color','rgba(0, 0, 0, 0.000)','pcb_color','rgba(0, 0, 0, 0.000)','priority',2147483647);
pro.net_settings.classes={cls};
pro.net_settings.meta.version=3;
pro.meta.filename=[name '.kicad_pro'];
pro.meta.version=1;
fid=fopen(fullfile(folder,[name '.kicad_pro']),'w');
fwrite(fid,jsonencode(pro,'PrettyPrint',true));
fclose(fid);
end

function u=new_uuid()
u=char(java.util.UUID.randomUUID());
end
