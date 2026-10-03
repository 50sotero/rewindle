using System.Reflection;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;

// The version attributes are not here: build.ps1 generates them from the repository's VERSION file (obj\AssemblyVersion.g.cs),
// so the setup program, the release bundle and every other binary carry the one version.
[assembly: AssemblyTitle("Rewindle Setup")]
[assembly: AssemblyDescription("Install Rewindle encrypted backup and verified recovery")]
[assembly: AssemblyProduct("Rewindle")]
[assembly: AssemblyCompany("Victor Sotero")]
[assembly: AssemblyCopyright("Copyright (c) 2026 Victor Sotero")]
[assembly: ComVisible(false)]
// csc does not say which .NET Framework a program targets, and without it the runtime applies the compatibility behavior of
// .NET 4.0: WPF would not follow a window between monitors of different scaling, and long paths would not work. Declaring 4.8
// (the version the installer requires anyway) turns the current behavior on.
[assembly: TargetFramework(".NETFramework,Version=v4.8", FrameworkDisplayName = ".NET Framework 4.8")]
