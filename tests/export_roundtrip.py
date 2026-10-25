"""Independent standard-library decoders for the Rust export regression test."""
import csv
import json
import pathlib
import sys

base = pathlib.Path(sys.argv[1])
fields = ["path", "path_hex", "kind", "allocated_bytes", "accounted_bytes", "subtree_bytes"]
expected = (base / "expected-hex").read_text().splitlines()
with (base / "rows.csv").open(newline="", encoding="utf-8") as stream:
    reader = csv.DictReader(stream)
    assert reader.fieldnames == fields
    csv_rows = list(reader)
with (base / "rows.jsonl").open(encoding="utf-8") as stream:
    json_rows = [json.loads(line) for line in stream]


def unescape(value):
    result = []
    chars = iter(value)
    for char in chars:
        result.append({"t": "\t", "n": "\n", "r": "\r", "\\": "\\"}[next(chars)] if char == "\\" else char)
    return "".join(result)


with (base / "rows.tsv").open(newline="", encoding="utf-8") as stream:
    lines = stream.read().split("\n")
assert lines.pop() == ""
assert lines.pop(0).split("\t") == fields
assert len(lines) == len(expected)  # Exactly one physical line per record.
tsv_rows = []
for line in lines:
    values = line.split("\t")
    assert len(values) == len(fields)
    values[0] = unescape(values[0])
    tsv_rows.append(dict(zip(fields, values)))
for rows in [csv_rows, json_rows, tsv_rows]:
    assert [row["path_hex"] for row in rows] == expected
    for row in rows:
        assert row["path"] == bytes.fromhex(row["path_hex"]).decode("utf-8", errors="replace")
        for field in fields[3:]:
            if rows is json_rows:
                assert type(row[field]) is int
            row[field] = int(row[field])
assert csv_rows == json_rows == tsv_rows
assert json_rows[0]["path"] == "" and json_rows[0]["kind"] == "directory"
assert all(row["kind"] == "file" for row in json_rows[1:])
assert all(row["allocated_bytes"] == row["accounted_bytes"] == row["subtree_bytes"] == 8192 for row in json_rows[1:])
