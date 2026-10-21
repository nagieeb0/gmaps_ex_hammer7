#!/usr/bin/env python3
"""Combine all leads_pages/page_*.csv into a single XLSX file with ONE worksheet.

Pure stdlib (no openpyxl/pandas needed). Each source page CSV already carries the
page metadata columns (page_number, rank_in_page, page_area_label,
page_center_lat, page_center_lon, page_radius_km) plus the original lead columns,
so we simply concatenate them into one sheet, keeping the ranking preserved.

Output: leads_pages_all.xlsx  (worksheet "Leads")
"""
import csv
import glob
import os
import re
import zipfile

SRC_DIR = "leads_pages"
OUT = "leads_pages_all.xlsx"
SHEET_NAME = "Leads"


def esc(v):
    return (v.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
            .replace('"', "&quot;"))


def load_pages(src_dir):
    files = sorted(
        glob.glob(os.path.join(src_dir, "page_*.csv")),
        key=lambda p: int(re.search(r"page_(\d+)\.csv", p).group(1)),
    )
    rows = []
    header = None
    for path in files:
        with open(path, encoding="utf-8", newline="") as f:
            reader = csv.reader(f)
            hdr = next(reader)
            if header is None:
                header = hdr
            for r in reader:
                if not r:
                    continue
                rows.append(r)
    return header, rows


def col_letter(idx):  # 0-based -> A, B, ...
    s = ""
    idx += 1
    while idx:
        idx, rem = divmod(idx - 1, 26)
        s = chr(65 + rem) + s
    return s


def build_xlsx(header, rows, out):
    ncols = len(header)
    last_col = col_letter(ncols - 1)
    nrows = len(rows)
    dimension = f"A1:{last_col}{nrows + 1}"

    # shared strings
    str_index = {}
    shared = []
    sheet_cells = []  # (row_idx_0based, col_idx_0based, is_str, value)

    def sref(value):
        if value not in str_index:
            str_index[value] = len(shared)
            shared.append(value)
        return str_index[value]

    # header row
    for c, val in enumerate(header):
        sheet_cells.append((0, c, True, sref(val)))
    # data rows
    for r, row in enumerate(rows, start=1):
        for c in range(ncols):
            val = row[c] if c < len(row) else ""
            # numeric if it looks like a plain number (negative/decimal), else string
            if re.fullmatch(r"-?\d+(\.\d+)?", val):
                sheet_cells.append((r, c, False, val))
            else:
                sheet_cells.append((r, c, True, sref(val)))

    # group by row for streaming-ish output
    by_row = {}
    for (r, c, is_str, v) in sheet_cells:
        by_row.setdefault(r, []).append((c, is_str, v))

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
        out_rows.append(f"<row r=\"{r + 1}\">{''.join(cell_xml)}</row>")

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

    shared_xml = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
        f'count="{len(shared)}" uniqueCount="{len(shared)}">'
        + "".join(f"<si><t xml:space=\"preserve\">{esc(s)}</t></si>" for s in shared)
        + "</sst>"
    )

    content_types = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
        '<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
        '<Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>'
        '</Types>'
    )

    root_rels = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>'
        '</Relationships>'
    )

    workbook_xml = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
        'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
        f'<sheets><sheet name="{esc(SHEET_NAME)}" sheetId="1" r:id="rId1"/></sheets>'
        '</workbook>'
    )

    workbook_rels = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>'
        '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/>'
        '</Relationships>'
    )

    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("[Content_Types].xml", content_types)
        z.writestr("_rels/.rels", root_rels)
        z.writestr("xl/workbook.xml", workbook_xml)
        z.writestr("xl/_rels/workbook.xml.rels", workbook_rels)
        z.writestr("xl/worksheets/sheet1.xml", sheet_xml)
        z.writestr("xl/sharedStrings.xml", shared_xml)


def main():
    header, rows = load_pages(SRC_DIR)
    print(f"Pages combined: {len(glob.glob(os.path.join(SRC_DIR, 'page_*.csv')))}")
    print(f"Total lead rows: {len(rows)} | columns: {len(header)}")
    build_xlsx(header, rows, OUT)
    print(f"Wrote {OUT}")


if __name__ == "__main__":
    main()
