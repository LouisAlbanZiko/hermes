# HTTP Server

An http server written in zig for serving static files and simple templates.

### How it works
Everything under the `www` is either embedded or compiled into the executable.
Files are interpreted in three different ways: HTTP handlers, Templates and Static Files.
- HTTP Handlers are files which end in `.zig` and contain zig function definitions for handling HTTP Requests on certain paths. The functions are named `http_<method>` where the method can be any of the HTTP methods with all capital letters.
- Templates are files which end in `.template` and contain 'variables' which can be replaced in HTTP handlers. These files are intended to be used by the handlers only and are not exposed publicly.
- Static files are all the other files. These are loaded and served as is.

The paths where these files are exposed is the path relative to the `www` directory. For example: if you have a file at `www/dir/test.txt` that file will be served at `/dir/test.txt`.
The exception to this is HTTP Handlers which are exposed at the path without the extension: `www/dir/test.zig` => `/dir/test`.

### Dependencies
- Zig (>=0.14) for building
- Sqlite was used as a database (included in the project)
- Openssl was used for handling https (linked to as a system library)

### Building
If you have zig installed simply run `zig build` to build and/or `zig build run` to run the server.
There must be a `www` directory present, otherwise a compile error will be thrown.

