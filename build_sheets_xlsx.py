#!/usr/bin/env python3
"""Build leads.xlsx with ONE worksheet per page (550 sheets).

Each source page CSV under leads_pages/page_*.csv becomes its own sheet named
"page_NNN". Ranking and page metadata columns are preserved. Pure stdlib,
no third-party deps.
"""
import csv
import glob
import os
import re
import zipfile

SRC_DIR = "leads_pages"
OUT = "leads.xlsx"


def esc(v):
    return (v.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
            .replace('"', "&quot;"))


def col_letter(idx):  # 0-based -> A, B, ...
    s = ""
    idx += 1
    while idx:
        idx, rem = divmod(idx - 1, 26)
        s = chr(65 + rem) + s
    return s


def load_page(path):
    with open(path, encoding="utf-8", newline="") as f:
        reader = csv.reader(f)
        header = next(reader)
        rows = [r for r in reader if r]
    return header, rows


def build_sheet_xml(header, rows):
    ncols = len(header)
    last_col = col_letter(ncols - 1)
    nrows = len(rows)
    dimension = f"A1:{last_col}{nrows + 1}"

    str_index = {}
    shared = []

    def sref(value):
        if value not in str_index:
            str_index[value] = len(shared)
            shared.append(value)
        return str_index[value]

    by_row = {0: []}
    for c, val in enumerate(header):
        by_row[0].append((c, True, sref(val)))
    for r, row in enumerate(rows, start=1):
        by_row[r] = []
        for c in range(ncols):
            val = row[c] if c < len(row) else ""
            if re.fullmatch(r"-?\d+(\.\d+)?", val):
                by_row[r].append((c, False, val))
            else:
                by_row[r].append((c, True, sref(val)))

    out_rows = []
    for r in range(nrows + 1):
        cells = by_row.get(r, [])
        cells.sort(key=lambda x: x[0])
        cell_xml = []
        for (c, is_str, v) in cells:
            ref = f"{col_letter(c)}{r + 1}"
            if is_str:
                cell_xml.append(f'<c r="{ref}" t="s"><v>{v}</v></c>')
            else:
                cell_xml.append(f'<c r="{ref}"><v>{v}</v></c>')
        out_rows.append(f'<row r="{r + 1}">{"".join(cell_xml)}</row>')

    sheet_xml = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
        f'<dimension ref="{dimension}"/>'
        '<sheetViews><sheetView workbookViewId="0">'
        '<pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/>'
        '</sheetView></sheetViews>'
        '<sheetFormatPr defaultRowHeight="15"/>'
        f'<sheetData>{"".join(out_rows)}</sheetData>'
        f'<autoFilter ref="{dimension}"/>'
        '</worksheet>'
    )
    return sheet_xml, shared


def main():
    files = sorted(
        glob.glob(os.path.join(SRC_DIR, "page_*.csv")),
        key=lambda p: int(re.search(r"page_(\d+)\.csv", p).group(1)),
    )
    assert files, "No page_*.csv found in leads_pages/"

    sheet_names = []
    sheet_xmls = []
    global_shared = []
    global_index = {}

    def gref(value):
        if value not in global_index:
            global_index[value] = len(global_shared)
            global_shared.append(value)
        return global_index[value]

    for i, path in enumerate(files, start=1):
        name = f"page_{i:03d}"
        sheet_names.append(name)
        header, rows = load_page(path)
        xml, local_shared = build_sheet_xml(header, rows)
        sheet_xmls.append(xml)
        # remap local shared refs into the global shared table
        # (rebuild by re-parsing is overkill; instead rebuild sheet with global refs)
        # Simpler: rebuild using global table directly.
        sheet_xmls[-1] = rebuild_with_global(header, rows, gref)

    shared_xml = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
        f'count="{len(global_shared)}" uniqueCount="{len(global_shared)}">'
        + "".join(f"<si><t xml:space=\"preserve\">{esc(s)}</t></si>" for s in global_shared)
        + "</sst>"
    )

    content_types = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
        '<Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>'
        + "".join(
            f'<Override PartName="/xl/worksheets/sheet{i}.xml" '
            'ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
            for i in range(1, len(sheet_xmls) + 1)
        )
        + '</Types>'
    )

    root_rels = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>'
        '</Relationships>'
    )

    sheets_xml = "".join(
        f'<sheet name="{esc(name)}" sheetId="{i}" r:id="rId{i}"/>'
        for i, name in enumerate(sheet_names, start=1)
    )
    workbook_xml = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
        'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
        f'<sheets>{sheets_xml}</sheets>'
        '</workbook>'
    )

    wb_rels = ['<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
               '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">']
    for i in range(1, len(sheet_xmls) + 1):
        wb_rels.append(
            f'<Relationship Id="rId{i}" '
            'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" '
            f'Target="worksheets/sheet{i}.xml"/>'
        )
    wb_rels.append(
        '<Relationship Id="rId'
        f'{len(sheet_xmls) + 1}" '
        'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" '
        'Target="sharedStrings.xml"/>'
    )
    wb_rels.append('</Relationships>')
    workbook_rels = "".join(wb_rels)

    with zipfile.ZipFile(OUT, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("[Content_Types].xml", content_types)
        z.writestr("_rels/.rels", root_rels)
        z.writestr("xl/workbook.xml", workbook_xml)
        z.writestr("xl/_rels/workbook.xml.rels", workbook_rels)
        z.writestr("xl/sharedStrings.xml", shared_xml)
        for i, xml in enumerate(sheet_xmls, start=1):
            z.writestr(f"xl/worksheets/sheet{i}.xml", xml)

    print(f"Pages (sheets): {len(sheet_xmls)}")
    print(f"Unique shared strings: {len(global_shared)}")
    print(f"Wrote {OUT}")


def rebuild_with_global(header, rows, gref):
    """Rebuild a sheet's XML using a shared global string table."""
    ncols = len(header)
    last_col = col_letter(ncols - 1)
    nrows = len(rows)
    dimension = f"A1:{last_col}{nrows + 1}"

    by_row = {0: []}
    for c, val in enumerate(header):
        by_row[0].append((c, True, gref(val)))
    for r, row in enumerate(rows, start=1):
        by_row[r] = []
        for c in range(ncols):
            val = row[c] if c < len(row) else ""
            if re.fullmatch(r"-?\d+(\.\d+)?", val):
                by_row[r].append((c, False, val))
            else:
                by_row[r].append((c, True, gref(val)))

    out_rows = []
    for r in range(nrows + 1):
        cells = by_row.get(r, [])
        cells.sort(key=lambda x: x[0])
        cell_xml = []
        for (c, is_str, v) in cells:
            ref = f"{col_letter(c)}{r + 1}"
            if is_str:
                cell_xml.append(f'<c r="{ref}" t="s"><v>{v}</v></c>')
            else:
                cell_xml.append(f'<c r="{ref}"><v>{v}</v></c>')
        out_rows.append(f'<row r="{r + 1}">{"".join(cell_xml)}</row>')

    return (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
        f'<dimension ref="{dimension}"/>'
        '<sheetViews><sheetView workbookViewId="0">'
        '<pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/>'
        '</sheetView></sheetViews>'
        '<sheetFormatPr defaultRowHeight="15"/>'
        f'<sheetData>{"".join(out_rows)}</sheetData>'
        f'<autoFilter ref="{dimension}"/>'
        '</worksheet>'
    )


if __name__ == "__main__":
    main()
