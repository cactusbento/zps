# zps

Just set the `PKGSRCLOC` environment variable to the `NetBSD/pkgsrc` repository on your
local drive.

```bash
# There are 3 Commands:
zps search [terms...]
zps install [package names...]
zps uninstall [package names...]
```

`zps search` currently only filters the packages by checking if the package name or description
contains one of the search terms.

## TODO

* Implement a better way to store repository info. 
* Read/Store package versions.
* Shell completions.
* Add option flags.
