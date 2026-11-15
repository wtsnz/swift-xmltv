# Test fixtures

The files named `upstream_*` come from the test data of the XMLTV project,
<https://github.com/XMLTV/xmltv>, in its `t/data` directory. They are licensed under the GNU
General Public License, version 2, like the rest of that project; see its `COPYING` file. They
are used here unchanged, as test input, and are not part of the library: apps that depend on
swift-xmltv do not build or ship them.

| File here | Upstream file |
|---|---|
| `upstream_<name>.xml` | `t/data/<name>.xml` |
| `upstream_test.xml.gz` | `t/data/test.xml`, compressed with gzip |
| `upstream_all_UTF8.expected` | `t/data/tv_cat_all_UTF8.expected` |

The other fixtures were written for this package and are under its MIT license.
