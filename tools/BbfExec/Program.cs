using System.Text.RegularExpressions;
using Microsoft.Data.SqlClient;

// Usage: BBF_CS='Server=...;User ID=...;Password=...' BbfExec < script.sql
// The connection string comes from the environment so it is not in any process's arguments.
// Prints result sets as tab-separated rows; stops at the first error (exit 1).
if (Environment.GetEnvironmentVariable("BBF_MANAGED_SNI") == "1") AppContext.SetSwitch("Switch.Microsoft.Data.SqlClient.UseManagedNetworkingOnWindows", true);
var cs = Environment.GetEnvironmentVariable("BBF_CS");
if (string.IsNullOrEmpty(cs)) { Console.Error.WriteLine("BBF_CS is not set"); return 2; }
var script = Console.In.ReadToEnd();
var batches = Regex.Split(script, @"^\s*GO\s*$", RegexOptions.Multiline | RegexOptions.IgnoreCase)
    .Where(b => !string.IsNullOrWhiteSpace(b));
try
{
    await using var c = new SqlConnection(cs);
    await c.OpenAsync();
    foreach (var b in batches)
    {
        await using var cmd = new SqlCommand(b, c) { CommandTimeout = 120 };
        await using var r = await cmd.ExecuteReaderAsync();
        do
            while (await r.ReadAsync())
                Console.WriteLine(string.Join('\t', Enumerable.Range(0, r.FieldCount).Select(i => r.IsDBNull(i) ? "NULL" : r.GetValue(i).ToString())));
        while (await r.NextResultAsync());
    }
    return 0;
}
catch (SqlException e)
{
    Console.Error.WriteLine($"error {e.Number}: {e.Message}");
    return 1;
}
