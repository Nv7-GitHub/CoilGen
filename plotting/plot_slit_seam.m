function plot_slit_seam(coil_layouts,single_ind_to_plot,ax)
%Mark the slit of a 'create slit cylinder mesh' coil in a 3D plot: the
%seam where the edges of a rolled flex PCB meet. Draws the two slit edges
%and the strip between them in red, slightly outside the coil surface.

if nargin<3, ax=gca; end
input_data=coil_layouts(single_ind_to_plot).out.input_data;
if ~strcmp(input_data.coil_mesh_file,'create slit cylinder mesh')
return;
end
p=input_data.slit_cylinder_mesh_parameter_list;
cylinder_height=p(1); cylinder_radius=p(2);
rot_mat=calc_rot_mat([p(5) p(6) p(7)]',p(8));
half_angle=p(10)/(2*cylinder_radius);
seam_angles=p(9)+[-half_angle half_angle];
r=cylinder_radius*1.02;
z_pos=linspace(-cylinder_height/2,cylinder_height/2,2);

hold(ax,'on');
edge_pts=cell(1,2);
for edge_ind=1:2
q=rot_mat*[r*cos(seam_angles(edge_ind))*[1 1]; r*sin(seam_angles(edge_ind))*[1 1]; z_pos];
edge_pts{edge_ind}=q;
plot3(ax,q(1,:),q(2,:),q(3,:),'r-','LineWidth',2.5);
end
strip=[edge_pts{1} fliplr(edge_pts{2})];
patch(ax,strip(1,:),strip(2,:),strip(3,:),'r','FaceAlpha',0.35,'EdgeColor','none');
label_pt=rot_mat*[r*1.15*cos(p(9)); r*1.15*sin(p(9)); -cylinder_height/2];
text(ax,label_pt(1),label_pt(2),label_pt(3),'seam (PCB split)','Color','r','FontWeight','bold','HorizontalAlignment','right');
end


function rot_mat_out=calc_rot_mat(rot_vec,rot_angle)
%rotation matrix around the axis rot_vec, as used for the cylinder meshes
rot_vec=rot_vec./norm(rot_vec);
u_x=rot_vec(1); u_y=rot_vec(2); u_z=rot_vec(3);
c=cos(rot_angle); s=sin(rot_angle); t=1-c;
rot_mat_out=[c+u_x*u_x*t u_x*u_y*t-u_z*s u_x*u_z*t+u_y*s; ...
    u_y*u_x*t+u_z*s c+u_y*u_y*t u_y*u_z*t-u_x*s; ...
    u_z*u_x*t-u_y*s u_z*u_y*t+u_x*s c+u_z*u_z*t];
end
