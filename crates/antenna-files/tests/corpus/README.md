# Corpus of dangerous files for the receive pipeline (SPEC §15)

The files here are **inert data** for the `tests/corpus.rs` tests. They are never opened outside the sandbox worker;
the tests hand them only to `Checker` (the worker under Landlock + seccomp + rlimits).

## What is in the repository

| Directory | Source | License | What it is |
| --- | --- | --- | --- |
| `pdfjs/` | Mozilla pdf.js test PDFs: `https://github.com/mozilla/pdf.js/tree/ef62f31f2486d7cf2c3854b2db4520b9ca389b2f/test/pdfs` (downloaded 2026-10-02; Q-F-4) | Apache-2.0 (`pdfjs/pdf.js.LICENSE` is the LICENSE of the pdf.js repository) | 6 files: `doc_actions.pdf` (JavaScript in document actions), `evaljs.pdf` (JavaScript `eval`), `attachment.pdf` (embedded file), `encrypted-attachment.pdf` (encrypted PDF with an attachment), `helloworld-bad.pdf` (damaged structure), `bomb_giant.pdf` (giant page size); no live payload |
| `pngsuite/` | PngSuite, Willem van Schaik: http://www.schaik.com/pngsuite/PngSuite-2017jul19.tgz (archive SHA-256 `0294b244c95a8342c01b00010cf34abdcabc7c6a34fd0fe1bd963917537bfdc8`, downloaded 2026-10-02) | "Permission to use, copy, modify and distribute these images for any purpose and without fee is hereby granted" (`pngsuite/PngSuite.LICENSE`) | 14 deliberately corrupted PNGs (`x*.png`: broken signature, wrong CRCs, color type 1 and 9, bit depth 0/3/99, no IDAT, inserted CR/LF) and 2 valid ones as controls (`basn2c08.png`, `basn6a08.png`) |

## What the tests generate (never written to the repository)

`tests/common/samples.rs`: EICAR (assembled from parts so the source is not a "virus" to developers' antivirus
software), a compression ratio ZIP bomb (150 MiB of zeros), a ZIP with overlapping entries (the Fifield scheme), a gzip
bomb (200 MiB of zeros), a ZIP with `../` and with a symlink pointing outside, a tar with `../`, a symlink, a hard link
and a device, a nested ZIP, polyglots (PNG+ZIP, PDF+ZIP, GIF+HTML, JPEG with `%PDF-` in the header), a 30000×30000 PNG
with a tiny IDAT (decompression bomb), a PNG with an instruction in a text chunk, a JPEG with EXIF "coordinates", a PDF
with `/JavaScript`+`/OpenAction` and with `/Launch`, an ELF named `.pdf`, a downloader script, a DOCX with
`vbaProject.bin`, an SVG with `onload`, files with keys, tokens and a seed phrase.

## What is not here and why

Public **exploit** PNGs/PDFs (live CVE samples from MalwareBazaar, VirusShare and the like) are not included: the
sources are not verified, and live exploits cannot be stored in the repository without a separate maintainer decision.
Protection against them does not depend on a specific CVE: files are parsed only by pure Rust decoders (`image`,
`hayro`) in an isolated worker, and what comes out is pixels and text, not a file in the format. Following Q-F-4, the
pdf.js test PDFs (Apache-2.0, `pdfjs/`) were added: scripts, attachments, encryption, damage, a page size "bomb"
(`tests/corpus.rs::pdfjs_test_pdfs_…`). The PDFBox set (Apache-2.0) is the next candidate.

## File SHA-256

```
c90e86090a625661b19960cafdde6e347d6e32d73837aaae533f66dd3f099506  basn2c08.png
559c594166eb156f461c9beff0f053196730dc998fdb0d2b801c89e6680860a5  basn6a08.png
4059f7e6a1c5bac1801f70e09f9ec1e1297dcdce34055c13ab2703d6d9613c7e  xc1n0g08.png
e252a0e7df3e794e52ce4a831edafef76e7043d0d8d84019db0f7fd0b30e20f4  xc9n2c08.png
3c0c2a68dd416a7be79400e0e2ceb358ba3191d5309d4bad9dd04b32ff6d5b60  xcrn0g04.png
71e4b2826f61556eda39f3a93c8769b14d3ac90f135177b9373061199dbef39a  xcsn0g01.png
c1287690808e809dc5d4fb89d8a7fd69ed93521f290abd42021ca00a061a1ba4  xd0n2c08.png
00b53c3bbd0641454521b982bc6f6bcfda7c91f1874cefb3a9bac37d80a1a269  xd3n2c08.png
16e5b40fb2600db1af20fb79ff715c2869255e2d4bef20702f16534e5dd6a847  xd9n2c08.png
f9d1fb2a708703518368c392c74765a6e3e5b49dbb9717df3974452291032df9  xdtn0g01.png
318864720c8fc0dbe4884035f2183cc3bd3d92ec60d447879982942600e9fe2e  xhdn0g08.png
968fd21abb8acf40fbca90676de3abcb3a6e35b01ba7a3b9190184eafb99c83d  xlfn0g04.png
776701227c7094dd10b78f508430b8ea4f03471d072096382cbcca628dea1d2b  xs1n0g01.png
9dd7e93ba9211f0caee09d8f12e37742936c469f45fcad21e577c9f0640cf99e  xs2n0g01.png
166c8633d116d1c26631cb98f3a75340cf4385fa7ae6a67913bc78e709bcb30d  xs4n0g01.png
7a380568beeac969908196ac89cd2347c96ac2f26fdc2b8e0314b62c59f0e308  xs7n0g01.png
```

`pdfjs/` (SHA-256):

```
9acec9f83f1557183c83a87111b85141e657849ac2aa92864ffd63cc91572379  attachment.pdf
a33bc9ff49df11644e5790add536df87b702684b729999539df32ae655fd6dd1  bomb_giant.pdf
828e5ca11cff202835d25f2b04db460b5434b8196a007b152ac206bedf23310d  doc_actions.pdf
0f44da5152adf8cafcd7b0057d840310d78e17d033ee5414da0881b6dcd130ab  encrypted-attachment.pdf
dad709ec8c7197fee70bcf053dcf8609d4f05e1830c96c4af51c85e83957c995  evaljs.pdf
c3e22ea5d7e6f5b7218d76abce4284728889df516a93c1b74a82c4fd69aa1639  helloworld-bad.pdf
```
