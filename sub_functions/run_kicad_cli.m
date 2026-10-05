function [status,output]=run_kicad_cli(cli,args,timeout_s)
%Run kicad-cli (or another program, e.g. Python) with a hard time limit.
%cli: path of kicad-cli or the program, args: cell array of arguments, timeout_s: limit in
%seconds (default 300). status is the exit code, -1 on a timeout.
%
%The process is started with Java's ProcessBuilder instead of system():
%MATLAB's system() can hang on macOS after longer child processes, and the
%process is killed if it runs into the time limit. Output (stdout and
%stderr) goes to a temporary file, stdin is empty.

if nargin<3, timeout_s=300; end
if ischar(args), args={args}; end
log_file=[tempname '.log'];
command=java.util.ArrayList();
command.add(java.lang.String(cli));
for i=1:numel(args)
command.add(java.lang.String(args{i}));
end
builder=java.lang.ProcessBuilder(command);
builder.redirectErrorStream(true);
builder.redirectOutput(java.io.File(log_file));
if ispc, null_file='NUL'; else, null_file='/dev/null'; end
builder.redirectInput(javaMethod('from','java.lang.ProcessBuilder$Redirect',java.io.File(null_file)));
try
process=builder.start();
catch err
status=-2; output=char(err.message);
return;
end
finished=process.waitFor(round(timeout_s),java.util.concurrent.TimeUnit.SECONDS);
if finished
status=process.exitValue();
else
process.destroyForcibly();
status=-1;
end
output='';
if isfile(log_file)
output=fileread(log_file);
delete(log_file);
end
if ~finished
output=sprintf('%s timed out after %d s.\n%s',cli,round(timeout_s),output);
end
end
