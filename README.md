# HTTP Server

An HTTP server written in Zig for serving static files and simple templates as well as basic custom functionality using `handlers`.
All files (static files, templates) are embedded into the executable at compile time.

### How it works
Everything under the `www` is either embedded or compiled into the executable.
Files are interpreted in three different ways: HTTP handlers, Templates and Static Files.
- HTTP Handlers are files which end in `.zig` and contain zig function definitions for handling HTTP Requests on certain paths. The functions are named `http_<method>` where the method can be any of the HTTP methods with all capital letters.
- Templates are files which end in `.template` and contain 'variables' which can be replaced in HTTP handlers. These files are intended to be used by the handlers only and are not exposed publicly.
- Static files are all the other files. These are loaded and served as is.

Routing is done based on the file structure under `www`. Let's say you have the following files under `www`:
- www/
    - about.zig
    - index.zig
    - favicon.ico
    - home/
        - index.zig
        - index.html.template

`about.zig` -> is a handler, the code in it will be compiled and will be called when the path `/about` is requested
`index.zig` -> is the same as `about.zig` except that it will be exposed on two paths: `/index` and `/`
`favicon.ico` -> is a static file, it will be embedded into the executable and exposed on the path `/favicon.ico`
`home/index.zig` -> is that as `index.zig` except that the paths for it will be `/home` and `/home/index`
`home/index.html.template` -> is a template, it will be ignored by the routing. The intended use for it is to be included by `home/index.zig` using `@embedFile("index.html.template")` and used as a template

### Dependencies
- Zig 0.14 for building
- Openssl was used for handling https (linked to as a system library). On debian you can install using `sudo apt install libssl-dev`.

### Simple Usage
The easiest way to use the server is to clone the repository and modify the contents of `example_www` directory.
- Clone the repository and checkout to 1.0 branch
```
git clone --single-branch --branch 1.0 https://github.com/LouisAlbanZiko/http_server.git
```
- Modify the files under `example_www`
- Build and run the project
```
zig build run
```

### Separate Project
To import into your own Zig project you will need to first add the server as a dependency in the `build.zig.zon`.
I would suggest adding the server as a git submodule and importing it like so:
```
.dependencies = .{
    .http_server = .{
        .path = "<path to submodule>",
    },
},
```

Then create a `www` directory where you will add static files, Zig handlers and templates.
Next you will need to update your `build.zig` script and pass the correct options to it:
```
const target = b.standardTargetOptions(.{});
const optimize = b.standardOptimizeOption(.{});

const http_server = b.dependency("http_server", .{
    .target = target,
    .optimize = optimize,
    .web_dir = b.path("www"),
    .exe_name = "<name of executable>",
});
b.getInstallStep().dependOn(http_server.builder.getInstallStep());
```

The server comes with an executable artifact which you can use:
```
const exe = http_server.artifact(exe_name);
b.installArtifact(exe);

const run_exe = b.addRunArtifact(exe);

const run_step = b.step("run", "Run the application");
run_step.dependOn(&run_exe.step);
```

Try to build and run the project:
```
zig build run
```

If everything is setup correctly and you have added at least one file to the `www` directory you should be able to open it on the browser.

### Plans for 2.0
I plan to add certain features to the server and release it as a 2.0 version:
- WebSockets
- SMTP
- Database support (probably Sqlite)
- Builtin Sessions and Users

However, I want to take a break from this project and come back to it at a later time.

