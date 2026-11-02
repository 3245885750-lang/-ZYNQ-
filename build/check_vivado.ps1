# ============================================================
# check_vivado.ps1 —— Vivado 综合"体检"脚本（只读，不改任何东西）
#
# 用途：综合卡住 / 界面显示在跑但没结果时，一条命令看清：
#   1) 系统内存还够不够
#   2) 有没有真的在跑的综合进程
#   3) runme.log 是否在更新、跑到哪一步
#   4) 有没有崩溃转储、残留锁标记
#
# 用法（任选其一）：
#   powershell -ExecutionPolicy Bypass -File "D:\Engineering_save\FPGA\AMD_ZYNQ\check_vivado.ps1"
#   powershell -ExecutionPolicy Bypass -File "...\check_vivado.ps1" -ProjectDir "D:\...\radar_pl_give.xpr\radar_pl"
#   powershell -ExecutionPolicy Bypass -File "...\check_vivado.ps1" -RunName impl_1
#
# 参数：
#   -ProjectDir  .xpr 所在目录（默认 D:\Engineering_save\FPGA\AMD_ZYNQ\radar_pl）
#   -RunName     运行名（默认 synth_1）
#   -NoPause     跑完直接退出，不等人按回车
# ============================================================
param(
    [string]$ProjectDir = "D:\Engineering_save\FPGA\AMD_ZYNQ\radar_pl",
    [string]$RunName    = "synth_1",
    [switch]$NoPause
)

$ErrorActionPreference = "SilentlyContinue"

function Write-Sep {
    Write-Output ("-" * 72)
}

# ---------- 0. 定位工程与运行目录 ----------
$xpr = Get-ChildItem $ProjectDir -Filter *.xpr -File -ErrorAction SilentlyContinue | Select-Object -First 1
if ($xpr) { $projName = $xpr.BaseName } else { $projName = "radar_pl" }

$runsDir = Join-Path $ProjectDir ($projName + ".runs")
$runDir  = Join-Path $runsDir $RunName
$logPath = Join-Path $runDir "runme.log"

Write-Output ""
Write-Output ("=" * 72)
Write-Output ("  Vivado 体检报告   " + (Get-Date -Format "yyyy/MM/dd HH:mm:ss"))
Write-Output ("  工程: " + $ProjectDir)
Write-Output ("  运行: " + $RunName)
Write-Output ("=" * 72)

# ---------- 1. 系统内存 ----------
Write-Output ""
Write-Output "[1] 系统内存"
$os         = Get-CimInstance Win32_OperatingSystem
$physFree   = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
$commitFree = [math]::Round($os.FreeVirtualMemory  / 1MB, 1)
Write-Output ("    物理可用 : {0,6} GB" -f $physFree)
Write-Output ("    提交可用 : {0,6} GB" -f $commitFree)
if ($commitFree -lt 2) {
    Write-Output "    !! 提交内存不足 2 GB：Vivado 综合（峰值约 6 GB）很可能起不来"
    Write-Output "    !! 处理：关掉 MATLAB/浏览器/IDE 等大程序，或重启电脑"
}

