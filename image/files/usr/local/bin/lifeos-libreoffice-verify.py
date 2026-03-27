#!/usr/bin/env python3
"""LifeOS LibreOffice Verification Bridge via Python UNO API.

Allows Axi to open, read, and verify spreadsheets/documents without vision.
Connects to a running LibreOffice instance via socket.

Usage:
    lifeos-libreoffice-verify.py read-cells FILE RANGE
    lifeos-libreoffice-verify.py verify-formula FILE CELL EXPECTED
    lifeos-libreoffice-verify.py check-format FILE CELL PROPERTY
    lifeos-libreoffice-verify.py sheet-info FILE
    lifeos-libreoffice-verify.py export-pdf FILE OUTPUT

Prerequisites:
    LibreOffice must be running with socket listener:
    soffice --accept="socket,host=localhost,port=2002;urp;" --norestore &

Examples:
    lifeos-libreoffice-verify.py read-cells budget.xlsx "B2:B10"
    lifeos-libreoffice-verify.py verify-formula budget.xlsx "D47" "1500"
    lifeos-libreoffice-verify.py sheet-info report.ods
"""

import json
import subprocess
import sys
import os
import time

def ensure_libreoffice_listening(port=2002):
    """Start LibreOffice with socket listener if not already running."""
    import socket
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        s.connect(("localhost", port))
        s.close()
        return True
    except ConnectionRefusedError:
        s.close()
        subprocess.Popen(
            ["soffice", "--headless", "--norestore",
             f"--accept=socket,host=localhost,port={port};urp;"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
        )
        for _ in range(30):
            time.sleep(0.5)
            try:
                s2 = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                s2.connect(("localhost", port))
                s2.close()
                return True
            except ConnectionRefusedError:
                continue
        return False


def connect_uno(port=2002):
    """Connect to LibreOffice via UNO socket."""
    try:
        import uno
        from com.sun.star.beans import PropertyValue
    except ImportError:
        print(json.dumps({"error": "python3-uno not available. Install libreoffice-pyuno."}))
        sys.exit(1)

    local_ctx = uno.getComponentContext()
    resolver = local_ctx.ServiceManager.createInstanceWithContext(
        "com.sun.star.bridge.UnoUrlResolver", local_ctx
    )
    ctx = resolver.resolve(
        f"uno:socket,host=localhost,port={port};urp;StarOffice.ComponentContext"
    )
    smgr = ctx.ServiceManager
    desktop = smgr.createInstanceWithContext("com.sun.star.frame.Desktop", ctx)
    return desktop


def open_document(desktop, filepath):
    """Open a document in LibreOffice."""
    from com.sun.star.beans import PropertyValue
    abs_path = os.path.abspath(filepath)
    url = "file://" + abs_path

    prop = PropertyValue()
    prop.Name = "Hidden"
    prop.Value = True

    doc = desktop.loadComponentFromURL(url, "_blank", 0, (prop,))
    if doc is None:
        raise RuntimeError(f"Failed to open: {filepath}")
    return doc


def cmd_read_cells(filepath, cell_range):
    """Read cells from a spreadsheet range like 'A1:D10'."""
    if not ensure_libreoffice_listening():
        print(json.dumps({"error": "Could not start LibreOffice"}))
        sys.exit(1)

    desktop = connect_uno()
    doc = open_document(desktop, filepath)

    try:
        sheet = doc.getSheets().getByIndex(0)
        cr = sheet.getCellRangeByName(cell_range)

        rows = cr.getDataArray()
        result = []
        for row in rows:
            result.append([str(cell) for cell in row])

        print(json.dumps({"range": cell_range, "data": result}))
    finally:
        doc.close(True)


def cmd_verify_formula(filepath, cell_addr, expected):
    """Verify a cell value matches expected."""
    if not ensure_libreoffice_listening():
        print(json.dumps({"error": "Could not start LibreOffice"}))
        sys.exit(1)

    desktop = connect_uno()
    doc = open_document(desktop, filepath)

    try:
        sheet = doc.getSheets().getByIndex(0)
        cell = sheet.getCellRangeByName(cell_addr)
        actual_value = cell.getValue()
        actual_str = cell.getString()
        formula = cell.getFormula()

        match = str(actual_value) == expected or actual_str == expected
        print(json.dumps({
            "cell": cell_addr,
            "value": actual_value,
            "string": actual_str,
            "formula": formula,
            "expected": expected,
            "match": match,
        }))
    finally:
        doc.close(True)


def cmd_check_format(filepath, cell_addr, prop_name):
    """Check formatting property of a cell."""
    if not ensure_libreoffice_listening():
        print(json.dumps({"error": "Could not start LibreOffice"}))
        sys.exit(1)

    desktop = connect_uno()
    doc = open_document(desktop, filepath)

    try:
        sheet = doc.getSheets().getByIndex(0)
        cell = sheet.getCellRangeByName(cell_addr)

        props = {}
        for name in ["CharFontName", "CharHeight", "CellBackColor", "IsCellBackgroundTransparent",
                      "HoriJustify", "CellProtection", "NumberFormat"]:
            try:
                val = cell.getPropertyValue(name)
                props[name] = str(val)
            except Exception:
                pass

        if prop_name in props:
            print(json.dumps({"cell": cell_addr, "property": prop_name, "value": props[prop_name]}))
        else:
            print(json.dumps({"cell": cell_addr, "all_properties": props}))
    finally:
        doc.close(True)


def cmd_sheet_info(filepath):
    """Get sheet names, row/column counts, and basic info."""
    if not ensure_libreoffice_listening():
        print(json.dumps({"error": "Could not start LibreOffice"}))
        sys.exit(1)

    desktop = connect_uno()
    doc = open_document(desktop, filepath)

    try:
        sheets = doc.getSheets()
        info = {"file": filepath, "sheet_count": sheets.getCount(), "sheets": []}

        for i in range(sheets.getCount()):
            sheet = sheets.getByIndex(i)
            cursor = sheet.createCursor()
            cursor.gotoStartOfUsedArea(False)
            cursor.gotoEndOfUsedArea(True)

            info["sheets"].append({
                "name": sheet.getName(),
                "used_rows": cursor.getRangeAddress().EndRow + 1,
                "used_cols": cursor.getRangeAddress().EndColumn + 1,
            })

        print(json.dumps(info))
    finally:
        doc.close(True)


def cmd_export_pdf(filepath, output):
    """Export document to PDF."""
    if not ensure_libreoffice_listening():
        print(json.dumps({"error": "Could not start LibreOffice"}))
        sys.exit(1)

    desktop = connect_uno()
    doc = open_document(desktop, filepath)

    try:
        from com.sun.star.beans import PropertyValue
        props = (PropertyValue(),)
        props[0].Name = "FilterName"
        props[0].Value = "writer_pdf_Export" if not filepath.endswith((".ods", ".xlsx", ".xls", ".csv")) else "calc_pdf_Export"

        abs_output = os.path.abspath(output)
        url = "file://" + abs_output
        doc.storeToURL(url, props)
        print(json.dumps({"exported": abs_output}))
    finally:
        doc.close(True)


def main():
    if len(sys.argv) < 3:
        print(json.dumps({"error": "Usage: lifeos-libreoffice-verify.py <command> <file> [args...]"}))
        sys.exit(1)

    cmd = sys.argv[1]
    filepath = sys.argv[2]

    if cmd == "read-cells" and len(sys.argv) >= 4:
        cmd_read_cells(filepath, sys.argv[3])
    elif cmd == "verify-formula" and len(sys.argv) >= 5:
        cmd_verify_formula(filepath, sys.argv[3], sys.argv[4])
    elif cmd == "check-format" and len(sys.argv) >= 4:
        cmd_check_format(filepath, sys.argv[3], sys.argv[4] if len(sys.argv) >= 5 else "")
    elif cmd == "sheet-info":
        cmd_sheet_info(filepath)
    elif cmd == "export-pdf" and len(sys.argv) >= 4:
        cmd_export_pdf(filepath, sys.argv[3])
    else:
        print(json.dumps({"error": f"Unknown command: {cmd}", "commands": ["read-cells", "verify-formula", "check-format", "sheet-info", "export-pdf"]}))
        sys.exit(1)


if __name__ == "__main__":
    main()
