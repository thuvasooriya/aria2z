const std = @import("std");
const zbh = @import("zig_build_helper");

comptime {
    zbh.checkZigVersion("0.15.2");
}

const BuildOptions = struct {
    bittorrent: bool,
    metalink: bool,
    websocket: bool,
    ssl: bool,
    appletls: bool,
    epoll: bool,
    libssh2: bool,
    sqlite3: bool,
    c_ares: bool,
    zlib: zbh.Dependencies.Mode,
    expat: zbh.Dependencies.Mode,
    zlib_dep: ?*std.Build.Step.Compile,
    c_ares_dep: ?*std.Build.Step.Compile,
    openssl_dep: ?*std.Build.Step.Compile,
    libssh2_dep: ?*std.Build.Step.Compile,
    sqlite3_dep: ?*std.Build.Step.Compile,
    expat_dep: ?*std.Build.Step.Compile,
};

fn validateOptions(options: BuildOptions, platform: zbh.Platform) void {
    if (options.websocket) {
        @panic("-Dwebsocket=true requires wslay wiring, which is not implemented yet.");
    }
    if (options.metalink and options.expat == .none) {
        @panic("-Dmetalink=true requires XML support. Use -Dexpat=linked or -Dexpat=static.");
    }
    if (options.appletls and !platform.is_darwin) {
        @panic("-Dappletls=true is only valid on Darwin targets.");
    }
    if (options.ssl and options.appletls) {
        @panic("-Dssl and -Dappletls are mutually exclusive.");
    }
    if (options.epoll and !platform.is_linux) {
        @panic("-Depoll=true is only valid on Linux targets.");
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const platform = zbh.Platform.detect(target.result);

    // Detect cross-compilation by comparing to host target
    const host = b.graph.host.result;
    const is_cross_compiling = target.result.cpu.arch != host.cpu.arch or
        target.result.os.tag != host.os.tag or
        target.result.abi != host.abi;

    // Dependency options
    const zlib_mode = b.option(zbh.Dependencies.Mode, "zlib", "zlib support: static, linked, none") orelse .static;
    
    // For expat: default to none since it requires system library that may not be installed
    const expat_mode = b.option(zbh.Dependencies.Mode, "expat", "expat support: linked, none") orelse .none;
    
    // c-ares: enabled by default for all platforms
    // For Darwin: use stub DNS (use_macos_sdk=false) to avoid SDK header dependencies
    // Users can force full SDK mode with -Duse_macos_sdk=true if needed
    const c_ares_explicit = b.option(bool, "c-ares", "Enable async DNS support via c-ares. Default: true");
    
    const c_ares_enabled: bool = c_ares_explicit orelse true;
    
    // For Darwin targets: default to stub DNS to avoid SDK header requirements
    // This works for both cross-compile and native builds
    const c_ares_use_macos_sdk: ?bool = if (platform.is_darwin) false else null;

    const zlib_dep = if (zlib_mode == .static) b.lazyDependency("zlib", .{ .target = target, .optimize = optimize }) else null;
    const zlib_lib = if (zlib_dep) |dep| dep.artifact("z") else null;

    // Configure c-ares dependency with appropriate settings
    const c_ares_dep = if (c_ares_enabled) blk: {
        const dep = b.dependency("c_ares", .{
            .target = target,
            .optimize = optimize,
            .shared = false,
            .use_macos_sdk = c_ares_use_macos_sdk,
        });
        break :blk dep;
    } else null;
    const c_ares_lib = if (c_ares_dep) |dep| dep.artifact("cares") else null;

    // Determine SSL mode based on platform and user options
    // SSL requires system libraries which are not available when cross-compiling
    // AppleTLS requires macOS SDK which is not available for most builds
    const ssl_mode_opt = b.option(zbh.Dependencies.Mode, "ssl", "SSL/TLS support: static, linked, none. Default: linked for native Linux, none for cross-compile or Darwin");
    const ssl_mode: zbh.Dependencies.Mode = blk: {
        if (ssl_mode_opt) |m| break :blk m;
        if (is_cross_compiling or platform.is_darwin) break :blk .none;
        break :blk .linked;
    };
    
    const appletls_explicit = b.option(bool, "appletls", "Enable Apple TLS support (macOS only). Default: false (requires macOS SDK)");
    const appletls_enabled = appletls_explicit orelse false;
    
    // SSL enabled if either static or linked mode
    const ssl_enabled = ssl_mode != .none;
    
    // Print warnings when auto-disabling features
    if (ssl_mode == .none and (is_cross_compiling or platform.is_darwin)) {
        if (platform.is_darwin) {
            std.log.warn("Darwin target: auto-disabling SSL. Use -Dssl=linked to force enable (requires OpenSSL) or -Dssl=static for bundled", .{});
        } else {
            std.log.warn("Cross-compiling detected: auto-disabling SSL. Use -Dssl=linked to force enable (requires OpenSSL for target) or -Dssl=static for bundled", .{});
        }
    }
    
    // Warn about Darwin-specific disabled features
    if (c_ares_explicit == null and platform.is_darwin) {
    }

    // Feature flags that affect dependency fetching
    const libssh2_enabled = b.option(bool, "libssh2", "Enable SFTP support via libssh2") orelse false;
    const sqlite3_enabled = b.option(bool, "sqlite3", "Enable Firefox3/Chromium cookie support via sqlite3") orelse false;

    // Fetch dependencies based on options
    const openssl_dep = if (ssl_mode == .static) b.lazyDependency("openssl", .{
        .target = target,
        .optimize = optimize,
    }) else null;
    // allyourcodebase openssl provides a single "openssl" artifact with both ssl and crypto
    const openssl_lib = if (openssl_dep) |dep| dep.artifact("openssl") else null;

    const libssh2_dep = if (libssh2_enabled) b.dependency("libssh2", .{
        .target = target,
        .optimize = optimize,
        .shared = false,
    }) else null;
    const libssh2_lib = if (libssh2_dep) |dep| dep.artifact("ssh2") else null;

    const sqlite3_dep = if (sqlite3_enabled) b.dependency("sqlite3", .{
        .target = target,
        .optimize = optimize,
        .shared = false,
    }) else null;
    const sqlite3_lib = if (sqlite3_dep) |dep| dep.artifact("sqlite3") else null;

    // expat is always fetched for metalink/XML-RPC support
    const expat_dep = b.lazyDependency("libexpat", .{
        .target = target,
        .optimize = optimize,
    });
    const expat_lib = if (expat_dep) |dep| dep.artifact("expat") else null;

    // Options
    const options = BuildOptions{
        .bittorrent = b.option(bool, "bittorrent", "Enable BitTorrent support") orelse true,
        .metalink = b.option(bool, "metalink", "Enable Metalink support") orelse false,
        .websocket = b.option(bool, "websocket", "Enable WebSocket support") orelse false,
        .ssl = ssl_enabled,
        .appletls = appletls_enabled,
        .epoll = b.option(bool, "epoll", "Use epoll (Linux only)") orelse platform.is_linux,
        .libssh2 = libssh2_enabled,
        .sqlite3 = sqlite3_enabled,
        .c_ares = c_ares_enabled,
        .zlib = zlib_mode,
        .expat = expat_mode,
        .zlib_dep = zlib_lib,
        .c_ares_dep = c_ares_lib,
        .openssl_dep = openssl_lib,
        .libssh2_dep = libssh2_lib,
        .sqlite3_dep = sqlite3_lib,
        .expat_dep = expat_lib,
    };

    validateOptions(options, platform);

    const upstream = b.dependency("upstream", .{});

    // Generate Config Header
    const config_h = generateConfigHeader(b, target, platform, options);

    // Create Executable
    const exe = createExecutable(b, target, optimize, upstream, config_h, platform, options);
    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run aria2c");
    run_step.dependOn(&run_cmd.step);

    // CI Step
    const ci_step = b.step("ci", "Build for all CI targets");
    for (zbh.Ci.standard) |ci_target_str| {
        const resolved = zbh.Ci.resolve(b, ci_target_str);
        const ci_platform = zbh.Platform.detect(resolved.result);

        // For CI, disable features that may cause issues
        // SSL/AppleTLS/Expat are auto-disabled by cross-compilation detection
        // We also disable c-ares for Darwin targets due to SDK header issues
        var ci_options = options;
        ci_options.metalink = false;
        ci_options.websocket = false;
        ci_options.libssh2 = false;
        ci_options.libssh2_dep = null;
        ci_options.sqlite3 = false;
        ci_options.sqlite3_dep = null;
        ci_options.epoll = ci_platform.is_linux;
        
        // Explicitly disable SSL and AppleTLS for CI cross-compilation
        ci_options.ssl = false;
        ci_options.openssl_dep = null;
        ci_options.appletls = false;
        
        // Configure c-ares for CI:
        // - Darwin: use stub DNS (use_macos_sdk=false)
        // - Non-Darwin: use c-ares normally
        if (ci_platform.is_darwin) {
            const ci_cares_dep = b.dependency("c_ares", .{
                .target = resolved,
                .optimize = .ReleaseFast,
                .shared = false,
                .use_macos_sdk = false,  // Use stub DNS for Darwin
            });
            ci_options.c_ares = true;
            ci_options.c_ares_dep = ci_cares_dep.artifact("cares");
        } else {
            // Non-Darwin targets: use c-ares normally
            const ci_cares_dep = b.dependency("c_ares", .{
                .target = resolved,
                .optimize = .ReleaseFast,
                .shared = false,
            });
            ci_options.c_ares = true;
            ci_options.c_ares_dep = ci_cares_dep.artifact("cares");
        }

        // Re-resolve zlib for this target
        const ci_zlib_dep = b.lazyDependency("zlib", .{ .target = resolved, .optimize = .ReleaseFast });
        ci_options.zlib_dep = if (ci_zlib_dep) |dep| dep.artifact("z") else null;
        
        // CI builds don't use expat (metalink disabled)
        ci_options.expat = .none;
        ci_options.expat_dep = null;

        // Generate target-specific config.h
        const ci_config_h = generateConfigHeader(b, resolved, ci_platform, ci_options);

        validateOptions(ci_options, ci_platform);

        // CI builds are ReleaseFast by default
        const ci_exe = createExecutable(b, resolved, .ReleaseFast, upstream, ci_config_h, ci_platform, ci_options);

        // We can't install all artifacts to bin/ because they'd overwrite each other
        // So we just depend on the build step to ensure they compile
        ci_step.dependOn(&ci_exe.step);
    }
}

fn createExecutable(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    upstream: *std.Build.Dependency,
    config_h: *std.Build.Step.WriteFile,
    platform: zbh.Platform,
    options: BuildOptions,
) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = "aria2c",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
        }),
    });

    // Include paths
    exe.addIncludePath(config_h.getDirectory());
    exe.addIncludePath(upstream.path("src"));
    exe.addIncludePath(upstream.path("src/includes"));
    exe.addIncludePath(upstream.path("lib"));

    // Add source files
    addSourceFiles(b, exe, upstream, platform, options);

    // Link dependencies
    linkDependencies(exe, platform, options);

    // Platform specific flags
    if (platform.is_darwin) {
        exe.root_module.addCMacro("_DARWIN_C_SOURCE", "1");
    }

    return exe;
}

