# Rebuilds tmux.exe: arndawg/tmux-windows at the pinned tag plus wide-char-width.patch.
# Needs Visual Studio 2022 C++ build tools, git, and vcpkg (-VcpkgRoot or VCPKG_ROOT).
param(
    [string]$VcpkgRoot = $env:VCPKG_ROOT,
    [string]$WorkDir = (Join-Path $env:TEMP 'keepalive-tmux-build')
)

$tag = 'v3.6a-win32.7'
$patch = Join-Path $PSScriptRoot 'wide-char-width.patch'

if (-not $VcpkgRoot -or -not (Test-Path -LiteralPath (Join-Path $VcpkgRoot 'vcpkg.exe'))) {
    Write-Output 'vcpkg.exe not found: pass -VcpkgRoot or set VCPKG_ROOT'
    exit 1
}

$cmake = (Get-Command cmake.exe -ErrorAction SilentlyContinue).Source
if (-not $cmake) {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    $vs = & $vswhere -latest -products * -version '[17.0,18.0)' -property installationPath
    $cmake = Join-Path $vs 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
}
if (-not (Test-Path -LiteralPath $cmake)) { Write-Output 'cmake.exe not found'; exit 1 }

& (Join-Path $VcpkgRoot 'vcpkg.exe') install libevent:x64-windows-static
if ($LASTEXITCODE -ne 0) { exit 1 }

if (Test-Path -LiteralPath $WorkDir) { Remove-Item -Recurse -Force -LiteralPath $WorkDir }
git clone --quiet --depth 1 --branch $tag https://github.com/arndawg/tmux-windows $WorkDir
if ($LASTEXITCODE -ne 0) { exit 1 }
git -C $WorkDir apply --whitespace=nowarn $patch
if ($LASTEXITCODE -ne 0) { Write-Output 'patch did not apply'; exit 1 }

$build = Join-Path $WorkDir 'build'
& $cmake -S $WorkDir -B $build -G 'Visual Studio 17 2022' -A x64 "-DCMAKE_TOOLCHAIN_FILE=$VcpkgRoot\scripts\buildsystems\vcpkg.cmake" -DVCPKG_TARGET_TRIPLET=x64-windows-static
if ($LASTEXITCODE -ne 0) { exit 1 }
& $cmake --build $build --config Release
if ($LASTEXITCODE -ne 0) { exit 1 }

$out = Join-Path $PSScriptRoot 'tmux.exe'
Copy-Item -LiteralPath (Join-Path $build 'Release\tmux.exe') -Destination $out -Force
Write-Output "built $out"
