package IgnoreXFSZ;
# Loaded into CHILD CGI processes via PERL5OPT by the write-failure injection
# tests (t/integration/13-write-failure.t). Under RLIMIT_FSIZE (`ulimit -f`),
# a write past the limit raises SIGXFSZ whose default action KILLS the
# process; ignoring it makes the write fail with EFBIG instead - the same
# graceful-failure path a real ENOSPC takes - so the tests exercise the
# checked-write handling rather than process death.
BEGIN { $SIG{XFSZ} = 'IGNORE' }
1;
