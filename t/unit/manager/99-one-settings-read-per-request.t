#!/usr/bin/perl
# SM516 MO-1: ONE read of the account store per request.
#
# _user_caps() forks tools/lazysite-users.pl and reads the account store, and
# the cookie path asked it twice for an ordinary request: once at the gate
# ahead of dispatch, and again at the action's own gate. whoami asked three
# times. Nothing writes the store before a read of it in the same request -
# action_users' own gate runs before its write, every other reader is a gate
# ahead of dispatch - so the second and third answers could never differ from
# the first.
#
# Counted rather than reasoned about, because the property is invisible in the
# response: two forks and one fork return the same JSON, and the only way to
# tell them apart from outside is to watch the tool being run. The stub here
# records each request and then hands it to the real tool, so the behaviour
# under test is the real one and only the count is instrumented.
use strict;
use warnings;
use Test::More;
use JSON::PP   qw(encode_json decode_json);
use IPC::Open2 qw(open2);
use IPC::Open3 qw(open3);
use Symbol     qw(gensym);
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root grant_caps);

my $root   = repo_root();
my $utool  = "$root/tools/lazysite-users.pl";
my $mapi   = "$root/lazysite-manager-api.pl";
my $secret = 'sekret' x 6;

my $d   = tempdir( CLEANUP => 1 );
my $log = "$d/tool-calls.log";

sub uapi {
    my ($p) = @_;
    my ( $o, $i );
    my $pid = open2( $o, $i, $^X, $utool, '--api', '--docroot', $d );
    print $i encode_json($p);
    close $i;
    my $out = do { local $/; <$o> };
    close $o;
    waitpid $pid, 0;
    return eval { decode_json($out) } // {};
}

# A pass-through that records the sub-action and then runs the real tool, so
# what the manager API talks to behaves exactly as the shipped one does.
my $stub = "$d/users-counting-stub.pl";
{
    open my $fh, '>', $stub or die $!;
    print {$fh} <<"STUB";
#!/usr/bin/perl
use strict;
use warnings;
my \$in = do { local \$/; <STDIN> };
my (\$a) = \$in =~ /"action"\\s*:\\s*"([^"]+)"/;
open my \$lg, '>>', '$log' or die \$!;
print {\$lg} ( \$a // '?' ), "\\n";
close \$lg;
open my \$p, '|-', \$^X, '$utool', \@ARGV or die \$!;
print {\$p} \$in;
close \$p;
exit( \$? >> 8 );
STUB
    close $fh;
    chmod 0755, $stub;
}

sub calls {
    return () unless -f $log;
    open my $fh, '<', $log or die $!;
    my @l = <$fh>;
    close $fh;
    chomp @l;
    return @l;
}

sub reset_log { unlink $log; return }

sub mapi {
    my (%o) = @_;
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}       = $d;
    $ENV{REQUEST_METHOD}      = 'GET';
    $ENV{CONTENT_LENGTH}      = 0;
    $ENV{LAZYSITE_USERS_TOOL} = $stub;
    delete $ENV{HTTP_X_REMOTE_USER};
    delete $ENV{HTTP_X_REMOTE_GROUPS};
    $ENV{$_} = $o{$_} for grep { defined $o{$_} } keys %o;
    # The auth wrapper sets X-Remote-* and LAZYSITE_AUTH_TRUSTED together, or
    # the trust gate correctly strips the header as forged.
    $ENV{LAZYSITE_AUTH_TRUSTED} = 1 if length( $ENV{HTTP_X_REMOTE_USER} // '' );
    my ( $w, $r );
    my $e   = gensym;
    my $pid = open3( $w, $r, $e, $^X, $mapi );
    close $w;
    my $out = do { local $/; <$r> };
    close $r;
    waitpid $pid, 0;
    my ($jb) = $out =~ /\r?\n\r?\n(.*)/s;
    return eval { decode_json( $jb // '' ) } // { _raw => $out };
}

make_path( "$d/lazysite/auth", "$d/lazysite/logs" );
{
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$cf} "site_name: Test\nlayout: base\ntheme: live\n";
    close $cf;
    open my $sf, '>', "$d/lazysite/auth/.secret" or die $!;
    print {$sf} $secret;
    close $sf;
    open my $pg, '>', "$d/about.md" or die $!;
    print {$pg} "# About\n";
    close $pg;
}

# An operator, so the site counts as SECURED (which is what puts the carve-out
# gate in play), and an ordinary editor, who is the caller under test.
uapi( { action => 'add', username => 'op', password => 'x' } );
grant_caps( $d, 'op', 'manage_users', 'manage_config' );
uapi( { action => 'add', username => 'ed', password => 'y' } );
grant_caps( $d, 'ed', 'manage_content', 'notifications' );

# --- the bell: the gate ahead of dispatch, then the action's own gate -------
{
    reset_log();
    my $r = mapi(
        QUERY_STRING         => 'action=notices',
        HTTP_X_REMOTE_USER   => 'ed',
        HTTP_X_REMOTE_GROUPS => 'ed'
    );
    ok( $r->{ok}, 'notices is served to an account holding notifications' )
        or diag explain $r;
    my @got = grep { $_ eq 'settings-get' } calls();
    is( scalar @got, 1,
        'action=notices reads the account store ONCE, not once per gate' )
        or diag( 'tool calls: ' . join( ', ', calls() ) );
}

# --- a content read: the same gate, then the SM268 H4 carve-out gate --------
{
    reset_log();
    my $r = mapi(
        QUERY_STRING         => 'action=read&path=about.md',
        HTTP_X_REMOTE_USER   => 'ed',
        HTTP_X_REMOTE_GROUPS => 'ed'
    );
    ok( $r->{ok}, 'read is served to an account holding manage_content' )
        or diag explain $r;
    my @got = grep { $_ eq 'settings-get' } calls();
    is( scalar @got, 1,
        'action=read reads the account store ONCE, not once per gate' )
        or diag( 'tool calls: ' . join( ', ', calls() ) );
}

# --- and the answer is still the account's, not an empty default -----------
# A memo that returned {} would make every count above 1 and every gate pass
# by accident, so pin that a capability the account LACKS is still refused.
{
    reset_log();
    my $r = mapi(
        QUERY_STRING         => 'action=config-read',
        HTTP_X_REMOTE_USER   => 'ed',
        HTTP_X_REMOTE_GROUPS => 'ed'
    );
    ok( !$r->{ok}, 'config-read is still refused without manage_config' );
    like( $r->{error} // '', qr/permission/i, 'and says which permission' );
}

done_testing();
