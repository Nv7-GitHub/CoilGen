function cli=find_kicad_cli(cli_hint)
%Path of KiCad's command line tool (kicad-cli); '' if it is not found.
%cli_hint: optional path to try first.

if nargin<1, cli_hint=''; end
candidates={cli_hint,'kicad-cli','/opt/homebrew/bin/kicad-cli','/usr/local/bin/kicad-cli', ...
    '/Applications/KiCad/KiCad.app/Contents/MacOS/kicad-cli','C:\Program Files\KiCad\bin\kicad-cli.exe'};
cli='';
for c=candidates
if isempty(c{1}), continue; end
[status,~]=system(['"' c{1} '" version']);
if status==0, cli=c{1}; return; end
end
end
