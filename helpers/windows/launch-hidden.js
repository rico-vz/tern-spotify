// Tern starts plugin processes without CREATE_NO_WINDOW, which on Windows 11 opens a
// Windows Terminal tab. Running under wscript.exe with window style 0 keeps the console hidden.
var shell = new ActiveXObject("WScript.Shell");
var parts = [];
for (var i = 0; i < WScript.Arguments.length; i++) {
	var arg = WScript.Arguments(i);
	parts.push(arg === "" || /[\s"]/.test(arg) ? '"' + arg.replace(/"/g, '\\"') + '"' : arg);
}
WScript.Quit(shell.Run(parts.join(" "), 0, true));
