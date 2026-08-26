# agy-windows-test.ps1
# Antigravity CLI'nin Windows'ta headless (non-TTY) calisip calismadigini olcer.
# Kullanim:  powershell -ExecutionPolicy Bypass -File .\agy-windows-test.ps1
# Sonuc dosyasi: .\AGY-WINDOWS-SONUC.txt  -> bu dosyayi geri gonder.

$ErrorActionPreference = "Continue"
$out = Join-Path $PSScriptRoot "AGY-WINDOWS-SONUC.txt"
$work = Join-Path $PSScriptRoot "agy-test-ws"
if (Test-Path $work) { Remove-Item $work -Recurse -Force }
New-Item -ItemType Directory -Path $work | Out-Null
"kirmizi=5" | Set-Content -Path (Join-Path $work "veri.txt") -Encoding utf8

$log = New-Object System.Collections.Generic.List[string]
function Say($m) { Write-Host $m; $log.Add($m) }

Say "=== AGY WINDOWS HEADLESS TESTI  $(Get-Date -Format 'yyyy-MM-dd HH:mm') ==="
Say "OS: $([System.Environment]::OSVersion.VersionString)"
Say "PowerShell: $($PSVersionTable.PSVersion)"
Say ""

# --- agy var mi ---
$agy = Get-Command agy -ErrorAction SilentlyContinue
if (-not $agy) {
  Say "SONUC: agy PATH'te bulunamadi."
  Say "Kurulum:  irm https://antigravity.google/cli/install.ps1 | iex"
  Say "Kurduktan sonra bir kez 'agy' yazip Google girisini tamamlayin, sonra bu betigi tekrar calistirin."
  $log -join "`r`n" | Set-Content $out -Encoding utf8
  exit 1
}
Say "agy yolu: $($agy.Source)"
Say "agy surumu: $(& agy --version 2>&1 | Select-Object -First 1)"
Say ""

# --- test kosucu: non-TTY'de calistirir, sureyi ve cikti boyutunu olcer ---
function Test-Case {
  param([string]$Name, [string[]]$AgyArgs, [int]$TimeoutSec = 150)

  $so = Join-Path $work "$Name.out"
  $se = Join-Path $work "$Name.err"
  $sw = [System.Diagnostics.Stopwatch]::StartNew()

  # Start-Process + dosyaya yonlendirme = non-TTY. Testin butun mesele bu.
  $p = Start-Process -FilePath $agy.Source -ArgumentList $AgyArgs `
       -RedirectStandardOutput $so -RedirectStandardError $se `
       -NoNewWindow -PassThru

  $bitti = $p.WaitForExit($TimeoutSec * 1000)
  if (-not $bitti) {
    try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch {}
    # cocuk surecleri de topla
    try { & taskkill /PID $p.Id /T /F 2>&1 | Out-Null } catch {}
    $sw.Stop()
    Say ("[{0}] ASILDI - {1}s sonra oldurudu  <<< BASARISIZ" -f $Name, $TimeoutSec)
    return @{ Name=$Name; Ok=$false; Why="asildi (timeout)" }
  }
  $sw.Stop()

  $ob = if (Test-Path $so) { (Get-Item $so).Length } else { 0 }
  $eb = if (Test-Path $se) { (Get-Item $se).Length } else { 0 }
  $sure = [math]::Round($sw.Elapsed.TotalSeconds, 1)
  Say ("[{0}] exit={1} sure={2}s stdout={3}B stderr={4}B" -f $Name, $p.ExitCode, $sure, $ob, $eb)

  if ($ob -eq 0) {
    Say "    >>> STDOUT BOS - Windows non-TTY hatasi (issue #76) bu makinede YASIYOR"
    return @{ Name=$Name; Ok=$false; Why="stdout bos" }
  }
  return @{ Name=$Name; Ok=$true; Why="ok"; OutFile=$so; ErrFile=$se }
}

$sonuclar = @()

Say "--- 1) agy models (auth + stdout) ---"
$sonuclar += Test-Case -Name "t1_models" -AgyArgs @("models")

Say ""
Say "--- 2) agy -p duz metin ---"
$sonuclar += Test-Case -Name "t2_print" -AgyArgs @("-p","Reply with exactly the word PONG and nothing else.")