fn generateConfigHeader(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    platform: zbh.Platform,
    options: BuildOptions,
) *std.Build.Step.WriteFile {
    const config_h = b.addWriteFiles();
    var builder = zbh.Config.HeaderBuilder.init(b.allocator);
    defer builder.deinit();

    // Package Info
    builder.addStr("PACKAGE", "aria2");
    builder.addStr("PACKAGE_NAME", "aria2");
    builder.addStr("PACKAGE_VERSION", "1.37.0");
    builder.addStr("VERSION", "1.37.0");
    builder.addStr("PACKAGE_BUGREPORT", "https://github.com/aria2/aria2/issues");
    builder.addStr("PACKAGE_URL", "https://aria2.github.io/");
    builder.addStr("PACKAGE_STRING", "aria2 1.37.0");
    builder.addStr("PACKAGE_TARNAME", "aria2");
    builder.addStr("BUILD", "zig");

    // Target Triple
    const target_triple = b.fmt("{s}-{s}-{s}", .{
        @tagName(target.result.cpu.arch),
        @tagName(target.result.os.tag),
        @tagName(target.result.abi),
    });
    builder.addStr("TARGET", target_triple);
    builder.addStr("HOST", target_triple);

    // C++ and Logic
    builder.addRaw("CXX11_OVERRIDE", "override");
    builder.define("ARIA2_CONFIG_H");
    builder.define("HAVE_CXX11");

    // Standard/POSIX Headers
    builder.define("HAVE_SYS_STAT_H");
    builder.define("HAVE_STDINT_H");
    builder.define("HAVE_INTTYPES_H");
    builder.define("HAVE_STRING_H");
    builder.define("HAVE_STDLIB_H");
    builder.define("HAVE_MEMORY_H");
    builder.define("STDC_HEADERS");

    if (platform.is_posix) {
        builder.define("HAVE_SOCKET");
        builder.define("HAVE_SOME_FALLOCATE");
        builder.define("HAVE_UTIME");
        builder.define("HAVE_A2_STRUCT_TIMESPEC");

        // Broad POSIX support
        builder.defineAll(&.{ "HAVE_UNISTD_H", "HAVE_SYS_TYPES_H", "HAVE_FCNTL_H", "HAVE_STRINGS_H", "HAVE_PTHREAD", "HAVE_GETTIMEOFDAY", "HAVE_TIMEGM", "HAVE_DAEMON", "HAVE_ASCTIME_R", "HAVE_LOCALTIME_R", "HAVE_STRPTIME", "HAVE_BASENAME", "HAVE_POLL", "HAVE_POLL_H", "HAVE_NETDB_H", "HAVE_SYS_SOCKET_H", "HAVE_NETINET_IN_H", "HAVE_NETINET_TCP_H", "HAVE_ARPA_INET_H", "HAVE_SYS_UIO_H", "HAVE_NANOSLEEP", "HAVE_SLEEP", "HAVE_USLEEP", "HAVE_UTIME_H", "HAVE_ALARM", "HAVE_ALLOCA", "HAVE_ALLOCA_H", "HAVE_ATEXIT", "HAVE_FLOAT_H", "HAVE_FORK", "HAVE_FTRUNCATE", "HAVE_GETCWD", "HAVE_GETHOSTBYADDR", "HAVE_GETHOSTBYNAME", "HAVE_GETIFADDRS", "HAVE_GETPAGESIZE", "HAVE_ICONV", "HAVE_IFADDRS_H", "HAVE_LANGINFO_H", "HAVE_LIMITS_H", "HAVE_LOCALE_H", "HAVE_MEMCHR", "HAVE_MEMMOVE", "HAVE_MEMSET", "HAVE_MKDIR", "HAVE_MMAP", "HAVE_MUNMAP", "HAVE_NL_LANGINFO", "HAVE_POSIX_MEMALIGN", "HAVE_POW", "HAVE_PTRDIFF_T", "HAVE_PUTENV", "HAVE_PWD_H", "HAVE_RMDIR", "HAVE_SELECT", "HAVE_SETLOCALE", "HAVE_STDBOOL_H", "HAVE_STDDEF_H", "HAVE_STDIO_H", "HAVE_STPCPY", "HAVE_STRCASECMP", "HAVE_STRCHR", "HAVE_STRCSPN", "HAVE_STRDUP", "HAVE_STRERROR", "HAVE_STRFTIME", "HAVE_STRNCASECMP", "HAVE_STRSTR", "HAVE_STRTOL", "HAVE_STRTOUL", "HAVE_STRTOULL", "HAVE_SYS_IOCTL_H", "HAVE_SYS_PARAM_H", "HAVE_SYS_RESOURCE_H", "HAVE_SYS_SELECT_H", "HAVE_SYS_TIME_H", "HAVE_SYS_UTSNAME_H", "HAVE_TERMIOS_H", "HAVE_TZSET", "HAVE_UNSETENV", "HAVE_UTIMES", "HAVE_VFORK", "HAVE_VPRINTF", "HAVE_WCHAR_H", "HAVE_WORKING_FORK", "HAVE_WORKING_VFORK", "HAVE_SIGNAL_H", "HAVE_SYS_SIGNAL_H", "HAVE_SIGACTION" });
    }

    // Unix-specific
    if (platform.is_unix) {
        builder.define("HAVE_DLFCN_H");
    }

    // Linux-specific
    if (platform.is_linux) {
        if (options.epoll) builder.define("HAVE_EPOLL_CREATE");
        builder.define("HAVE_FALLOCATE");
        builder.define("HAVE_POSIX_FALLOCATE");
        builder.define("HAVE_GETENTROPY");
    }

    // Windows-specific
    if (platform.is_windows) {
        builder.define("HAVE_WINSOCK2_H");
        builder.define("HAVE_WS2TCPIP_H");
        builder.define("HAVE_WINDOWS_H");
        builder.define("HAVE_A2_STRUCT_TIMESPEC");
        builder.define("HAVE_IO_H");
        builder.define("HAVE_SHARE_H");
        builder.define("HAVE_WINIOCTL_H");
        builder.define("HAVE_SIGNAL_H");
    }

    // BSD/macOS-specific
    if (platform.is_darwin or platform.is_bsd) {
        builder.define("HAVE_KQUEUE");
        builder.define("HAVE_SOCKADDR_IN_SIN_LEN");
    }

    // macOS-specific
    if (platform.is_darwin) {
        builder.define("HAVE_CFLOCALECOPYCURRENT");
        builder.define("HAVE_CFPREFERENCESCOPYAPPVALUE");
        builder.define("HAVE_SOCKADDR_IN6_SIN6_LEN");
    }

    // Libraries
    if (options.zlib != .none) builder.define("HAVE_ZLIB");
    if (options.zlib != .none) builder.define("HAVE_GZBUFFER");
    if (options.zlib != .none) builder.define("HAVE_GZSETPARAMS");
    if (options.expat != .none) builder.define("HAVE_LIBEXPAT");
    if (options.expat != .none) builder.define("HAVE_SOME_XMLLIB");

    // getaddrinfo: Windows has it in ws2tcpip.h, POSIX platforms detect it
    builder.define("HAVE_GETADDRINFO");

    // gai_strerror: Windows SDK version is broken/missing, use custom implementation
    // Only define HAVE_GAI_STRERROR for non-Windows platforms
    if (!platform.is_windows) {
        builder.define("HAVE_GAI_STRERROR");
    }

    // Features
    if (options.ssl) {
        builder.define("HAVE_OPENSSL");
        builder.define("ENABLE_SSL");
        builder.define("USE_OPENSSL_MD");
    } else if (options.appletls) {
        builder.define("HAVE_APPLETLS");
        builder.define("ENABLE_SSL");
        builder.define("USE_APPLE_MD");
    } else {
        builder.define("USE_INTERNAL_MD");
    }

    if (options.c_ares) {
        builder.define("ENABLE_ASYNC_DNS");
        builder.define("HAVE_LIBCARES");
    }

    if (options.bittorrent) {
        builder.define("ENABLE_BITTORRENT");
        // Use internal implementations if no OpenSSL
        if (!options.ssl) {
            builder.define("USE_INTERNAL_BIGNUM");
            builder.define("USE_INTERNAL_ARC4");
        }
    }

    if (options.metalink) builder.define("ENABLE_METALINK");
    if (options.websocket) builder.define("ENABLE_WEBSOCKET");
    if (options.expat != .none) builder.define("ENABLE_XML_RPC"); // Requires XML parser
    if (options.libssh2) {
        builder.define("ENABLE_SFTP");
        builder.define("HAVE_LIBSSH2");
    }
    if (options.sqlite3) {
        builder.define("ENABLE_SQLITE3");
        builder.define("HAVE_SQLITE3");
    }

    // Types
    builder.add("SIZEOF_INT", 4);
    const sizeof_long: usize = if (platform.ptr_width == 64) 8 else 4;
    builder.add("SIZEOF_LONG", sizeof_long);
    builder.add("SIZEOF_OFF_T", 8); // Usually 8 on modern systems
    const sizeof_size_t: usize = if (platform.ptr_width == 64) 8 else 4;
    builder.add("SIZEOF_SIZE_T", sizeof_size_t);

    if (platform.is_big_endian) builder.define("WORDS_BIGENDIAN");

    // Select types (dummy values for modern systems where these are flexible or not macros)
    builder.addRaw("SELECT_TYPE_ARG1", "int");
    builder.addRaw("SELECT_TYPE_ARG234", "(fd_set *)");
    builder.addRaw("SELECT_TYPE_ARG5", "(struct timeval *)");
    builder.define("LSTAT_FOLLOWS_SLASHED_SYMLINK");

    _ = config_h.add("config.h", builder.finish());
    return config_h;
}

