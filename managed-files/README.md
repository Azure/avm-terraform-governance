# Managed Files

This directory is used to keep core files updated.

Within any named parent directory under `root`, `<parent>/_all/<suffix>` is synchronized as `<parent>/<child>/<suffix>` for every existing immediate child directory. The `_all` directory itself is not copied, while `root/_all` remains a literal path.
