# Get the text out of an image or a scanned PDF - a photographed receipt, a screenshot, a contract someone scanned, a document with no selectable text.

Use this when the content is *pixels, not text*: a customer sends a photo of an invoice, a
user uploads a scan, or a PDF's `extract_text` came back empty because it is really a stack
of images. (For a PDF that already has a text layer, use the `documents` skill instead - it
is faster and exact.)

## First: can you just look at it?

If your model is vision-capable and the image is already in the conversation, you may simply
read it directly and transcribe or answer from it - no tools needed. That is the best path
for a single photo where the user wants an answer, not a text file. Reach for the OCR tools
below when you need machine-readable text at scale, from many pages, or from a file that is
not already in context.

## Tools

Installed on demand (see `write-a-script` for the `uv`/Python setup):

- **`ocrmypdf`** - the right tool for a scanned PDF: it adds a searchable text layer, after
  which the `documents` skill reads it normally.
  ```bash
  ocrmypdf in.pdf out.pdf        # then extract text from out.pdf
  ocrmypdf -l por in.pdf out.pdf # a non-English document: pass the language
  ```
- **`tesseract`** (via `pytesseract`) - for a single image.
  ```python
  import pytesseract
  from PIL import Image
  text = pytesseract.image_to_string(Image.open("receipt.jpg"), lang="por+eng")
  ```

Both need the Tesseract engine and its language packs installed (`tesseract-ocr` plus e.g.
`tesseract-ocr-por` for Portuguese on Debian/Ubuntu, `brew install tesseract tesseract-lang`
on macOS). Install the language the document is actually in - OCR in the wrong language is
worse than none.

## Getting good text

- **Say the language.** A Portuguese receipt read as English is garbage; pass `-l por` /
  `lang="por"`.
- **Straighten and clean first** if the scan is skewed or noisy - `ocrmypdf` has
  `--deskew --clean`, which noticeably improves accuracy.
- **Trust nothing blindly.** OCR misreads `0`/`O`, `1`/`l`, and decimal points in money.
  When a number matters (a total, an account, a date), sanity-check it and, if it drives an
  action, confirm with the user rather than acting on a possible misread.
