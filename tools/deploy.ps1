<#
.SYNOPSIS
    Розгортання бази даних курсової (Варіант 6 "Поліклініка") одним запуском.

.DESCRIPTION
    Послідовно виконує SQL-скрипти репозиторію на локальному SQL Server:
      Database\CREATE_DATABASE.sql -> CREATE_TABLES -> CREATE_CONSTRAINTS -> CREATE_TRIGGERS -> CREATE_PROCEDURES
      DataGeneration\GENERATE_DATA.sql -> VERIFY_DATA.sql (смоук-тест) -> BACKUP_DATABASE.sql
      (опційно -IncludeDW) Database\CREATE_DW.sql -> RUN_ETL_PIPELINE.sql -> VERIFY_DW.sql
    Скрипти розбиваються на пакети за роздільником GO (як у SSMS/sqlcmd).
    Повний журнал (PRINT-повідомлення, результати SELECT, помилки з номером рядка) пишеться в
    logs\deploy_<дата>.log та logs\last_deploy.log.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\tools\deploy.ps1
    powershell -ExecutionPolicy Bypass -File .\tools\deploy.ps1 -SqlUser sa -SqlPassword <пароль> -IncludeDW
    powershell -ExecutionPolicy Bypass -File .\tools\deploy.ps1 -Only VERIFY_DATA.sql
