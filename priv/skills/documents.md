# Read or produce a real document - pull text and tables out of a PDF, or read and generate a spreadsheet (xlsx), a Word doc (docx), or a slide deck (pptx).

Use this when the task involves an actual office file rather than plain text: someone sends
a PDF to summarize, you need the numbers out of a spreadsheet, or the deliverable is an
`.xlsx`/`.docx`/`.pptx` the user will open in their own tools. Do the work with a short
script (`run_script`, or `bash` after writing a file), and send the result back with
`send_file`.

## The toolbox

These are Python libraries, installed on demand. Follow the `write-a-script` skill for the
`uv` setup if Python is not already available; then add what you need:

- **PDF** - `pypdf` (extract text, split, merge), `pdfplumber` (tables and layout-aware
  text). For a scanned PDF (images, no text layer), it is an OCR job: see the `ocr` skill.
- **Spreadsheet** - `openpyxl` (read/write `.xlsx`, formulas, styles), or `pandas` when you
  are analyzing rather than formatting.
- **Word** - `python-docx`.
- **Slides** - `python-pptx`.

## Reading

Extract, then work on the text. Do not paste a whole document into your reply; pull out
what the task needs.

```python
# PDF text
from pypdf import PdfReader
text = "\n".join(page.extract_text() or "" for page in PdfReader("in.pdf").pages)

# PDF tables (better for financials, invoices)
import pdfplumber
with pdfplumber.open("in.pdf") as pdf:
    rows = pdf.pages[0].extract_table()

# Spreadsheet
import openpyxl
ws = openpyxl.load_workbook("in.xlsx", data_only=True).active
data = [[c.value for c in row] for row in ws.iter_rows()]
```

A large PDF is a lot of tokens. Extract to a file, read the slice you need with `read_file`,
and summarize rather than carrying the whole thing in context.

## Producing

Write the file into the agent's workspace, then hand it over:

```python
import openpyxl
wb = openpyxl.Workbook(); ws = wb.active
ws.append(["Month", "Leads"]); ws.append(["June", 128])
wb.save("report.xlsx")
```

Then `send_file` the path so the user gets the actual file, not a wall of text. Generate the
format the user asked for; do not hand back CSV when they wanted an `.xlsx` they can open.

## Notes

- If a document holds a credential or personal data, treat it as sensitive: do not echo it
  into the chat, and remember tool output is written to the trace.
- Keep intermediates in the workspace `tmp/` so they do not clutter the user's files.