# ---------- 2. Vivado / cmd 进程 ----------
Write-Output ""
Write-Output "[2] Vivado / cmd 进程"
$procs = @(Get-Process | Where-Object { $_.ProcessName -match "^vivado$|^cmd$" })
if ($procs.Count -eq 0) {
    Write-Output "    没有 vivado/cmd 进程（Vivado 没开）"
} else {
    $procs | Sort-Object StartTime | ForEach-Object {
        $commit = [math]::Round($_.PrivateMemorySize64 / 1GB, 2)
        $ws     = [math]::Round($_.WorkingSet64      / 1GB, 2)
        $cpu    = 0
        if ($_.CPU -ne $null) { $cpu = [math]::Round($_.CPU, 0) }
        $flag = ""
        if ($_.ProcessName -eq "vivado" -and $commit -gt 1 -and $ws -lt 0.2) {
            $flag = "   <== 疑似挂死（提交大、工作集小）"
        }
        Write-Output ("    PID {0,-6} {1,-7}  提交 {2,6} GB  工作集 {3,6} GB  CPU {4,7}s  启动 {5}{6}" -f `
            $_.Id, $_.ProcessName, $commit, $ws, $cpu, $_.StartTime, $flag)
    }
}

# ---------- 3. 进程父子关系 ----------
Write-Output ""
Write-Output "[3] 进程父子关系（判断是不是包装脚本在等子进程）"
$tree = @(Get-CimInstance Win32_Process | Where-Object { $_.Name -match "^vivado|^cmd\.exe$" })
if ($tree.Count -eq 0) {
    Write-Output "    无"
} else {
    $tree | Sort-Object CreationDate | ForEach-Object {
        Write-Output ("    PID {0,-6} 父 {1,-6} {2,-12} 启动 {3}" -f $_.ProcessId, $_.ParentProcessId, $_.Name, $_.CreationDate)
    }
}

# ---------- 4. 占内存最多的程序（方便决定关谁） ----------
Write-Output ""
Write-Output "[4] 占提交内存最多的程序 (Top 8)"
Get-Process | Sort-Object PrivateMemorySize64 -Descending | Select-Object -First 8 | ForEach-Object {
    Write-Output ("    {0,-24} PID {1,-6} 提交 {2,6} GB  工作集 {3,6} GB" -f `
        $_.ProcessName, $_.Id, [math]::Round($_.PrivateMemorySize64 / 1GB, 2), [math]::Round($_.WorkingSet64 / 1GB, 2))
}

# ---------- 5. 运行目录 ----------
Write-Output ""
Write-Output "[5] 运行目录: $runDir"
$logAge   = 999999
$hasDcp   = $false
if (-not (Test-Path $runDir)) {
    Write-Output "    目录不存在（这个运行还没开始过）"
} else {
    if (Test-Path $logPath) {
        $lf    = Get-Item $logPath
        $logAge = ((Get-Date) - $lf.LastWriteTime).TotalSeconds
        Write-Output ("    runme.log : 最后写入 {0}   已静默 {1:N0} 秒   大小 {2:N0} 字节" -f $lf.LastWriteTime, $logAge, $lf.Length)
        Write-Output "    ---- 最后 5 行 ----"
        Get-Content $logPath -Tail 5 | ForEach-Object { Write-Output ("    | " + $_) }
    } else {
        Write-Output "    runme.log : 不存在（综合还没真正启动）"
    }

    $dcps = @(Get-ChildItem $runDir -Filter *.dcp -File)
    if ($dcps.Count -gt 0) {
        $hasDcp = $true
        Write-Output ("    综合产物  : " + (($dcps | ForEach-Object { $_.Name + " (" + $_.LastWriteTime + ")" }) -join ", "))
    } else {
        Write-Output "    综合产物  : 无 .dcp  => 综合没有完成"
    }

    Write-Output "    ---- 运行标记 ----"
    foreach ($m in @("__synthesis_is_running__", ".vivado.begin.rst", ".vivado.error.rst", ".stop.rst")) {
        $mp = Join-Path $runDir $m
        if (Test-Path $mp) {
            Write-Output ("    {0,-28} 存在   最后写入 {1}" -f $m, (Get-Item $mp).LastWriteTime)
        } else {
            Write-Output ("    {0,-28} 无" -f $m)
        }
    }

    $hs = @(Get-ChildItem $runDir -Filter "hs_err_*" -File)
    if ($hs.Count -gt 0) {
        Write-Output "    ---- 崩溃转储 ----"
        $hs | ForEach-Object { Write-Output ("    " + $_.Name + "  " + $_.LastWriteTime) }
    }
}

# ---------- 6. 最近阶段 ----------
if (Test-Path $logPath) {
    Write-Output ""
    Write-Output "[6] 最近的阶段 / 错误"
    $hits = @(Select-String -Path $logPath -Pattern "Start |Finished |ERROR|CRITICAL WARNING" | Select-Object -Last 8)
    if ($hits.Count -eq 0) {
        Write-Output "    (日志里没有阶段标记)"
    } else {
        $hits | ForEach-Object { Write-Output ("    | " + $_.Line) }
    }
}

# ---------- 7. 结论 ----------
Write-Output ""
Write-Sep "判断"
if ($hasDcp) {
    Write-Output "    结果：有 .dcp，综合已经完成过（看上面的时间是不是本次运行）"
} else {
    $workers = @(Get-Process | Where-Object { $_.ProcessName -eq "vivado" -and $_.PrivateMemorySize64 -gt 1GB })
    if ($workers.Count -gt 0 -and $logAge -lt 120) {
        Write-Output "    结果：有综合工作进程且日志在更新  =>  正在运行，正常等待"
    } elseif ($workers.Count -gt 0 -and $logAge -ge 120) {
        Write-Output "    结果：有工作进程但日志超过 2 分钟没更新  =>  可能卡住，再等 5 分钟复查"
    } else {
        Write-Output "    结果：没有综合工作进程  =>  综合没有在跑（界面显示 Running 是假象）"
        Write-Output "    处理：先 reset_run；不行就关 Vivado，删掉本运行目录后重开"
    }
}
if ($commitFree -lt 2) {
    Write-Output "    注意：提交内存只剩 $commitFree GB，先腾内存再跑"
}
Write-Output ("-" * 72)
Write-Output ""

if (-not $NoPause) {
    Read-Host "按回车退出" | Out-Null
}
