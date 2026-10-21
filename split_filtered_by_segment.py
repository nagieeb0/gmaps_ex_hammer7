#!/usr/bin/env python3
"""Split filtered_leads/leads_filtered.xlsx into one worksheet per `segment`.

The source file has a single sheet "filtered_leads" (36 columns A..AJ) whose last
column (AJ) holds the `segment` value (company / gov / training / residential).
This rewrites the workbook so each segment gets its own sheet, preserving every
other column exactly (inline strings + numeric cells are copied verbatim).

Pure stdlib (no openpyxl/pandas).
"""
import os
import re
import zipfile

SRC = "filtered_leads/leads_filtered.xlsx"
OUT = "filtered_leads/leads_filtered.xlsx"  # overwrite in place
SEG_COL = "AJ"  # 36th column, 0-based 35
PREFERRED_ORDER = ["company", "gov", "training", "residential"]


def col_to_idx(letters):
    idx = 0
    for ch in letters:
        idx = idx * 26 + (ord(ch) - 64)
    return idx - 1


def col_letter(idx):  # 0-based -> A, B, ...
    s = ""
    idx += 1
    while idx:
        idx, rem = divmod(idx - 1, 26)
        s = chr(65 + rem) + s
    return s


def parse_rows(xml):
    """Yield (row_number, {col_letter: (type_attr, inner_xml)}). Header is r=1."""
    rows = re.findall(r'<row r="(\d+)">(.*?)</row>', xml, re.S)
    out = []
    for rnum, body in rows:
        cells = {}
        for cm in re.finditer(r'<c r="([A-Z]+\d+)"([^>]*)>(.*?)</c>', body, re.S):
            ref, attrs, inner = cm.group(1), cm.group(2), cm.group(3)
            col = re.match(r'([A-Z]+)', ref).group(1)
            t = "n" if 't="n"' in attrs else "inlineStr"
            cells[col] = (t, inner)
        out.append((int(rnum), cells))
    return out


def build_sheet_xml(header_cells, data_rows, ncols):
    """Build a worksheet with frozen header + autofilter.

    header_cells: list of (col_letter, (t, inner)) for the header row.
    data_rows: list of {col_letter: (t, inner)} dicts.
    """
    last_col = col_letter(ncols - 1)
    nrows = len(data_rows)
    dimension = f"A1:{last_col}{nrows + 1}"

    def row_xml(rnum, cells):
        if rnum == 1:
            items = [(col, t, inner) for col, (t, inner) in header_cells]
        else:
            src = data_rows[rnum - 2]
            items = [(col, src[col][0], src[col][1]) for col in src]
        items.sort(key=lambda x: col_to_idx(x[0]))
        cell_xml = []
        for col, t, inner in items:
            ref = f"{col}{rnum}"
            cell_xml.append(f'<c r="{ref}" t="{t}">{inner}</c>')
        return f'<row r="{rnum}">{"".join(cell_xml)}</row>'

    out_rows = [row_xml(1, None)]
    for i in range(nrows):
        out_rows.append(row_xml(2 + i, None))

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


def main():
    with zipfile.ZipFile(SRC) as z:
        sheet_xml = z.read("xl/worksheets/sheet1.xml").decode("utf-8")

    rows = parse_rows(sheet_xml)
    header_rnum, header_dict = rows[0]
    assert header_rnum == 1
    header_cells = [(col, header_dict[col]) for col in header_dict]
    ncols = max(col_to_idx(c[0]) for c in header_cells) + 1

    # group data rows by segment (AJ)
    groups = {}
    for rnum, cells in rows[1:]:
        seg_cell = cells.get(SEG_COL)
        if not seg_cell:
            seg = "unknown"
        else:
            m = re.search(r"<t[^>]*>(.*?)</t>", seg_cell[1], re.S)
            seg = m.group(1) if m else "unknown"
        groups.setdefault(seg, []).append(cells)

    seg_order = [s for s in PREFERRED_ORDER if s in groups]
    seg_order += [s for s in sorted(groups) if s not in seg_order]

    sheet_names = [s[:31] for s in seg_order]
    sheet_xmls = [build_sheet_xml(header_cells, groups[s], ncols) for s in seg_order]

    sheet_names_xml = "".join(
        f'<sheet name="{name}" sheetId="{i}" r:id="rId{i}"/>'
        for i, name in enumerate(sheet_names, start=1)
    )
    workbook_xml = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
        'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
        f'<sheets>{sheet_names_xml}</sheets></workbook>'
    )

    content_types = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
        + "".join(
            f'<Override PartName="/xl/worksheets/sheet{i}.xml" '
            'ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
            for i in range(1, len(sheet_xmls) + 1)
        )
        + "</Types>"
    )

    root_rels = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>'
        '</Relationships>'
    )

    wb_rels = [
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
    ]
    for i in range(1, len(sheet_xmls) + 1):
        wb_rels.append(
            f'<Relationship Id="rId{i}" '
            'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" '
            f'Target="worksheets/sheet{i}.xml"/>'
        )
    wb_rels.append("</Relationships>")
    workbook_rels = "".join(wb_rels)

    with zipfile.ZipFile(OUT, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("[Content_Types].xml", content_types)
        z.writestr("_rels/.rels", root_rels)
        z.writestr("xl/workbook.xml", workbook_xml)
        z.writestr("xl/_rels/workbook.xml.rels", workbook_rels)
        for i, xml in enumerate(sheet_xmls, start=1):
            z.writestr(f"xl/worksheets/sheet{i}.xml", xml)

    print(f"Segments: {len(sheet_xmls)} -> {sheet_names}")
    for s in seg_order:
        print(f"  {s}: {len(groups[s])} rows")


if __name__ == "__main__":
    main()
