#!/usr/bin/perl
# SM288: the same account, in the same group, gets the same read decision on
# every channel.
#
# Before this, it did not. WebDAV resolved the account's real groups, so an
# @group ACL matched a partner; MCP hard-set the group list to empty; and the
# control-API token path read X-Remote-Groups, which a token client structurally
# cannot send. One account, one group, one file, one ACL - allowed over WebDAV
# and refused over MCP.
#
# The operator found it by reading a summary and saying "partners do have
# groups". No test had ever asked the same question twice on two channels, which
# is exactly the gap: each channel was tested against itself.
#
# So this test is deliberately shaped as a MATRIX, not three tests. It asks one
# question - may this partner read this file - on every channel that can answer,
# and asserts they agree. Then it removes the group and asserts they agree
# again, because "allowed everywhere" is only half of consistent.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use JSON::PP   qw(encode_json decode_json);
use IPC::Open2;
use MIME::Base64 ();
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root setup_dav_site grant_caps);

my $root = repo_root();

sub spit {
    my ( $p, $t ) = @_;
    open my $fh, '>', $p or die "$p: $!";
    print {$fh} $t;
    close $fh;
    return;
}

# A REAL user store, not a stub: WebDAV verifies the password against it, so the
# three channels have to authenticate for real or the matrix compares nothing.
my $site = setup_dav_site( user => 'partner', password => 'secret' );
my $d    = $site->{docroot};
make_path( "$d/content/gated", "$d/lazysite/manager/locks" );

# The site must be SECURED - some group has to grant manager access - or the
# control API refuses every token client with a bootstrap message and the whole
# channel answers "no" for a reason that has nothing to do with groups.
grant_caps( $d, 'boss', qw(ui manage_users) );

# Both token channels are off by default and refuse before they ever look at a
# credential, so without these the control API answers "no" for a reason that
# has nothing to do with the question being asked.
open my $cf, '>>', "$d/lazysite/lazysite.conf" or die $!;
print {$cf} "mcp_enabled: true\ncontrol_api_enabled: true\n";
close $cf;

spit( "$d/content/gated/secret.md", "---\ntitle: S\n---\nGATEDBYTES\n" );
spit( "$d/lazysite/auth/acls.json", '{"content/gated":{"read":["@editors"]}}' );

# The group file is the ONE place membership lives, and every channel must reach
# this same fact. Rewrites ONLY the lines this test owns: grant_caps put the
# role-* groups that carry the capabilities in the same file, and replacing it
# wholesale would silently strip the partner's right to use any channel at all.
sub set_groups {
    my (@lines) = @_;
    my $f = "$d/lazysite/auth/groups";
    my @keep;
    if ( open my $fh, '<', $f ) {
        @keep = grep { !/\A\s*(?:editors|staff)\s*:/ } <$fh>;
        close $fh;
    }
    chomp @keep;
    spit( $f, join( "\n", @keep, @lines ) . "\n" );
    return;
}

# The users tool is stubbed for capabilities only - the stub says nothing about
# groups, which is the point: group membership must come from the store, not
# from whatever a channel happens to be handed.
my $stub = "$d/users-stub.pl";
spit( $stub, <<'STUB' );
#!/usr/bin/perl
use strict; use warnings; use JSON::PP qw(encode_json decode_json);
my $in = do { local $/; <STDIN> };
my $r  = eval { decode_json($in) } || {};
print encode_json({ ok => 1, settings => {
    webdav => 1, manage_content => 1, mcp => 1, api => 1,
} });
STUB
chmod 0755, $stub;

# --- the three channels, each asked the same question ------------------------

sub via_dav {
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}           = $d;
    $ENV{SCRIPT_NAME}             = '/dav';
    $ENV{REMOTE_ADDR}             = '127.0.0.1';
    $ENV{LAZYSITE_DAV_FAIL_DELAY} = 0;
    $ENV{LAZYSITE_USERS_TOOL}     = $stub;
    $ENV{HTTP_AUTHORIZATION}
        = 'Basic ' . MIME::Base64::encode_base64( 'partner:secret', '' );
    $ENV{REQUEST_METHOD} = 'GET';
    $ENV{PATH_INFO}      = '/content/gated/secret.md';
    $ENV{CONTENT_LENGTH} = 0;
    my $out = `\Q$^X\E \Q$root/lazysite-dav.pl\E </dev/null 2>/dev/null`;
    return ( defined $out && $out =~ /GATEDBYTES/ ) ? 1 : 0;
}

