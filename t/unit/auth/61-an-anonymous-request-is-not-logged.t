#!/usr/bin/perl
# SM1099: an anonymous request does not fill the web server's error log.
#
# The release manager, 2026-10-16: the Apache error log "filled with hundreds
# of MB of" `[INFO] [auth] [/] auth: no cookie`. Every request passes through
# lazysite-auth.pl, whose log lines go to stderr - the web server's error log.
# It logged one INFO line per signed-out request, and one per signed-in request
# ("cookie valid"), and it never read log_level from lazysite.conf, so a site
# could not turn it down.
#
# What this holds, driving the real wrapper as a CGI request:
#
# - at the default level a signed-out request logs nothing to stderr
# - log_level: DEBUG in lazysite.conf brings the line back, so the wrapper reads
#   the site's level (the processor always did)
# - LAZYSITE_LOG_LEVEL still wins over the conf, as in the processor
use strict;
use warnings;
use Test::More;
use IPC::Open3 qw(open3);
use Symbol     qw(gensym);
use File::Temp ();
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root env_passthrough site_tempdir);

my $root = repo_root();
my $auth = "$root/lazysite-auth.pl";

my $stubdir = File::Temp->newdir;
my $stub    = "$stubdir/stub.pl";
open my $stf, '>', $stub or die $!;
print {$stf} "#!/usr/bin/perl\nprint \"Status: 200 OK\\r\\nContent-Type: text/plain\\r\\n\\r\\nok\\n\";\n";
close $stf;

sub site {
    my ($conf) = @_;
    my $d = site_tempdir();
    mkdir "$d/lazysite";
    mkdir "$d/lazysite/auth";
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$cf} "site_name: T\n$conf";
    close $cf;
    return $d;
}

sub anon_get {
    my ( $d, %env ) = @_;
    local %ENV = (
        env_passthrough(),
        DOCUMENT_ROOT      => $d,
        REDIRECT_URL       => '/',
        REQUEST_METHOD     => 'GET',
        QUERY_STRING       => '',
        REMOTE_ADDR        => '127.0.0.1',
        HTTPS              => '',
        LAZYSITE_PROCESSOR => $stub,
        %env,
    );
    my ( $wtr, $rdr );
    my $err = gensym;
    my $pid = open3( $wtr, $rdr, $err, $^X, $auth );
    close $wtr;
    my $out  = do { local $/; <$rdr> };
    my $eout = do { local $/; <$err> };
    waitpid $pid, 0;
    return { out => $out // '', err => $eout // '' };
}

subtest 'a signed-out request at the default level logs nothing' => sub {
    my $r = anon_get( site('') );
    like $r->{out}, qr/^ok$/m, 'the page is served';
    unlike $r->{err}, qr/auth: no cookie/, 'no per-request line on stderr';
};

subtest 'the site log_level is honoured' => sub {
    my $r = anon_get( site("log_level: DEBUG\n") );
    like $r->{err}, qr/\[DEBUG\] \[auth\] \[\/\] auth: no cookie/,
        'log_level: DEBUG in lazysite.conf brings the line back';
};

subtest 'the env override wins over the conf' => sub {
    my $r = anon_get( site("log_level: DEBUG\n"), LAZYSITE_LOG_LEVEL => 'WARN' );
    unlike $r->{err}, qr/auth: no cookie/, 'LAZYSITE_LOG_LEVEL=WARN silences it';
};

done_testing;