#>
[CmdletBinding()]
param(
    [string]$Server = 'localhost',
    [string]$SqlUser,
    [string]$SqlPassword,
    [switch]$IncludeDW,
    [switch]$SkipBackup,
    [string[]]$Only
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$repo   = Split-Path -Parent $PSScriptRoot
$logDir = Join-Path $repo 'logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$stamp  = Get-Date -Format 'yyyyMMdd_HHmmss'
$log    = Join-Path $logDir "deploy_$stamp.log"
$utf8   = New-Object System.Text.UTF8Encoding($true)

function Write-Log([string]$text, [string]$color = 'Gray') {
    Write-Host $text -ForegroundColor $color
    [System.IO.File]::AppendAllText($log, $text + "`r`n", $utf8)
}

$steps = @(
    'Database\CREATE_DATABASE.sql',
    'Database\CREATE_TABLES.sql',
    'Database\CREATE_CONSTRAINTS.sql',
    'Database\CREATE_TRIGGERS.sql',
    'Database\CREATE_PROCEDURES.sql',
    'DataGeneration\GENERATE_DATA.sql',
    'DataGeneration\VERIFY_DATA.sql'
)
if (-not $SkipBackup) { $steps += 'DataGeneration\BACKUP_DATABASE.sql' }
if ($IncludeDW)       { $steps += @('Database\CREATE_DW.sql', 'Database\RUN_ETL_PIPELINE.sql', 'Database\VERIFY_DW.sql') }
if ($Only)            { $steps = $steps | Where-Object { $Only -contains (Split-Path $_ -Leaf) } }
if ($Only -and -not $steps) {
    # дозволяємо запуск будь-якого скрипта репозиторію за назвою
    $steps = Get-ChildItem -Path $repo -Recurse -Filter '*.sql' | Where-Object { $Only -contains $_.Name } |
             ForEach-Object { $_.FullName.Substring($repo.Length + 1) }
}

if ($SqlUser) {
    $cs = "Server=$Server;Database=master;User ID=$SqlUser;Password=$SqlPassword;TrustServerCertificate=True;Application Name=Kursova-deploy;Connect Timeout=15"
    $authInfo = "SQL Server Authentication ($SqlUser)"
} else {
    $cs = "Server=$Server;Database=master;Integrated Security=SSPI;TrustServerCertificate=True;Application Name=Kursova-deploy;Connect Timeout=15"
    $authInfo = 'Windows Authentication'
}

function Format-DataTable([System.Data.DataTable]$dt, [int]$maxRows = 300) {
    if ($dt.Columns.Count -eq 0) { return '' }
    $cols = @($dt.Columns | ForEach-Object { $_.ColumnName })
    if ($dt.Rows.Count -eq 0) { return "(порожній результат: " + ($cols -join ', ') + ")" }
    $rows = @($dt.Rows | Select-Object -First $maxRows | ForEach-Object {
        $r = $_; $o = [ordered]@{}
        foreach ($c in $cols) { $v = $r[$c]; $o[$c] = if ($v -is [DBNull]) { 'NULL' } else { $v } }
        [pscustomobject]$o
    })
    $txt = ($rows | Format-Table -AutoSize | Out-String -Width 4096).TrimEnd()
    if ($dt.Rows.Count -gt $maxRows) { $txt += "`r`n... (показано $maxRows з $($dt.Rows.Count) рядків)" }
    return $txt
}

Write-Log "=== Розгортання БД курсової | $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | Сервер: $Server | $authInfo ===" 'Green'
$summary = @()
$failed  = $false

foreach ($step in $steps) {
    $path = Join-Path $repo $step
    if (-not (Test-Path $path)) { Write-Log "!! Файл не знайдено: $step" 'Red'; $failed = $true; break }

    $sql     = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
    $batches = [regex]::Split($sql, '(?im)^[ \t]*GO[ \t]*(?:--[^\r\n]*)?\r?$')
    Write-Log ''
    Write-Log ">>> $step  ($($batches.Count) пакетів)" 'Cyan'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    $conn = New-Object System.Data.SqlClient.SqlConnection $cs
    $conn.add_InfoMessage({ param($s, $e) foreach ($m in $e.Errors) { Write-Log ("   " + $m.Message) } })
    $stepOk = $true
    try {
        $conn.Open()
        $init = $conn.CreateCommand()
        $init.CommandText = 'SET ARITHABORT ON; SET NUMERIC_ROUNDABORT OFF; SET CONCAT_NULL_YIELDS_NULL ON; SET ANSI_PADDING ON; SET ANSI_WARNINGS ON; SET ANSI_NULLS ON; SET QUOTED_IDENTIFIER ON;'
        [void]$init.ExecuteNonQuery()

        $lineOffset = 1
        for ($i = 0; $i -lt $batches.Count; $i++) {
            $b = $batches[$i]
            $batchStartLine = $lineOffset
            $lineOffset += ([regex]::Matches($b, "`n")).Count
            if ([string]::IsNullOrWhiteSpace($b)) { continue }
            $cmd = $conn.CreateCommand()
            $cmd.CommandText = $b
            $cmd.CommandTimeout = 0
            try {
                $reader = $cmd.ExecuteReader()
                try {
                    do {
                        if ($reader.FieldCount -gt 0) {
                            $dt = New-Object System.Data.DataTable
                            for ($c = 0; $c -lt $reader.FieldCount; $c++) {
                                $name = $reader.GetName($c)
                                if ([string]::IsNullOrEmpty($name)) { $name = "Column$($c + 1)" }
                                while ($dt.Columns.Contains($name)) { $name = "$name`_$c" }
                                [void]$dt.Columns.Add($name, [object])
                            }
                            while ($reader.Read()) {
                                $vals = New-Object 'object[]' $reader.FieldCount
                                [void]$reader.GetValues($vals)
                                [void]$dt.Rows.Add($vals)
                            }
                            Write-Log (Format-DataTable $dt) 'White'
                        }
                    } while ($reader.NextResult())
                } finally {
                    $reader.Close()
                }
            } catch [System.Data.SqlClient.SqlException] {
                foreach ($er in $_.Exception.Errors) {
                    if ($er.Class -gt 10) {
                        $fileLine = $batchStartLine + [Math]::Max($er.LineNumber, 1) - 1
                        Write-Log ("!! ПОМИЛКА Msg {0}, Level {1}, пакет #{2}, рядок файлу ~{3}: {4}" -f $er.Number, $er.Class, ($i + 1), $fileLine, $er.Message) 'Red'
                    } else {
                        Write-Log ("   " + $er.Message)
                    }
                }
                $stepOk = $false
                break
            }
        }
    } catch {
        Write-Log ("!! ПОМИЛКА підключення/виконання: " + $_.Exception.Message) 'Red'
        $stepOk = $false
    } finally {
        $conn.Close(); $conn.Dispose()
    }
    $sw.Stop()
    $status = if ($stepOk) { 'OK' } else { 'FAILED' }
    $summary += [pscustomobject]@{ Script = $step; Status = $status; Seconds = [Math]::Round($sw.Elapsed.TotalSeconds, 1) }
    Write-Log ("<<< $step : $status за {0:N1} с" -f $sw.Elapsed.TotalSeconds) $(if ($stepOk) { 'Green' } else { 'Red' })
    if (-not $stepOk) { $failed = $true; break }
}

Write-Log ''
Write-Log '=== ПІДСУМОК ===' 'Green'
Write-Log (($summary | Format-Table -AutoSize | Out-String -Width 400).TrimEnd()) 'White'
$final = if ($failed) { 'РЕЗУЛЬТАТ: Є ПОМИЛКИ (див. вище)' } else { 'РЕЗУЛЬТАТ: УСПІШНО' }
Write-Log $final $(if ($failed) { 'Red' } else { 'Green' })
Copy-Item -Force $log (Join-Path $logDir 'last_deploy.log')
Write-Host "Журнал: $log"
if ($failed) { exit 1 } else { exit 0 }