fn addSourceFiles(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    upstream: *std.Build.Dependency,
    platform: zbh.Platform,
    options: BuildOptions,
) void {
    // Flags
    var flags = zbh.Flags.Builder.init(b.allocator);
    flags.appendSlice(&.{ "-std=c++11", "-Wall", "-Wextra", "-Wno-deprecated-literal-operator", "-Wno-unused-parameter", "-Wno-vla-extension", "-Wno-date-time", "-Wno-builtin-macro-redefined", "-DHAVE_CONFIG_H" });

    if (platform.is_darwin) {
        flags.appendSlice(&.{ "-Wno-incompatible-library-redeclaration", "-Wno-error" });
        flags.append("-D_DARWIN_C_SOURCE"); // Ensure consistent headers
    }
    if (platform.is_windows) {
        flags.appendSlice(&.{
            "-D_POSIX_C_SOURCE=1",
            "-D__MINGW32__=1",
            "-D_WIN32_WINNT=0x0600",
            "-D__USE_MINGW_ANSI_STDIO=1",
        });
    }

    const cxxflags = flags.items();
    const cflags_strict = &[_][]const u8{"-DHAVE_CONFIG_H"};

    // Core Source Files
    var core_files: std.ArrayList([]const u8) = .empty;
    defer core_files.deinit(b.allocator);

    // Filter out Platform.cc from core files so we can use our patched version
    for (get_core_files()) |f| {
        if (!std.mem.eql(u8, f, "Platform.cc") and !std.mem.eql(u8, f, "SimpleRandomizer.cc")) {
            core_files.append(b.allocator, f) catch @panic("OOM");
        }
    }

    exe.addCSourceFiles(.{
        .root = upstream.path("src"),
        .files = core_files.items,
        .flags = cxxflags,
    });

    // Patched Platform.cc to fix missing ENABLE_SSL guards
    exe.addCSourceFile(.{ .file = b.path("src/patches/Platform.cc"), .flags = cxxflags });
    // Patched SimpleRandomizer.cc to avoid hard Security header requirement on SDK-less Darwin cross builds
    exe.addCSourceFile(.{ .file = b.path("src/patches/SimpleRandomizer.cc"), .flags = cxxflags });

    // Main
    exe.addCSourceFile(.{ .file = upstream.path("src/main.cc"), .flags = cxxflags });
    // C file
    exe.addCSourceFile(.{ .file = upstream.path("src/uri_split.c"), .flags = cflags_strict });
    // Shared parser controller used by JSON/bencode parser state machines
    exe.addCSourceFile(.{ .file = upstream.path("src/XmlRpcRequestParserController.cc"), .flags = cxxflags });

    // Platform specific
    if (platform.is_windows) {
        // gai_strerror.c is REQUIRED for Windows (SDK version is broken)
        exe.addCSourceFile(.{ .file = upstream.path("src/gai_strerror.c"), .flags = cflags_strict });
        // WinConsoleFile for Windows console I/O
        exe.addCSourceFile(.{ .file = upstream.path("src/WinConsoleFile.cc"), .flags = cxxflags });
        // daemon() stub - Windows doesn't have POSIX daemon()
        exe.addCSourceFile(.{ .file = b.path("src/win_daemon_stub.cc"), .flags = cxxflags });
        // Time and string compatibility functions
        exe.addCSourceFiles(.{
            .root = upstream.path("src"),
            .files = &.{
                "gettimeofday.c",
                "asctime_r.c",
                "localtime_r.c",
                "strptime.c",
                "timegm.c",
                "libgen.c",
            },
            .flags = cflags_strict,
        });
    }

    // Event Polling
    if (platform.is_linux and options.epoll) {
        exe.addCSourceFile(.{ .file = upstream.path("src/EpollEventPoll.cc"), .flags = cxxflags });
    } else if (platform.is_darwin or platform.is_bsd) {
        exe.addCSourceFile(.{ .file = upstream.path("src/KqueueEventPoll.cc"), .flags = cxxflags });
    }
    if (platform.is_posix) {
        exe.addCSourceFile(.{ .file = upstream.path("src/PollEventPoll.cc"), .flags = cxxflags });
    }

    // Async DNS (c-ares)
    if (options.c_ares) {
        exe.addCSourceFiles(.{
            .root = upstream.path("src"),
            .files = &.{
                "AsyncNameResolver.cc",
                "AsyncNameResolverMan.cc",
            },
            .flags = cxxflags,
        });
    }

    // SSL/TLS
    if (options.ssl) {
        exe.addCSourceFiles(.{
            .root = upstream.path("src"),
            .files = &.{
                "LibsslTLSContext.cc",    "LibsslTLSSession.cc",        "LibsslARC4Encryptor.cc",
                "LibsslDHKeyExchange.cc", "LibsslMessageDigestImpl.cc",
            },
            .flags = cxxflags,
        });
    } else if (options.appletls) {
        exe.addCSourceFiles(.{
            .root = upstream.path("src"),
            .files = &.{
                "AppleTLSContext.cc", "AppleTLSSession.cc", "AppleMessageDigestImpl.cc",
            },
            .flags = cxxflags,
        });
    } else {
        exe.addCSourceFiles(.{
            .root = upstream.path("src"),
            .files = &.{ "InternalMessageDigestImpl.cc", "crypto_hash.cc" },
            .flags = cxxflags,
        });
    }

    // XML
    if (options.expat != .none) {
        exe.addCSourceFiles(.{
            .root = upstream.path("src"),
            .files = &.{ "XmlAttr.cc", "XmlParser.cc", "ExpatXmlParser.cc" },
            .flags = cxxflags,
        });
    }

    // ZLib
    if (options.zlib != .none) {
        exe.addCSourceFiles(.{
            .root = upstream.path("src"),
            .files = &.{ "GZipDecodingStreamFilter.cc", "GZipEncoder.cc", "GZipFile.cc", "Adler32MessageDigestImpl.cc" },
            .flags = cxxflags,
        });
    }

    // WebSocket
    if (options.websocket) {
        exe.addCSourceFiles(.{
            .root = upstream.path("src"),
            .files = &.{
                "WebSocketInteractionCommand.cc", "WebSocketResponseCommand.cc",
                "WebSocketSession.cc",            "WebSocketSessionMan.cc",
            },
            .flags = cxxflags,
        });
    }

    // XML-RPC
    if (options.expat != .none) {
        exe.addCSourceFiles(.{
            .root = upstream.path("src"),
            .files = &.{ "XmlRpcDiskWriter.cc", "XmlRpcRequestParserStateImpl.cc", "XmlRpcRequestParserStateMachine.cc" },
            .flags = cxxflags,
        });
    }

    // BitTorrent
    if (options.bittorrent) {
        exe.addCSourceFiles(.{
            .root = upstream.path("src"),
            .files = get_bittorrent_files(),
            .flags = cxxflags,
        });
        if (!options.ssl) {
            exe.addCSourceFiles(.{
                .root = upstream.path("src"),
                .files = &.{ "InternalDHKeyExchange.cc", "InternalARC4Encryptor.cc" },
                .flags = cxxflags,
            });
        }
    }

    // Metalink
    if (options.metalink) {
        exe.addCSourceFiles(.{
            .root = upstream.path("src"),
            .files = &.{
                "Metalink2RequestGroup.cc",     "MetalinkEntry.cc",               "Metalinker.cc",
                "MetalinkMetaurl.cc",           "MetalinkParserController.cc",    "MetalinkParserState.cc",
                "MetalinkParserStateImpl.cc",   "MetalinkParserStateMachine.cc",  "MetalinkParserStateV3Impl.cc",
                "MetalinkParserStateV4Impl.cc", "MetalinkPostDownloadHandler.cc", "MetalinkResource.cc",
                "metalink_helper.cc",
            },
            .flags = cxxflags,
        });
    }

    // Platform Compat (missing POSIX)
    if (!platform.is_posix and !platform.is_windows) {
        exe.addCSourceFiles(.{
            .root = upstream.path("src"),
            .files = &.{
                "getaddrinfo.c", "gai_strerror.c", "gettimeofday.c", "asctime_r.c",
                "localtime_r.c", "strptime.c",     "timegm.c",       "daemon.cc",
                "libgen.c",
            },
            .flags = cflags_strict,
        });
    }
}

