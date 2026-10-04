using System;

namespace Rewindle.Setup
{
    // The only web addresses Setup ever opens. The page asks by name ("readme"), never by address, and each name maps to a fixed
    // address of the project's own, the one the dashboard's About page states (web/src/project.ts).
    internal static class ProjectLinks
    {
        public const string Repository = "https://github.com/50sotero/rewindle";

        public static bool TryResolve(string name, out string address)
        {
            switch (name)
            {
                case "readme":
                    address = Repository + "#readme";
                    return true;
                case "issues":
                    address = Repository + "/issues";
                    return true;
                case "license":
                    address = Repository + "/blob/main/LICENSE";
                    return true;
                case "requirements":
                    address = Repository + "#requirements";
                    return true;
                default:
                    address = null;
                    return false;
            }
        }
    }
}
