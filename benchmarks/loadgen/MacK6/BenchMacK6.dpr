program BenchMacK6;

// Helper for the M0 load generator on the Mac. Runs through PAServer (Forge
// run_remote), because the Mac has no other remote shell for the Forge.
//
//   install <version>             downloads k6 <version> from GitHub into
//                                 ~/dxbench/k6/<version>/ (no admin rights, no Homebrew)
//   version <version>             prints the k6 version
//   probe <url>                   one GET with the RTL client, prints status and size
//   run <version> <scriptUrl> <outName> KEY=VALUE ...
//                                 downloads the k6 script, runs k6 with -e KEY=VALUE,
//                                 writes out/<outName>.json and out/<outName>.log
//
// The working directory of a run_remote call is the PAServer scratch folder; the
// "out" folder comes back to the Forge with "collect": "out".

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes, System.IOUtils, System.Zip,
  System.Net.HttpClient, System.Net.URLClient,
  Posix.Stdlib, Posix.Stdio, Posix.SysStat;

function HomeDir: string;
begin
  Result := GetEnvironmentVariable('HOME');
end;

function K6Dir(const AVersion: string): string;
begin
  Result := TPath.Combine(TPath.Combine(TPath.Combine(HomeDir, 'dxbench'), 'k6'), AVersion);
end;

function K6Exe(const AVersion: string): string;
begin
  Result := TPath.Combine(K6Dir(AVersion), 'k6');
end;

function ShellQuote(const AText: string): string;
begin
  // #39 is the single quote; written as a char code to keep the source simple.
  Result := #39 + StringReplace(AText, #39, #39'"'#39'"'#39, [rfReplaceAll]) + #39;
end;

// Runs a shell command and returns its combined output.
function RunCapture(const ACommand: string; out AExitCode: Integer): string;
var
  LPipe: PIOFile;
  LBuffer: array[0..4095] of AnsiChar;
  LBytes: TBytes;
  LStream: TBytesStream;
  LRead: Integer;
  LCmd: TBytes;
