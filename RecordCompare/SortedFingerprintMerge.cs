// .NET Framework 4.7 / Windows PowerShell 5.1 compatible.
// Local file operations only. No network and no database connections.
using System;
using System.IO;
using System.IO.Compression;
using System.Text;

public sealed class FingerprintCompareCounts
{
    public long SourceRows { get; set; }
    public long TargetRows { get; set; }
    public long OnlyInSource { get; set; }
    public long Changed { get; set; }
    public long OnlyInTarget { get; set; }
    public long Unchanged { get; set; }
    public long DetailRowsWritten { get; set; }
    public bool DetailsTruncated { get; set; }
}

public static class SortedFingerprintMerge
{
    private sealed class FingerprintRow
    {
        public string HexId;
        public string Fingerprint;
    }

    private static readonly StringComparer CompareIds = StringComparer.Ordinal;
    private static readonly UTF8Encoding StrictUtf8 = new UTF8Encoding(false, true);

    private static FingerprintRow Next(StreamReader reader, ref string previousId)
    {
        string line = reader.ReadLine();
        if (line == null) return null;
        int tab = line.IndexOf('\t');
        if (tab < 1 || tab != line.LastIndexOf('\t'))
            throw new InvalidDataException("Bad fingerprint row (expected one tab): " + line.Substring(0, Math.Min(60, line.Length)));
        string id = line.Substring(0, tab);
        string hash = line.Substring(tab + 1);
        if (id.Length == 0 || (id.Length % 2) != 0 || hash.Length != 64 || !IsLowerHex(id) || !IsLowerHex(hash))
            throw new InvalidDataException("Malformed ID hex or SHA-256 row fingerprint.");
        if (previousId != null && CompareIds.Compare(id, previousId) <= 0)
            throw new InvalidDataException("Unsorted or duplicate record key detected in database export.");
        previousId = id;
        return new FingerprintRow { HexId = id, Fingerprint = hash };
    }

    private static bool IsLowerHex(string text)
    {
        for (int i = 0; i < text.Length; i++)
        {
            char c = text[i];
            if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return false;
        }
        return true;
    }

    private static int HexNibble(char c)
    {
        if (c >= '0' && c <= '9') return c - '0';
        if (c >= 'a' && c <= 'f') return c - 'a' + 10;
        throw new InvalidDataException("Unexpected hex character.");
    }

    private static string DecodeId(string hex)
    {
        byte[] bytes = new byte[hex.Length / 2];
        for (int i = 0; i < bytes.Length; i++)
            bytes[i] = (byte)((HexNibble(hex[2 * i]) << 4) | HexNibble(hex[2 * i + 1]));
        return StrictUtf8.GetString(bytes);
    }

    private static string Csv(string input)
    {
        if (input == null) return "";
        return "\"" + input.Replace("\"", "\"\"") + "\"";
    }

    private static void WriteDifference(StreamWriter writer, string type, FingerprintRow source,
                                        FingerprintRow target, FingerprintCompareCounts counts, long maxDetailRows)
    {
        if (maxDetailRows >= 0 && counts.DetailRowsWritten >= maxDetailRows)
        {
            counts.DetailsTruncated = true;
            return;
        }
        string hex = (source != null ? source.HexId : target.HexId);
        string id = DecodeId(hex);
        writer.Write(type);
        writer.Write(',');
        writer.Write(Csv(id));
        writer.Write(',');
        writer.Write(source != null ? source.Fingerprint : "");
        writer.Write(',');
        writer.Write(target != null ? target.Fingerprint : "");
        writer.WriteLine();
        counts.DetailRowsWritten++;
    }

    // maxDetailRows = -1 means all IDs; nonnegative values limit only the detailed CSV.
    // Aggregate counters are always calculated across the entire two input files.
    public static FingerprintCompareCounts Merge(string sourcePath, string targetPath,
                                               string outputGzipCsvPath, long maxDetailRows)
    {
        var counts = new FingerprintCompareCounts();
        using (var source = new StreamReader(sourcePath, StrictUtf8, true, 1024 * 1024))
        using (var target = new StreamReader(targetPath, StrictUtf8, true, 1024 * 1024))
        using (var file = new FileStream(outputGzipCsvPath, FileMode.CreateNew, FileAccess.Write, FileShare.None, 1024 * 1024))
        using (var compressed = new GZipStream(file, CompressionMode.Compress))
        using (var detail = new StreamWriter(compressed, new UTF8Encoding(false), 1024 * 1024))
        {
            detail.WriteLine("change_type,record_id,source_sha256,target_sha256");
            string priorSourceId = null;
            string priorTargetId = null;
            FingerprintRow s = Next(source, ref priorSourceId);
            FingerprintRow t = Next(target, ref priorTargetId);
            while (s != null || t != null)
            {
                if (t == null || (s != null && CompareIds.Compare(s.HexId, t.HexId) < 0))
                {
                    counts.SourceRows++;
                    counts.OnlyInSource++;
                    WriteDifference(detail, "SOURCE_ONLY", s, null, counts, maxDetailRows);
                    s = Next(source, ref priorSourceId);
                }
                else if (s == null || CompareIds.Compare(s.HexId, t.HexId) > 0)
                {
                    counts.TargetRows++;
                    counts.OnlyInTarget++;
                    WriteDifference(detail, "TARGET_ONLY", null, t, counts, maxDetailRows);
                    t = Next(target, ref priorTargetId);
                }
                else
                {
                    counts.SourceRows++;
                    counts.TargetRows++;
                    if (StringComparer.Ordinal.Equals(s.Fingerprint, t.Fingerprint))
                        counts.Unchanged++;
                    else
                    {
                        counts.Changed++;
                        WriteDifference(detail, "CHANGED", s, t, counts, maxDetailRows);
                    }
                    s = Next(source, ref priorSourceId);
                    t = Next(target, ref priorTargetId);
                }
            }
        }
        if (counts.SourceRows != counts.OnlyInSource + counts.Unchanged + counts.Changed ||
            counts.TargetRows != counts.OnlyInTarget + counts.Unchanged + counts.Changed)
            throw new InvalidDataException("Comparison reconciliation failed.");
        return counts;
    }
}
