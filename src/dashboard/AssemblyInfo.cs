using System.Reflection;
using System.Runtime.InteropServices;

// The version attributes are not here: build.ps1 generates them from the repository's VERSION file (obj\AssemblyVersion.g.cs),
// so the executable, its manifest, the web package and the release all carry the one version.
[assembly: AssemblyTitle("Rewindle")]
[assembly: AssemblyDescription("Rewindle verified backup dashboard")]
[assembly: AssemblyCompany("Victor Sotero")]
[assembly: AssemblyProduct("Rewindle")]
[assembly: AssemblyCopyright("Copyright (c) 2026 Victor Sotero")]
[assembly: ComVisible(false)]
[assembly: Guid("ad39e901-72a7-4e51-a9cc-3e0e4f2cb45f")]