fn linkDependencies(
    exe: *std.Build.Step.Compile,
    platform: zbh.Platform,
    options: BuildOptions,
) void {
    // Platform Libs
    platform.linkPosixLibs(exe);
    platform.linkWindowsLibs(exe, &.{ "ws2_32", "wsock32", "gdi32", "winmm", "iphlpapi", "psapi" });

    // SSL - static or system linked
    if (options.ssl) {
        if (options.openssl_dep) |ssl_lib| {
            // Static linking: allyourcodebase openssl provides single artifact with both ssl+crypto
            exe.linkLibrary(ssl_lib);
        } else {
            // System linking
            if (platform.is_darwin) {
                exe.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/openssl@3/lib" });
                exe.addIncludePath(.{ .cwd_relative = "/opt/homebrew/opt/openssl@3/include" });
            }
            exe.linkSystemLibrary("ssl");
            exe.linkSystemLibrary("crypto");
        }
    } else if (options.appletls) {
        platform.linkDarwinFrameworks(exe, &.{ "Security", "CoreFoundation" });
    }

    // Common Libs
    zbh.Dependencies.linkStaticOrSystem(exe, options.zlib, options.zlib_dep, "z");
    zbh.Dependencies.linkStaticOrSystem(exe, options.expat, options.expat_dep, "expat");

    if (options.c_ares_dep) |lib| {
        exe.linkLibrary(lib);
    }

    // libssh2 - static linking
    if (options.libssh2_dep) |lib| {
        exe.linkLibrary(lib);
    }

    // sqlite3 - static linking
    if (options.sqlite3_dep) |lib| {
        exe.linkLibrary(lib);
    }
}