begin
  LStream := TBytesStream.Create;
  try
    LCmd := TEncoding.UTF8.GetBytes(ACommand + ' 2>&1' + #0);
    LPipe := popen(MarshaledAString(@LCmd[0]), 'r');
    if LPipe = nil then
      raise Exception.Create('popen failed');
    repeat
      LRead := fread(@LBuffer[0], 1, SizeOf(LBuffer), LPipe);
      if LRead > 0 then
        LStream.WriteBuffer(LBuffer[0], LRead);
    until LRead <= 0;
    AExitCode := pclose(LPipe);
    if AExitCode > 255 then
      AExitCode := AExitCode shr 8;
    LBytes := Copy(LStream.Bytes, 0, LStream.Size);
    Result := TEncoding.UTF8.GetString(LBytes);
  finally
    LStream.Free;
  end;
end;

function IsAppleSilicon: Boolean;
var
  LCode: Integer;
begin
  // uname -m reports x86_64 under Rosetta; the sysctl tells the real CPU.
  Result := Trim(RunCapture('/usr/sbin/sysctl -n hw.optional.arm64', LCode)) = '1';
end;

procedure Download(const AUrl, AFile: string);
var
  LClient: THTTPClient;
  LFile: TFileStream;
  LResponse: IHTTPResponse;
begin
  LClient := THTTPClient.Create;
  try
    LClient.HandleRedirects := True;
    LFile := TFileStream.Create(AFile, fmCreate);
    try
      LResponse := LClient.Get(AUrl, LFile);
    finally
      LFile.Free;
    end;
    if LResponse.StatusCode <> 200 then
      raise Exception.CreateFmt('download %s: HTTP %d', [AUrl, LResponse.StatusCode]);
  finally
    LClient.Free;
  end;
end;

procedure DoVersion(const AVersion: string);
var
  LCode: Integer;
begin
  Writeln(Trim(RunCapture(ShellQuote(K6Exe(AVersion)) + ' version', LCode)));
  ExitCode := LCode;
end;

procedure DoInstall(const AVersion: string);
var
  LArch, LName, LUrl, LZip, LDir, LInner: string;
  LZipFile: TZipFile;
  LCode: Integer;
begin
  if TFile.Exists(K6Exe(AVersion)) then
  begin
    Writeln('already installed: ', K6Exe(AVersion));
    DoVersion(AVersion);
    Exit;
  end;
  if IsAppleSilicon then
    LArch := 'arm64'
  else
    LArch := 'amd64';
  LName := Format('k6-%s-macos-%s', [AVersion, LArch]);
  LUrl := Format('https://github.com/grafana/k6/releases/download/%s/%s.zip', [AVersion, LName]);
  LDir := K6Dir(AVersion);
  TDirectory.CreateDirectory(LDir);
  LZip := TPath.Combine(LDir, LName + '.zip');
  Writeln('download ', LUrl);
  Download(LUrl, LZip);
  LZipFile := TZipFile.Create;
  try
    LZipFile.Open(LZip, zmRead);
    LZipFile.ExtractAll(LDir);
  finally
    LZipFile.Free;
  end;
  LInner := TPath.Combine(TPath.Combine(LDir, LName), 'k6');
  if TFile.Exists(LInner) then
    TFile.Move(LInner, K6Exe(AVersion));
  RunCapture('/bin/chmod 755 ' + ShellQuote(K6Exe(AVersion)), LCode);
  // Downloaded through the RTL client there is no quarantine flag; remove it anyway.
  RunCapture('/usr/bin/xattr -d com.apple.quarantine ' + ShellQuote(K6Exe(AVersion)), LCode);
  TFile.Delete(LZip);
  Writeln('installed: ', K6Exe(AVersion), ' (', LArch, ')');
  DoVersion(AVersion);
end;

procedure DoProbe(const AUrl: string);
var
  LClient: THTTPClient;
  LResponse: IHTTPResponse;
begin
  LClient := THTTPClient.Create;
  try
    LClient.ConnectionTimeout := 5000;
    LClient.ResponseTimeout := 5000;
    try
      LResponse := LClient.Get(AUrl);
      Writeln(Format('probe %s: HTTP %d, %d bytes', [AUrl, LResponse.StatusCode, LResponse.ContentLength]));
    except
      on E: Exception do
      begin
        Writeln(Format('probe %s: %s: %s', [AUrl, E.ClassName, E.Message]));
        ExitCode := 2;
      end;
    end;
  finally
    LClient.Free;
  end;
end;

procedure DoRun(const AVersion, AScriptUrl, AOutName: string; AFirstEnv: Integer);
var
  LOutDir, LScript, LCmd, LOutput: string;
  I, LCode: Integer;
begin
  LOutDir := TPath.Combine(GetCurrentDir, 'out');
  TDirectory.CreateDirectory(LOutDir);
  LScript := TPath.Combine(GetCurrentDir, 'run.js');
  if not TFile.Exists(LScript) then
    Download(AScriptUrl, LScript);
  LCmd := 'GODEBUG=http2client=0 ' + ShellQuote(K6Exe(AVersion)) + ' run --quiet --no-color';
  for I := AFirstEnv to ParamCount do
    LCmd := LCmd + ' -e ' + ShellQuote(ParamStr(I));
  LCmd := LCmd + ' -e ' + ShellQuote('OUT=' + TPath.Combine(LOutDir, AOutName + '.json'));
  LCmd := LCmd + ' ' + ShellQuote(LScript);
  LOutput := RunCapture(LCmd, LCode);
  TFile.WriteAllText(TPath.Combine(LOutDir, AOutName + '.log'), LCmd + sLineBreak + LOutput);
  Writeln(AOutName, ': exit ', LCode);
  ExitCode := LCode;
end;

var
  LMode: string;
begin
  try
    if ParamCount < 1 then
      raise Exception.Create('usage: install|version|probe|run ...');
    LMode := LowerCase(ParamStr(1));
    if LMode = 'install' then
      DoInstall(ParamStr(2))
    else if LMode = 'version' then
      DoVersion(ParamStr(2))
    else if LMode = 'probe' then
    begin
      for var I := 2 to ParamCount do
        DoProbe(ParamStr(I));
    end
    else if LMode = 'run' then
      DoRun(ParamStr(2), ParamStr(3), ParamStr(4), 5)
    else
      raise Exception.CreateFmt('unknown mode: %s', [LMode]);
  except
    on E: Exception do
    begin
      Writeln(ErrOutput, E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
