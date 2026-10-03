using System;
using System.Collections.Generic;
using System.Text.RegularExpressions;

namespace Rewindle.Setup
{
    internal sealed class BridgeRequest
    {
        public string Id;
        public string Command;
        public IDictionary<string, object> Payload;
    }

    // The wire format between the wizard page and this program, and the one list of what the page may ask for. A message is
    // accepted only if it is a JSON object of the form {"type":"request","id":"<token>","command":"<name from Commands>",
    // "payload":{...}} and no longer than MaximumMessageLength; anything else is dropped without an answer (it did not come from
    // the wizard), and a well-formed request for a command that is not listed is answered with an error. The payloads themselves
    // are checked again by the command that reads them (see SetupBridge and InstallerContract). The page's side of this is
    // web/src/setup/bridge.ts, and a test keeps the two lists of commands equal.
    internal static class BridgeProtocol
    {
        public const int Version = 1;
        public const int MaximumMessageLength = 256 * 1024;

        public static readonly string[] Commands =
        {
            "hello",
            "getPlan",
            "browseFolder",
            "browseRepositoryFolder",
            "measureFolders",
            "cancelMeasure",
            "install",
            "cancelInstall",
            "uninstall",
            "openDashboard",
            "saveRecoveryKeyCopy",
            "showRecoveryKey",
            "copyText",
            "openUrl",
            "setZoom",
            "close"
        };

        private static readonly Regex IdPattern = new Regex("^[A-Za-z0-9_-]{1,64}$", RegexOptions.CultureInvariant);

        public static bool IsCommand(string name)
        {
            return name != null && Array.IndexOf(Commands, name) >= 0;
        }

        public static bool IsValidId(string id)
        {
            return id != null && IdPattern.IsMatch(id);
        }

        // Returns false for a message that is not a well-formed request. `request.Command` is null when the command is not one
        // the page may use; the caller answers that with an error, because the page is waiting for an answer.
        public static bool TryParseRequest(string json, out BridgeRequest request)
        {
            request = null;
            if (string.IsNullOrEmpty(json) || json.Length > MaximumMessageLength)
            {
                return false;
            }
            object parsed;
            try
            {
                parsed = Json.Parse(json);
                // The page sends objects; a string holding JSON (the web view's own convention) is read once as well.
                string text = parsed as string;
                if (text != null)
                {
                    parsed = Json.Parse(text);
                }
            }
            catch (Exception)
            {
                return false;
            }
            IDictionary<string, object> message = Json.AsObject(parsed);
            if (message == null || !string.Equals(Json.String(message, "type", 16), "request", StringComparison.Ordinal))
            {
                return false;
            }
            string id = Json.String(message, "id", 64);
            if (!IsValidId(id))
            {
                return false;
            }
            string command = Json.String(message, "command", 64);
            request = new BridgeRequest();
            request.Id = id;
            request.Command = IsCommand(command) ? command : null;
            request.Payload = Json.AsObject(Json.Get(message, "payload"));
            return true;
        }

        public static string Response(string id, object result)
        {
            Dictionary<string, object> message = new Dictionary<string, object>();
            message["type"] = "response";
            message["id"] = id;
            message["ok"] = true;
            message["result"] = result;
            return Json.Serialize(message);
        }

        public static string Failure(string id, string code, string text)
        {
            Dictionary<string, object> error = new Dictionary<string, object>();
            error["code"] = code;
            error["message"] = text;
            Dictionary<string, object> message = new Dictionary<string, object>();
            message["type"] = "response";
            message["id"] = id;
            message["ok"] = false;
            message["error"] = error;
            return Json.Serialize(message);
        }

        public static string Event(string name, object data)
        {
            Dictionary<string, object> message = new Dictionary<string, object>();
            message["type"] = "event";
            message["event"] = name;
            message["data"] = data;
            return Json.Serialize(message);
        }
    }

    // Where the wizard page is served from, and the one address the web view may ever load or request: https on the virtual host
    // that SetupWindow maps to the unpacked wizard folder. Nothing else (no other host, no credentials in the address, no other
    // port) is navigated to, requested or accepted as the source of a message.
    internal static class WebPolicy
    {
        public const string HostName = "rewindle-setup.local";
        public const string Origin = "https://rewindle-setup.local";
        public const string PageAddress = "https://rewindle-setup.local/setup.html";

        public static bool IsAllowedUri(string value)
        {
            Uri uri;
            if (!Uri.TryCreate(value, UriKind.Absolute, out uri))
            {
                return false;
            }
            return string.Equals(uri.Scheme, Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase) &&
                string.Equals(uri.Host, HostName, StringComparison.OrdinalIgnoreCase) &&
                string.IsNullOrEmpty(uri.UserInfo) &&
                (uri.Port == -1 || uri.Port == 443);
        }
    }
}
