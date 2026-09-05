param($Repo, $HostN, $Cmd)
$sshPath = "C:\Windows\System32\OpenSSH\ssh.exe"
$sshCmd = "git-$Cmd '$Repo'"
$proc = New-Object System.Diagnostics.Process
$proc.StartInfo.FileName = $sshPath
$proc.StartInfo.Arguments = "-T -i C:\Users\jianz\.ssh\id_ed25519 -o StrictHostKeyChecking=accept-new -o ConnectTimeout=40 git@$HostN $sshCmd"
$proc.StartInfo.UseShellExecute = $false
$proc.StartInfo.RedirectStandardInput = $true
$proc.StartInfo.RedirectStandardOutput = $true
$proc.StartInfo.RedirectStandardError = $true
$proc.Start() | Out-Null
$bin = New-Object System.IO.BinaryReader($proc.StandardOutput.BaseStream)
$stdin = $proc.StandardInput

function ReadPkt($bin){
  $lb = $bin.ReadBytes(4)
  if ($lb.Length -lt 4) { return $null }
  $hex = -join ($lb | ForEach-Object { $_.ToString("x2") })
  $len = [Convert]::ToInt32($hex,16)
  return $bin.ReadBytes($len)
}
function WritePkt($stdin,$str){
  $b = [System.Text.Encoding]::UTF8.GetBytes($str)
  $hb = [System.Text.Encoding]::UTF8.GetBytes($b.Length.ToString("x4"))
  $stdin.Write($hb); $stdin.Write($b); $stdin.Flush()
}

WritePkt $stdin "command=version`nprotocol-version=2`n"
while ($true) {
  $p = ReadPkt $bin
  if (-not $p) { Write-Host "CONN_CLOSED"; $proc.Kill(); return }
  if ($p.Length -eq 0) { Write-Host "handshake_done"; break }
}
WritePkt $stdin "command=list`nhost=$HostN`n"
$mainSha = $null; $cnt = 0
while ($cnt -lt 200) {
  $p = ReadPkt $bin
  if (-not $p) { break }
  if ($p.Length -eq 0) { Write-Host "list_done"; break }
  $s = [System.Text.Encoding]::UTF8.GetString($p)
  if ($s -match 'refs/heads/(main|master)\s+') {
    $mainSha = $Matches[0].Trim()
    Write-Host "MAIN_SHA=$mainSha"
  }
  $cnt++
}
if (-not $mainSha) { Write-Host "NO_MAIN_SHA_FOUND" }
$proc.StandardInput.Close(); $proc.WaitForExit()
