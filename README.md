# aria2z

aria2 download utility with Zig build system and full cross-compilation support.

## About

This is [aria2](https://aria2.github.io) packaged for the Zig build system with support for:
- BitTorrent, Metalink, WebSocket
- SSL/TLS (OpenSSL)
- SFTP (via libssh2)
- Async DNS (via c-ares)
- Cookie storage (via sqlite3)

## Build

```bash
# Native build
zig build

# Cross-compilation
zig build -Dtarget=x86_64-linux-gnu
zig build -Dtarget=aarch64-linux-gnu
zig build -Dtarget=x86_64-macos
zig build -Dtarget=aarch64-macos
zig build -Dtarget=x86_64-windows-gnu
zig build -Dtarget=aarch64-windows-gnu
```

## Dependencies

- zig-build-helper
- c-ares
- zlib (via allyourcodebase)
- openssl (via allyourcodebase)
- libssh2 (via allyourcodebase)
- sqlite3 (via allyourcodebase)
- libexpat (via allyourcodebase)

## License

The Zig build code is MIT licensed. The upstream aria2 uses GPL2.