sub via_mcp {
    my $body = encode_json(
        { jsonrpc => '2.0',
            id     => 1,
            method => 'tools/call',
            params => {
                name      => 'read_file',
                arguments => { path => '/content/gated/secret.md' },
            },
        }
    );
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}       = $d;
    $ENV{REQUEST_METHOD}      = 'POST';
    $ENV{CONTENT_LENGTH}      = length $body;
    $ENV{LAZYSITE_USERS_TOOL} = $stub;
    $ENV{HTTP_AUTHORIZATION}  = 'Bearer partner:lzs_x';
    my ( $out, $in );
    my $pid = open2( $out, $in, $^X, "$root/lazysite-mcp.pl" );
    print {$in} $body;
    close $in;
    my $resp = do { local $/; <$out> };
    close $out;
    waitpid $pid, 0;
    return ( defined $resp && $resp =~ /GATEDBYTES/ ) ? 1 : 0;
}

# THE CONTROL API IS NOT IN THIS MATRIX, and that is a finding rather than a
# gap in the test. Its token surface has no action that makes a per-file READ
# decision: `read` and `file-download` both answer "served only to the manager
# UI over a cookie session". A token client can SET an ACL there (acl-set) and
# cannot read the content it just governed - it has to change channel, to MCP or
# WebDAV, to exercise the grant it wrote.
#
# So the read matrix is the two channels that can answer a read, which are
# exactly the two that used to disagree. The control API's half of SM288 - that
# it resolves a token client's groups from the account rather than from a header
# a token cannot send - is pinned at source by t/lint/35, because there is no
# behaviour here to drive.
#
# Recorded for [[SM289]]: "the same method from every surface" has a bigger hole
# than the two names it was filed about.
my %CHANNEL = ( WebDAV => \&via_dav, MCP => \&via_mcp );

# --- in the group: every channel serves it -----------------------------------
subtest 'a partner IN @editors is served on every channel' => sub {
    set_groups("editors: partner");
    for my $name ( sort keys %CHANNEL ) {
        ok( $CHANNEL{$name}->(),
            "$name: the \@editors entry matches the partner" );
    }
};

# --- out of the group: every channel refuses ---------------------------------
# The control that makes the subtest above mean something. Without it, a channel
# that ignores ACLs entirely would pass the first half and look consistent.
subtest 'removing the group refuses it on every channel' => sub {
    set_groups("editors: someone-else");
    for my $name ( sort keys %CHANNEL ) {
        ok( !$CHANNEL{$name}->(),
            "$name: no longer in \@editors, so no longer served" );
    }
};

# --- a named partner is unaffected -------------------------------------------
# Naming the account directly was the documented workaround while @group did not
# work for partners. It must keep working, on all three, or the fix has traded
# one inconsistency for another.
subtest 'naming the partner directly still works on every channel' => sub {
    set_groups("editors: someone-else");
    spit( "$d/lazysite/auth/acls.json",
        '{"content/gated":{"read":["partner"]}}' );
    for my $name ( sort keys %CHANNEL ) {
        ok( $CHANNEL{$name}->(), "$name: named in the read list, so served" );
    }
    spit( "$d/lazysite/auth/acls.json",
        '{"content/gated":{"read":["@editors"]}}' );
};

# --- nested groups resolve the same way everywhere ---------------------------
# effective_groups closes membership upward over sub-groups, so a partner in a
# group that is itself a member of @editors is in @editors. Asserted because the
# three channels used to reach group membership by three different routes, and
# only one of them expanded anything.
subtest 'a nested group is honoured on every channel' => sub {
    set_groups( "editors: staff", "staff: partner" );
    for my $name ( sort keys %CHANNEL ) {
        ok( $CHANNEL{$name}->(),
            "$name: partner is in \@staff, which is in \@editors" );
    }
};

done_testing();
