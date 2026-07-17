@echo off
REM start.bat - colibri-portable-ssd 即插即用启动器 (Windows 11)
REM
REM 放在 SSD 根目录，双击或在终端运行:
REM     start.bat                交互聊天
REM     start.bat run "提示词"    单次生成
REM     start.bat serve          OpenAI 兼容 API
REM     start.bat --readonly     纯只读模式 (KVSAVE=0, 不写 SSD)
REM
REM 前提: 安装 Python 3.10+ (python.org 或 Microsoft Store)。
setlocal EnableDelayedExpansion

set "ROOT=%~dp0"
REM 去掉末尾反斜杠
if "%ROOT:~-1%"=="\" set "ROOT=%ROOT:~0,-1%"
set "ENGINE=%ROOT%\engine\windows-x86_64"
set "MODEL_DIR=%ROOT%\model\glm52_i4"

REM ---------- 参数 ----------
set "READONLY=0"
set "ARGS="
:parse
if "%~1"=="" goto done_parse
if /I "%~1"=="--readonly" (set "READONLY=1" & shift & goto parse)
if /I "%~1"=="--ro"       (set "READONLY=1" & shift & goto parse)
set "ARGS=%ARGS% %~1"
shift
goto parse
:done_parse
if "%ARGS%"=="" set "ARGS= chat"

REM ---------- 自检 ----------
if not exist "%ENGINE%\coli" (
  echo [x] 找不到 Windows 引擎: %ENGINE%\coli
  echo     这块 SSD 还没有 windows-x86_64 平台的引擎。
  echo     在有网络的 Windows 机器上运行: scripts\build_engine.bat --ssd %ROOT%
  exit /b 1
)
if not exist "%MODEL_DIR%\config.json" (
  echo [x] 模型不存在或不完整: %MODEL_DIR%
  echo     请先下载模型 (约 370GB, 断点续传): coli-ssd download --ssd %ROOT%
  exit /b 1
)

REM ---------- Python ----------
set "PY="
where py >nul 2>nul && (set "PY=py -3")
if not defined PY (where python >nul 2>nul && set "PY=python")
if not defined PY (
  echo [x] 未找到 Python。请从 python.org 安装 Python 3.10+ 后重试。
  exit /b 1
)

REM ---------- 环境 ----------
set "COLI_MODEL=%MODEL_DIR%"
if "%READONLY%"=="1" (
  set "KVSAVE=0"
  set "COLI_USAGE=0"
  echo [*] 纯只读模式: KVSAVE=0, SSD 上不会产生会话写入。
)

echo [*] 模型 %MODEL_DIR%
if "%READONLY%"=="0" echo [*] 提示: start.bat --readonly 可全程不写 SSD; 用完正常退出后即可安全拔出。

REM ---------- 启动 ----------
REM 排除杀毒软件实时扫描 370GB 模型（首次使用建议执行一次, 需要管理员）:
REM   powershell Add-MpPreference -ExclusionPath "%MODEL_DIR%"
cd /d "%ENGINE%"
%PY% "%ENGINE%\coli"%ARGS%
