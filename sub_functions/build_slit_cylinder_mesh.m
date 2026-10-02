function cylinder_mesh=build_slit_cylinder_mesh(cylinder_height,cylinder_radius,num_circular_divisions,num_longitudinal_divisions,rotation_vector_x,rotation_vector_y,rotation_vector_z,rotation_angle,slit_center_angle,slit_width)
%create a cylindrical regular mesh with an axial slit (open along one line),
%e.g. for a flex PCB that is rolled into a cylinder: no current can cross
%the slit, so the coil layout never crosses the seam of the PCB.
%The slit is centered at the angle slit_center_angle [radian] measured as
%atan2(y,x) in the unrotated frame (cylinder axis along z) and has the arc
%width slit_width [m]. The rotation is applied as in build_cylinder_mesh.

slit_angle=slit_width/cylinder_radius;
phi_positions=linspace(slit_center_angle+slit_angle/2,slit_center_angle+2*pi-slit_angle/2,num_circular_divisions+1);
x_positions=cos(phi_positions).*cylinder_radius;
y_positions=sin(phi_positions).*cylinder_radius;
z_positions=linspace((-1)*cylinder_height/2,cylinder_height/2,num_longitudinal_divisions+1);

num_ring=numel(phi_positions);
vertices_x=repmat(x_positions,[1 numel(z_positions)]);
vertices_y=repmat(y_positions,[1 numel(z_positions)]);
vertices_z=repelem(z_positions,num_ring);
vertices=[vertices_x; vertices_y; vertices_z];

%two triangles per quad, no wrap-around between the first and last column
[col_ind,row_ind]=meshgrid(1:num_ring-1,1:numel(z_positions)-1);
col_ind=col_ind(:)'; row_ind=row_ind(:)';
v1=(row_ind-1)*num_ring+col_ind;
v2=v1+1;
v3=v1+num_ring;
v4=v2+num_ring;
faces_1=[v1; v2; v4];
faces_2=[v1; v4; v3];

cylinder_mesh.faces=[faces_1 faces_2]';
cylinder_mesh.vertices=vertices';

%rotate the cylinder in the desired orientation
rot_mat=calc_3d_rotation_matrix_by_vector([rotation_vector_x rotation_vector_y rotation_vector_z]',rotation_angle);
cylinder_mesh.vertices=(rot_mat*cylinder_mesh.vertices')';

end