fn get_core_files() []const []const u8 {
    return &.{
        "A2STR.cc",                             "AbstractAuthResolver.cc",            "AbstractCommand.cc",                  "AbstractDiskWriter.cc",
        "AbstractHttpServerResponseCommand.cc", "AbstractOptionHandler.cc",           "AbstractProxyRequestCommand.cc",      "AbstractProxyResponseCommand.cc",
        "AbstractSingleDiskAdaptor.cc",         "AdaptiveFileAllocationIterator.cc",  "AdaptiveURISelector.cc",              "AuthConfig.cc",
        "AuthConfigFactory.cc",                 "AutoSaveCommand.cc",                 "BackupIPv4ConnectCommand.cc",         "base32.cc",
        "bitfield.cc",                          "BitfieldMan.cc",                     "BufferedFile.cc",                     "ByteArrayDiskWriter.cc",
        "CheckIntegrityCommand.cc",             "CheckIntegrityDispatcherCommand.cc", "CheckIntegrityEntry.cc",              "Checksum.cc",
        "ChecksumCheckIntegrityEntry.cc",       "ChunkChecksum.cc",                   "ChunkedDecodingStreamFilter.cc",      "ColorizedStream.cc",
        "Command.cc",                           "ConnectCommand.cc",                  "console.cc",                          "ConsoleStatCalc.cc",
        "ContentTypeRequestGroupCriteria.cc",   "Context.cc",                         "ContextAttribute.cc",                 "Cookie.cc",
        "CookieStorage.cc",                     "cookie_helper.cc",                   "CreateRequestCommand.cc",             "CUIDCounter.cc",
        "DefaultAuthResolver.cc",               "DefaultDiskWriter.cc",               "DefaultDiskWriterFactory.cc",         "DefaultPieceStorage.cc",
        "DefaultStreamPieceSelector.cc",        "DirectDiskAdaptor.cc",               "DiskAdaptor.cc",                      "DlAbortEx.cc",
        "DlRetryEx.cc",                         "DNSCache.cc",                        "DownloadCommand.cc",                  "DownloadContext.cc",
        "DownloadEngine.cc",                    "DownloadEngineFactory.cc",           "DownloadFailureException.cc",         "DownloadHandler.cc",
        "DownloadHandlerConstants.cc",          "DownloadResult.cc",                  "download_handlers.cc",                "download_helper.cc",
        "Exception.cc",                         "FatalException.cc",                  "FeatureConfig.cc",                    "FeedbackURISelector.cc",
        "File.cc",                              "FileAllocationCommand.cc",           "FileAllocationDispatcherCommand.cc",  "FileAllocationEntry.cc",
        "FileEntry.cc",                         "FillRequestGroupCommand.cc",         "fmt.cc",                              "FtpConnection.cc",
        "FtpDownloadCommand.cc",                "FtpFinishDownloadCommand.cc",        "FtpInitiateConnectionCommand.cc",     "FtpNegotiationCommand.cc",
        "FtpTunnelRequestCommand.cc",           "FtpTunnelResponseCommand.cc",        "GeomStreamPieceSelector.cc",          "GroupId.cc",
        "GrowSegment.cc",                       "HaveEraseCommand.cc",                "help_tags.cc",                        "HttpConnection.cc",
        "FallocFileAllocationIterator.cc",      "HttpDownloadCommand.cc",             "HttpHeader.cc",                       "HttpHeaderProcessor.cc",
        "HttpInitiateConnectionCommand.cc",     "HttpListenCommand.cc",               "HttpProxyRequestCommand.cc",          "HttpProxyResponseCommand.cc",
        "HttpRequest.cc",                       "HttpRequestCommand.cc",              "HttpResponse.cc",                     "HttpResponseCommand.cc",
        "HttpServer.cc",                        "HttpServerBodyCommand.cc",           "HttpServerCommand.cc",                "HttpServerResponseCommand.cc",
        "HttpSkipResponseCommand.cc",           "InitiateConnectionCommand.cc",       "InitiateConnectionCommandFactory.cc", "InorderStreamPieceSelector.cc",
        "RandomStreamPieceSelector.cc",         "InorderURISelector.cc",              "IOFile.cc",                           "IteratableChecksumValidator.cc",
        "IteratableChunkChecksumValidator.cc",  "json.cc",                            "JsonParser.cc",                       "LogFactory.cc",
        "Logger.cc",                            "LongestSequencePieceSelector.cc",    "MessageDigest.cc",                    "message_digest_helper.cc",
        "MetadataInfo.cc",                      "MetalinkHttpEntry.cc",               "MultiDiskAdaptor.cc",                 "MultiFileAllocationIterator.cc",
        "MultiUrlRequestInfo.cc",               "NameResolver.cc",                    "Netrc.cc",                            "NetrcAuthResolver.cc",
        "NetStat.cc",                           "Notifier.cc",                        "NsCookieParser.cc",                   "NullSinkStreamFilter.cc",
        "Option.cc",                            "OptionHandler.cc",                   "OptionHandlerException.cc",           "OptionHandlerFactory.cc",
        "OptionHandlerImpl.cc",                 "OptionParser.cc",                    "option_processing.cc",                "paramed_string.cc",
        "PeerStat.cc",                          "Piece.cc",                           "PiecedSegment.cc",                    "PieceHashCheckIntegrityEntry.cc",
        "PieceStatMan.cc",                      "Platform.cc",                        "prefs.cc",                            "ProtocolDetector.cc",
        "Range.cc",                             "RarestPieceSelector.cc",             "RealtimeCommand.cc",                  "RecoverableException.cc",
        "Request.cc",                           "RequestGroup.cc",                    "RequestGroupEntry.cc",                "RequestGroupMan.cc",
        "RpcMethod.cc",                         "RpcMethodFactory.cc",                "RpcMethodImpl.cc",                    "RpcRequest.cc",
        "RpcResponse.cc",                       "rpc_helper.cc",                      "SaveSessionCommand.cc",               "SegmentMan.cc",
        "SelectEventPoll.cc",                   "ServerStat.cc",                      "ServerStatMan.cc",                    "SessionSerializer.cc",
        "Signature.cc",                         "SimpleRandomizer.cc",                "SingleFileAllocationIterator.cc",     "SinkStreamFilter.cc",
        "SocketBuffer.cc",                      "SocketCore.cc",                      "SocketRecvBuffer.cc",                 "SpeedCalc.cc",
        "StreamCheckIntegrityEntry.cc",         "StreamFileAllocationEntry.cc",       "StreamFilter.cc",                     "TimeA2.cc",
        "TimeBasedCommand.cc",                  "TimedHaltCommand.cc",                "TimerA2.cc",                          "TorrentAttribute.cc",
        "TransferStat.cc",                      "TruncFileAllocationIterator.cc",     "UnknownLengthPieceStorage.cc",        "UnknownOptionException.cc",
        "uri.cc",                               "UriListParser.cc",                   "URIResult.cc",                        "util.cc",
        "util_security.cc",                     "ValueBase.cc",                       "ValueBaseStructParserStateImpl.cc",   "ValueBaseStructParserStateMachine.cc",
        "version_usage.cc",                     "wallclock.cc",                       "WatchProcessCommand.cc",              "WrDiskCache.cc",
        "WrDiskCacheEntry.cc",                  "OpenedFileCounter.cc",               "SHA1IOFile.cc",                       "EvictSocketPoolCommand.cc",
    };
}

