using System;
using System.Collections;
using System.Collections.Generic;
using System.Web.Script.Serialization;

namespace Rewindle.Setup
{
    // JSON in and out of the host, with the same serializer the dashboard uses. Reads are defensive: a value that is missing,
    // of another type or too long is "not there", and the callers decide what that means.
    internal static class Json
    {
        public const int MaximumLength = 16 * 1024 * 1024;

        private static JavaScriptSerializer Create()
        {
            JavaScriptSerializer serializer = new JavaScriptSerializer();
            serializer.MaxJsonLength = MaximumLength;
            serializer.RecursionLimit = 64;
            return serializer;
        }

        // Throws on text that is not JSON. Objects come back as IDictionary<string, object>, arrays as object[] or ArrayList.
        public static object Parse(string text)
        {
            return Create().DeserializeObject(text);
        }

        public static string Serialize(object value)
        {
            return Create().Serialize(value);
        }

        public static IDictionary<string, object> AsObject(object value)
        {
            return value as IDictionary<string, object>;
        }

        public static IList<object> AsList(object value)
        {
            object[] array = value as object[];
            if (array != null)
            {
                return array;
            }
            ArrayList list = value as ArrayList;
            if (list != null)
            {
                List<object> copy = new List<object>(list.Count);
                foreach (object item in list)
                {
                    copy.Add(item);
                }
                return copy;
            }
            return null;
        }

        public static object Get(IDictionary<string, object> values, string key)
        {
            object value;
            if (values == null || !values.TryGetValue(key, out value))
            {
                return null;
            }
            return value;
        }

        // The string under `key`, or null when it is absent, not a string or longer than maximumLength.
        public static string String(IDictionary<string, object> values, string key, int maximumLength)
        {
            string value = Get(values, key) as string;
            if (value == null || value.Length > maximumLength)
            {
                return null;
            }
            return value;
        }

        public static bool? Bool(IDictionary<string, object> values, string key)
        {
            object value = Get(values, key);
            if (value is bool)
            {
                return (bool)value;
            }
            return null;
        }

        public static long? Long(IDictionary<string, object> values, string key)
        {
            object value = Get(values, key);
            if (value is int)
            {
                return (int)value;
            }
            if (value is long)
            {
                return (long)value;
            }
            if (value is decimal)
            {
                decimal number = (decimal)value;
                if (number == Math.Truncate(number) && number >= long.MinValue && number <= long.MaxValue)
                {
                    return (long)number;
                }
            }
            if (value is double)
            {
                double number = (double)value;
                if (number == Math.Truncate(number) && Math.Abs(number) < 9e15)
                {
                    return (long)number;
                }
            }
            return null;
        }
    }
}
