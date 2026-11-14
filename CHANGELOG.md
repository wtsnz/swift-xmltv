# Changelog

## 0.1.0, unreleased

The first release.

- `XMLTVDocument` parses whole guides on every core.
- `XMLTVReader` reads one record at a time from a file or `Data`.
- `XMLTVItems` decodes an async sequence of byte chunks.
- Every element and attribute in the XMLTV DTD is decoded.
- Channel and time-window filters skip programmes without decoding them.
- Lenient and strict error policies. Lenient mode reports every recovery as a diagnostic.
- Input may be UTF-8, UTF-16, ISO-8859-1, ISO-8859-15 or Windows-1252, gzip-compressed or not.