Say ""
Say "--- 3) agy -p --output-format json ---"
$r3 = Test-Case -Name "t3_json" -AgyArgs @("-p","Reply with exactly the word PONG and nothing else.","--output-format","json")
$sonuclar += $r3
if ($r3.Ok) {
  $raw = Get-Content $r3.OutFile -Raw
  Say "    ham: $($raw.Substring(0, [Math]::Min(220, $raw.Length)))"
  try {
    $j = $raw | ConvertFrom-Json
    Say "    ayristirildi: status=$($j.status) response='$($j.response)' tokens=$($j.usage.total_tokens)"
    if (-not $j.response) { Say "    >>> response BOS - izin engeli olabilir" }
  } catch { Say "    >>> JSON ayristirilamadi: $_" }
}

Say ""
Say "--- 4) read lane: --add-dir ile dosya okuma ---"
$r4 = Test-Case -Name "t4_read" -AgyArgs @(
  "-p","Read the file veri.txt in the workspace and reply with only its exact contents.",
  "--add-dir",$work,"--mode","plan","--output-format","json","--print-timeout","10m")
$sonuclar += $r4
if ($r4.Ok) {
  try {
    $j = (Get-Content $r4.OutFile -Raw | ConvertFrom-Json)
    Say "    response='$($j.response)'"
    if ($j.response -match "kirmizi") { Say "    >>> READ LANE CALISIYOR" }
    else { Say "    >>> READ LANE BASARISIZ (response bos/yanlis)"; Say "    stderr: $(Get-Content $r4.ErrFile -Raw)" }
  } catch { Say "    JSON hatasi: $_" }
}

Say ""
Say "--- 5) write lane: --mode accept-edits ile dosya yazma ---"
$r5 = Test-Case -Name "t5_write" -AgyArgs @(
  "-p","TOOL CONSTRAINT: Use only the built-in file write tool. Do NOT run shell commands. Create a file named hello.txt in the workspace containing exactly HELLO. Then reply DONE.",
  "--add-dir",$work,"--mode","accept-edits","--output-format","json","--print-timeout","10m")
$sonuclar += $r5
$hello = Join-Path $work "hello.txt"
if (Test-Path $hello) { Say "    >>> WRITE LANE CALISIYOR - hello.txt icerik: '$((Get-Content $hello -Raw).Trim())'" }
else {
  Say "    >>> WRITE LANE BASARISIZ - hello.txt olusmadi"
  if ($r5.ErrFile -and (Test-Path $r5.ErrFile)) { Say "    stderr: $(Get-Content $r5.ErrFile -Raw)" }
}

Say ""
Say "--- 6) paralellik: 3 es zamanli lane ---"
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$jobs = 1..3 | ForEach-Object {
  $n = $_
  Start-Job -ScriptBlock {
    param($exe,$n,$dir)
    & $exe -p "Reply with only the result of $n multiplied by 7." --output-format json 2>&1
  } -ArgumentList $agy.Source, $n, $work
}
$bittiMi = Wait-Job -Job $jobs -Timeout 180
$sw.Stop()
$ok = 0
foreach ($j in $jobs) {
  $res = (Receive-Job -Job $j -ErrorAction SilentlyContinue) -join ""
  if ($res -and $res.Trim().Length -gt 0) { $ok++ }
}
Remove-Job -Job $jobs -Force -ErrorAction SilentlyContinue
Say ("    3 lane, {0}/3 cikti verdi, toplam {1}s" -f $ok, [math]::Round($sw.Elapsed.TotalSeconds,1))
if ($ok -lt 3) { Say "    >>> PARALELLIK SORUNLU" } else { Say "    >>> PARALELLIK CALISIYOR" }

Say ""
Say "=================== OZET ==================="
$gecen = ($sonuclar | Where-Object { $_.Ok }).Count
Say "$gecen / $($sonuclar.Count) temel test gecti"
foreach ($s in $sonuclar) { Say ("  {0,-12} {1}" -f $s.Name, $(if ($s.Ok) {"GECTI"} else {"KALDI - $($s.Why)"})) }
Say ""
if ($gecen -eq $sonuclar.Count) {
  Say "KARAR: agy bu Windows makinesinde headless calisiyor. gemini-fleet uyarlanabilir."
} else {
  Say "KARAR: headless yolu bu makinede bozuk. gemini-fleet Windows'ta su haliyle KURULMAMALI."
}

$log -join "`r`n" | Set-Content $out -Encoding utf8
Say ""
Say "Sonuc dosyasi: $out"
Say "Bu dosyayi geri gonderin."
