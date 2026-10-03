# The one place the build names the WebView2 SDK it compiles against: the dashboard (src\dashboard\build.ps1) and Rewindle Setup
# (installer\setup\build.ps1) both reference this exact, hash-checked package, so the two cannot drift apart. Dot-source this file;
# it defines a function only and changes nothing.

$script:RewindleWebView2Version = '1.0.4191.47'
$script:RewindleWebView2PackageSha256 = 'F492BBF547D0DA329553B6727435B677579B1E9F91CC9E4A1AD029366D5F23D0'

# Returns where the pinned package is unpacked (src\dashboard\.packages, ignored by Git) and the files the builds use,
# downloading it from NuGet and checking its SHA-256 when it is not there yet.
function Get-RewindleWebView2Sdk {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)

    $version = $script:RewindleWebView2Version
    $package = Join-Path $ProjectRoot ('src\dashboard\.packages\webview2.' + $version)
    $wpf = Join-Path $package 'lib\net462\Microsoft.Web.WebView2.Wpf.dll'
    if (-not (Test-Path -LiteralPath $wpf)) {
        $archive = $package + '.zip'
        New-Item -ItemType Directory -Path (Split-Path -Parent $archive) -Force | Out-Null
        Invoke-WebRequest -UseBasicParsing -Uri "https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/$version/microsoft.web.webview2.$version.nupkg" -OutFile $archive
        if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $script:RewindleWebView2PackageSha256) {
            throw 'WebView2 package checksum does not match the pinned SDK.'
        }
        Expand-Archive -LiteralPath $archive -DestinationPath $package -Force
    }
    [pscustomobject]@{
        Version = $version
        PackageRoot = $package
        WpfAssembly = $wpf
        CoreAssembly = Join-Path $package 'lib\net462\Microsoft.Web.WebView2.Core.dll'
        LoaderDll = Join-Path $package 'runtimes\win-x64\native\WebView2Loader.dll'
        License = Join-Path $package 'LICENSE.txt'
        Notice = Join-Path $package 'NOTICE.txt'
    }
}