fn get_bittorrent_files() []const []const u8 {
    return &.{
        "AbstractBtMessage.cc",           "ActivePeerConnectionCommand.cc",   "AnnounceList.cc",                     "AnnounceTier.cc",
        "bencode2.cc",                    "BencodeParser.cc",                 "bittorrent_helper.cc",                "BtAbortOutstandingRequestEvent.cc",
        "BtAllowedFastMessage.cc",        "BtAnnounce.cc",                    "BtBitfieldMessage.cc",                "BtBitfieldMessageValidator.cc",
        "BtCancelMessage.cc",             "BtCheckIntegrityEntry.cc",         "BtChokeMessage.cc",                   "BtDependency.cc",
        "BtExtendedMessage.cc",           "BtFileAllocationEntry.cc",         "BtHandshakeMessage.cc",               "BtHandshakeMessageValidator.cc",
        "BtHaveAllMessage.cc",            "BtHaveMessage.cc",                 "BtHaveNoneMessage.cc",                "BtInterestedMessage.cc",
        "BtKeepAliveMessage.cc",          "BtLeecherStateChoke.cc",           "BtNotInterestedMessage.cc",           "BtPieceMessage.cc",
        "BtPieceMessageValidator.cc",     "BtPortMessage.cc",                 "BtPostDownloadHandler.cc",            "BtRegistry.cc",
        "BtRejectMessage.cc",             "BtRequestMessage.cc",              "BtRuntime.cc",                        "BtSeederStateChoke.cc",
        "BtSetup.cc",                     "BtStopDownloadCommand.cc",         "BtSuggestPieceMessage.cc",            "BtUnchokeMessage.cc",
        "DefaultBtAnnounce.cc",           "DefaultBtInteractive.cc",          "DefaultBtMessageDispatcher.cc",       "DefaultBtMessageFactory.cc",
        "DefaultBtMessageReceiver.cc",    "DefaultBtProgressInfoFile.cc",     "DefaultBtRequestFactory.cc",          "DefaultExtensionMessageFactory.cc",
        "DefaultPeerStorage.cc",          "DHTAbstractMessage.cc",            "DHTAbstractTask.cc",                  "DHTAnnouncePeerMessage.cc",
        "DHTAnnouncePeerReplyMessage.cc", "DHTAutoSaveCommand.cc",            "DHTBucket.cc",                        "DHTBucketRefreshCommand.cc",
        "DHTBucketRefreshTask.cc",        "DHTBucketTree.cc",                 "DHTConnectionImpl.cc",                "DHTEntryPointNameResolveCommand.cc",
        "DHTFindNodeMessage.cc",          "DHTFindNodeReplyMessage.cc",       "DHTGetPeersCommand.cc",               "DHTGetPeersMessage.cc",
        "DHTGetPeersReplyMessage.cc",     "DHTInteractionCommand.cc",         "DHTMessage.cc",                       "DHTMessageDispatcherImpl.cc",
        "DHTMessageEntry.cc",             "DHTMessageFactoryImpl.cc",         "DHTMessageReceiver.cc",               "DHTMessageTracker.cc",
        "DHTMessageTrackerEntry.cc",      "DHTNode.cc",                       "DHTNodeLookupEntry.cc",               "DHTNodeLookupTask.cc",
        "DHTNodeLookupTaskCallback.cc",   "DHTPeerAnnounceCommand.cc",        "DHTPeerAnnounceEntry.cc",             "DHTPeerAnnounceStorage.cc",
        "DHTPeerLookupTask.cc",           "DHTPeerLookupTaskCallback.cc",     "DHTPingMessage.cc",                   "DHTPingReplyMessage.cc",
        "DHTPingTask.cc",                 "DHTQueryMessage.cc",               "DHTRegistry.cc",                      "DHTReplaceNodeTask.cc",
        "DHTResponseMessage.cc",          "DHTRoutingTable.cc",               "DHTRoutingTableDeserializer.cc",      "DHTRoutingTableSerializer.cc",
        "DHTSetup.cc",                    "DHTTaskExecutor.cc",               "DHTTaskFactoryImpl.cc",               "DHTTaskQueueImpl.cc",
        "DHTTokenTracker.cc",             "DHTTokenUpdateCommand.cc",         "DHTUnknownMessage.cc",                "ExtensionMessageRegistry.cc",
        "HandshakeExtensionMessage.cc",   "IndexBtMessage.cc",                "IndexBtMessageValidator.cc",          "InitiatorMSEHandshakeCommand.cc",
        "LpdDispatchMessageCommand.cc",   "LpdMessage.cc",                    "LpdMessageDispatcher.cc",             "LpdMessageReceiver.cc",
        "LpdReceiveMessageCommand.cc",    "magnet.cc",                        "MSEHandshake.cc",                     "NameResolveCommand.cc",
        "Peer.cc",                        "PeerAbstractCommand.cc",           "PeerAddrEntry.cc",                    "PeerChokeCommand.cc",
        "PeerConnection.cc",              "PeerInitiateConnectionCommand.cc", "PeerInteractionCommand.cc",           "PeerListenCommand.cc",
        "PeerReceiveHandshakeCommand.cc", "PeerSessionResource.cc",           "PriorityPieceSelector.cc",            "RangeBtMessage.cc",
        "RangeBtMessageValidator.cc",     "ReceiverMSEHandshakeCommand.cc",   "RequestSlot.cc",                      "SeedCheckCommand.cc",
        "ShareRatioSeedCriteria.cc",      "SimpleBtMessage.cc",               "TimeSeedCriteria.cc",                 "TrackerWatcherCommand.cc",
        "UDPTrackerClient.cc",            "UDPTrackerRequest.cc",             "UnionSeedCriteria.cc",                "UTMetadataDataExtensionMessage.cc",
        "UTMetadataExtensionMessage.cc",  "UTMetadataPostDownloadHandler.cc", "UTMetadataRejectExtensionMessage.cc", "UTMetadataRequestExtensionMessage.cc",
        "UTMetadataRequestFactory.cc",    "UTMetadataRequestTracker.cc",      "UTPexExtensionMessage.cc",            "ZeroBtMessage.cc",
    };
}
