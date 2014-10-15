gchunt
======

gchunt is a tool is to help D developers identify and keep in check usage of GC in their projects.

## How it works

gchunt transforms a stream of GC usage warnings of a D compiler to a nice wiki table. This relies on 2.066 D frontend feature to print [GC allocation points](http://dlang.org/changelog.html#vgc-switch).

For a given project build log, a wiki-table is generated, with columns containing:
    * module name
    * artifact name (as in `someClass.someMethod.innerFunction`)
    * set of source-links to the exact lines of that specific revision
    * reasons for GC allocation
    * a place for user comments (solutions)

Currently source-links are generated to github source browser, but it's readily hackable to support any other code hosting.

See [wiki page](https://github.com/DmitryOlshansky/gchunt/wiki) for example output.

```sh
# Add `-vgc` flag to your build command
# Example for rdmd:
rdmd --build-only -vgc mymain.d > out.vgc

# you might want to check that it does contain 
# lines with vgc messages (i.e. the flag was properly set)
grep -c vgc out.vgc # count all 'vgc' words

# Then run gchunt on compiler's log
<path-to>/gchunt < out.vgc > report.wiki

# report.wiki contains table copy-pastable to any Wiki enigne
# with MediaWiki syntax support (e.g. GitHub)
```


## Building

gchunt uses D's de-facto standard [dub](http://code.dlang.org/about) build tool (and package manager).

Once dub is installed, the build is as simple as:
```sh
# if all goes well should produce 'gchunt', a standalone binary
dub build -b plain
```

Installation is as simple copying it to some directory in your `PATH`.

P.S. gchunt for now is tested for now only on Linux/x86_64, though it should  compile and work just fine under any OS with recent D compiler.
