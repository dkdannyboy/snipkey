using System.Globalization;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

namespace SnipKey.Core;

/// <summary>
/// store.json 직렬화. Swift 의 JSONEncoder(.iso8601, [.prettyPrinted, .sortedKeys])와
/// 맞춘다: 날짜는 초 단위 UTC 'Z', UUID 는 대문자, 키는 정렬.
/// </summary>
public static class StoreJson
{
    public static readonly JsonSerializerOptions Options = CreateOptions();

    private static JsonSerializerOptions CreateOptions()
    {
        var o = new JsonSerializerOptions
        {
            WriteIndented = true,
            // 한글·일본어를 \uXXXX 로 바꾸지 않는다 — Mac 이 쓴 파일과 diff 가 작아야 한다.
            Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
            ReadCommentHandling = JsonCommentHandling.Disallow,
        };
        o.Converters.Add(new UpperGuidConverter());
        o.Converters.Add(new Iso8601DateConverter());
        return o;
    }

    private static readonly string[] RequiredGroupKeys = { "enabled", "id", "name", "snippets" };
    private static readonly string[] RequiredSnippetKeys =
        { "abbreviation", "caseSensitive", "content", "createdAt", "enabled", "id", "label", "modifiedAt" };

    public static StoreData Deserialize(byte[] raw)
    {
        // Swift 쪽은 그룹·스니펫의 키가 모두 필수다. 빠진 채로 기본값을 채워 읽고 다시
        // 쓰면 '없던 값'을 지어내게 되므로, 역직렬화 전에 문서에서 직접 확인한다.
        using (var doc = JsonDocument.Parse(raw))
        {
            if (doc.RootElement.ValueKind != JsonValueKind.Object)
                throw new JsonException("store.json root is not an object");
            if (doc.RootElement.TryGetProperty("groups", out var groups))
            {
                foreach (var g in groups.EnumerateArray())
                {
                    RequireKeys(g, RequiredGroupKeys, "group");
                    foreach (var s in g.GetProperty("snippets").EnumerateArray())
                        RequireKeys(s, RequiredSnippetKeys, "snippet");
                }
            }
        }
        return JsonSerializer.Deserialize<StoreData>(raw, Options)
               ?? throw new JsonException("store.json is null");
    }

    private static void RequireKeys(JsonElement e, string[] keys, string what)
    {
        foreach (var k in keys)
            if (!e.TryGetProperty(k, out _)) throw new JsonException($"{what} is missing required key '{k}'");
    }

    /// <summary>키를 정렬한 들여쓰기 JSON. 같은 내용이면 항상 같은 바이트가 나온다.</summary>
    public static byte[] Serialize(StoreData data)
    {
        var node = JsonSerializer.SerializeToNode(data, Options)!;
        var sorted = Sort(node)!;
        var text = sorted.ToJsonString(Options);
        return Encoding.UTF8.GetBytes(text);
    }

    private static JsonNode? Sort(JsonNode? node) => node switch
    {
        JsonObject obj => new JsonObject(
            obj.OrderBy(kv => kv.Key, StringComparer.Ordinal)
               .Select(kv => KeyValuePair.Create(kv.Key, Sort(kv.Value?.DeepClone())))),
        JsonArray arr => new JsonArray(arr.Select(n => Sort(n?.DeepClone())).ToArray()),
        _ => node?.DeepClone(),
    };

    private sealed class UpperGuidConverter : JsonConverter<Guid>
    {
        public override Guid Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
            => Guid.Parse(reader.GetString()!);

        public override void Write(Utf8JsonWriter writer, Guid value, JsonSerializerOptions options)
            => writer.WriteStringValue(value.ToString("D").ToUpperInvariant());
    }

    /// <summary>Swift .iso8601 은 소수 초를 거부한다 — 한 개라도 있으면 Mac 이 파일 전체를 못 읽는다.</summary>
    private sealed class Iso8601DateConverter : JsonConverter<DateTime>
    {
        public override DateTime Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
        {
            var s = reader.GetString()!;
            return DateTime.Parse(s, CultureInfo.InvariantCulture,
                DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal);
        }

        public override void Write(Utf8JsonWriter writer, DateTime value, JsonSerializerOptions options)
            => writer.WriteStringValue(value.ToUniversalTime().ToString(Iso8601.Format, CultureInfo.InvariantCulture));
    }
}
