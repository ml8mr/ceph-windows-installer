[CmdletBinding(DefaultParameterSetName='None')]
Param(
    # Builds Ceph using WSL
    [Parameter(ParameterSetName="CephWSL", Mandatory=$true)]
    [Parameter(ParameterSetName="CephWSLSign", Mandatory=$true)]
    [switch]$UseWSL = $false,
    [Parameter(ParameterSetName="CephWSL")]
    [Parameter(ParameterSetName="CephWSLSign")]
    [ValidateNotNullOrEmpty()]
    [string]$WSLDistro = "Ubuntu-20.04",
    [Parameter(ParameterSetName="CephWSL")]
    [Parameter(ParameterSetName="CephWSLSign")]
    [ValidateNotNullOrEmpty()]
    [string]$CephRepoUrl = "https://github.com/petrutlucian94/ceph",
    [Parameter(ParameterSetName="CephWSL")]
    [Parameter(ParameterSetName="CephWSLSign")]
    [ValidateNotNullOrEmpty()]
    [string]$CephRepoBranch = "windows.12",

    # Archive containing the Ceph Windows binaries, will be fetched using scp.
    # Can be a local path, a UNC path or a remote scp path.
    [Parameter(ParameterSetName="CephZipPath", Mandatory=$true)]
    [Parameter(ParameterSetName="CephZipPathSign", Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]$CephZipPath,

    # The thumbprint of the X509 certificate used for signing the WNBD driver
    # and the MSI installer
    [Parameter(ParameterSetName="CephZipPathSign", Mandatory=$true)]
    [Parameter(ParameterSetName="CephWSLSign", Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]$SignX509Thumbprint,
    [Parameter(ParameterSetName="CephZipPathSign", Mandatory=$true)]
    [Parameter(ParameterSetName="CephWSLSign", Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]$SignTimestampUrl,
    [Parameter(ParameterSetName="CephZipPathSign", Mandatory=$true)]
    [Parameter(ParameterSetName="CephWSLSign", Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]$SignCrossCertPath,

    # Don't remove the dependencies build directory if it exists.
    # This can be useful during development
    [switch]$RetainDependenciesBuildDir = $false
)

$ErrorActionPreference = "Stop"

function SetVCVars($version="2019", $platform="x86_amd64") {
    pushd "$ENV:ProgramFiles (x86)\Microsoft Visual Studio\$version\Community\VC\Auxiliary\Build"
    try {
        cmd /c "vcvarsall.bat $platform & set" |
        foreach {
          if ($_ -match "=") {
            $v = $_.split("="); set-item -force -path "ENV:\$($v[0])"  -value "$($v[1])"
          }
        }
    }
    finally {
        popd
    }
}

function Sign($x509thumbprint, $crossCertPath, $timestampUrl, $path) {
    & signtool.exe sign /ac $crossCertPath /sha1 $x509thumbprint /tr $timestampUrl /td SHA256 /v $path
    if($LASTEXITCODE) { throw "signtool failed" }
}

function BuildWnbd() {
    pushd $depsBuildDir
    if (!(Test-Path wnbd)) {
        & git.exe clone https://github.com/cloudbase/wnbd
        if($LASTEXITCODE) {
            throw "git failed"
        }
    }
    cd wnbd

    & msbuild.exe vstudio\wnbd.sln /p:Configuration=Release
    if($LASTEXITCODE) {
        throw "msbuild failed"
    }

    if($SignX509Thumbprint) {
        Sign $SignX509Thumbprint $SignCrossCertPath $SignTimestampUrl .\vstudio\x64\Release\driver\wnbd.sys
        Sign $SignX509Thumbprint $SignCrossCertPath $SignTimestampUrl .\vstudio\x64\Release\driver\wnbd.cat
    }

    copy vstudio\x64\Release\driver\* ..\..\Driver\
    copy vstudio\x64\Release\libwnbd.dll ..\..\Binaries\

    popd
}

function CopyCephBinaries($sourcePath, $targetPath) {
    $targetFullPath = (Get-Item $targetPath).FullName

    pushd $sourcePath
    copy -Path *.dll,`
    ceph-conf.exe,`
    rados.exe,`
    rbd.exe,`
    rbd-wnbd.exe,`
    ceph-dokan.exe `
    -Destination $targetFullPath
    popd
}

function GetCephBinaries() {
    pushd $depsBuildDir

    if (!(Test-Path cephzip)) {
        & scp.exe $CephZipPath ceph.zip
        if($LASTEXITCODE) {
            throw "scp failed"
        }

        Expand-Archive ceph.zip -DestinationPath cephzip
        rm ceph.zip
    }

    CopyCephBinaries "cephzip\ceph" "..\Binaries\"
    popd
}

function BuildCephWSL() {
    pushd $depsBuildDir

    if (!(Test-Path ceph)) {
        & git.exe -c core.symlinks=true clone --recurse-submodules $CephRepoUrl $CephRepoBranch
        if($LASTEXITCODE) {
            throw "git failed"
        }
    }
    cd ceph

    & wsl.exe -d $WSLDistro -u root -e bash -c "BUILD_ZIP=1 STRIP_ZIPPED=1 SKIP_TESTS=1 SKIP_BINDIR_CLEAN=1 ./win32_build.sh"
    if($LASTEXITCODE) {
        throw "Ceph WSL build failed"
    }

    CopyCephBinaries "build\bin_stripped" "..\..\Binaries\"
    popd
}

$depsBuildDir = "Dependencies"

SetVCVars

if ((Test-Path $depsBuildDir) -and !$RetainDependenciesBuildDir) {
    Write-Output "Removing dependencies build dir"
    rm -Recurse -Force $depsBuildDir\
}

mkdir -Force $depsBuildDir

del Driver\*
del Binaries\*

if($UseWSL) {
    BuildCephWSL
} else {
    GetCephBinaries
}

BuildWnbd

$configuration = "Release"
& msbuild.exe ceph-windows-installer.sln /p:Platform=x64 /p:Configuration=$configuration
if($LASTEXITCODE) {
    throw "msbuild failed"
}

if($SignX509Thumbprint) {
    Sign $SignX509Thumbprint $SignCrossCertPath $SignTimestampUrl .\bin\Release\Ceph.msi
}

Write-Output ""
Write-Output "Success! MSI location: $((Get-Item .\bin\$configuration\Ceph.msi).FullName)"
