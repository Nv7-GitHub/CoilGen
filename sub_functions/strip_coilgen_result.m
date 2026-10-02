function out=strip_coilgen_result(out)
%Keep only the fields of a CoilGen result that the functions in 'plotting'
%use, so that a result can be saved compactly (the sensitivity, resistance
%and basis matrices of the optimization are dropped).

keep_top={'coil_parts','num_levels','potential_step','primary_surface','target_field','is_supressed_point', ...
    'field_by_layout','field_by_unconnected_loops','field_layout_per1Amp','field_loops_per1Amp', ...
    'needed_current_layout','b_field_opt_sf','b_field_opt_sf_1A','target_field_1A','error_vals', ...
    'input_data','layout_gradient','combined_mesh'};
keep_part={'coil_mesh','stream_function','contour_lines','contour_step','potential_level_list', ...
    'wire_path','groups','current_density','field_by_loops','field_by_layout','opt_current_layout'};

out=rmfield(out,setdiff(fieldnames(out),keep_top));
parts=out.coil_parts;
parts=rmfield(parts,setdiff(fieldnames(parts),keep_part));
out.coil_parts=parts;
if isfield(out,'combined_mesh')
out.combined_mesh=rmfield(out.combined_mesh,intersect(fieldnames(out.combined_mesh),{'basis_elements','sensitivity_matrix','resistance_matrix','current_density_mat','inductance_matrix'}));
end
end
