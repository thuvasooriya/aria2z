// win_daemon_stub.c - Windows daemon() stub
// Windows doesn't have POSIX daemon() - this provides a minimal stub
// that returns success. Windows services work differently.
#ifdef _WIN32

namespace aria2 {

// Stub implementation of daemon() for Windows
// Returns 0 (success) - aria2 will run in foreground on Windows
int daemon(int nochdir, int noclose) {
    (void)nochdir;  // Unused on Windows
    (void)noclose;  // Unused on Windows
    return 0;       // Success (no forking on Windows)
}

} // namespace aria2

#endif // _WIN32
