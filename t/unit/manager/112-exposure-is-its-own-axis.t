#!/usr/bin/perl
# SM587: `destructive` means THE DATA CANNOT BE RECOVERED, assigned by the copy
# test; a SECOND flag means THIS CHANGES WHO CAN SEE THINGS. The operator ruled
# Option A plus a second axis on 2026-08-25, and the whole value of the ruling
# is that both flags are answered by reading the code rather than by arguing
# about consequences.
#
# The case that made the ruling necessary is `acl-remove`: reversible as an
# OBJECT (the rule can be re-set, so no copy is lost) and irreversible as an
# EFFECT (content that was exposed cannot be un-exposed). Under one flag it had
# to be mis-described either way. So this asserts the divergence itself - the
# two actions where the axes disagree, in both directions - rather than the
# whole table, which would be a second copy of the table.
use strict;
use warnings;
use Test::More;
use File::Temp   qw(tempdir);
use File::Path   qw(make_path);
use JSON::PP     qw(encode_json decode_json);
use MIME::Base64 qw(encode_base64);
use IPC::Open2;
use IPC::Open3;
use Symbol qw(gensym);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root grant_caps);

my $root   = repo_root();
my $utool  = "$root/tools/lazysite-users.pl";
my $mapi   = "$root/lazysite-manager-api.pl";
my $secret = 'sekret' x 6;

sub uapi {
    my ( $d, $p ) = @_;
    my ( $o, $i );
    my $pid = open2( $o, $i, $^X, $utool, '--api', '--docroot', $d );
    print $i encode_json($p);
    close $i;
    my $out = do { local $/; <$o> };
    close $o;
    waitpid $pid, 0;
    return eval { decode_json($out) } // { _raw => $out };
}

sub mapi {
    my ( $d, %o ) = @_;
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT} = $d;

    # Pin the user-management tool this CGI shells to - _tool_path() resolves a
    # cgi-bin SIBLING first, which can be a stale copy outside the checkout.
    $ENV{LAZYSITE_USERS_TOOL} = $utool;
    $ENV{REQUEST_METHOD}      = 'GET';
    $ENV{CONTENT_LENGTH}      = 0;
    delete $ENV{HTTP_X_REMOTE_USER};
    for ( keys %o ) { $ENV{$_} = $o{$_} if defined $o{$_} }
    my ( $w, $r );
    my $e   = gensym;
    my $pid = open3( $w, $r, $e, $^X, $mapi );
    close $w;
    my $out = do { local $/; <$r> };
    my $err = do { local $/; <$e> };
    waitpid $pid, 0;
    my ($jb) = $out =~ /\r?\n\r?\n(.*)/s;
    return eval { decode_json( $jb // '' ) } // { _raw => $out, _err => $err };
}

sub basic { 'Basic ' . encode_base64( "$_[0]:$_[1]", '' ) }

my $d = tempdir( CLEANUP => 1 );
make_path("$d/lazysite/auth");
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print $cf "control_api_enabled: true\n";
close $cf;
open my $gsf, '>', "$d/lazysite/auth/groups-settings.json" or die $!;
print $gsf '{"admins":{"label":"Admins","ui":1,"manage_users":1}}';
close $gsf;
open my $sf, '>', "$d/lazysite/auth/.secret" or die $!;
print $sf "$secret\n";
close $sf;

uapi( $d, { action => 'add', username => 'partner', password => 'x' } );
grant_caps( $d, 'partner', 'manage_content', 'api' );
my $tok = uapi( $d, { action => 'token', username => 'partner' } )->{token};
ok( $tok, 'partner has a token' );

# --- 1. the engine says it, over the wire ------------------------------------
# The two axes are published on actions-list beside `mutating`, the way SM572
# publishes the pair. A caller that must ask instead of remember can only do so
# if the answer arrives with the listing.
my $list = mapi( $d,
    QUERY_STRING       => 'action=actions-list',
    HTTP_AUTHORIZATION => basic( 'partner', $tok ) );
ok( $list->{ok}, 'actions-list answers a token client' ) or diag( explain $list );
my %row = map { $_->{action} => $_ } @{ $list->{actions} || [] };

ok( $row{'acl-remove'}, 'acl-remove is in the listing' );
is( ( $row{'acl-remove'} || {} )->{changes_access},
    JSON::PP::true, 'acl-remove CHANGES WHO CAN SEE THINGS' );
ok( !( $row{'acl-remove'} || {} )->{destructive},
    'acl-remove is NOT destructive - the rule can be re-set, so a copy survives' );
is( ( $row{'acl-set'} || {} )->{changes_access},
    JSON::PP::true, 'acl-set carries the exposure flag too - it is one verb, both directions' );

# --- 2. and the other direction ----------------------------------------------
# brief-delete is the mirror case: no copy survives, and nobody's read access
# moves. If one flag ever silently means both, this is where it shows.
my $caps = mapi( $d,
    QUERY_STRING       => 'action=describe-capabilities',
    HTTP_AUTHORIZATION => basic( 'partner', $tok ) );
ok( $caps->{ok}, 'describe-capabilities answers' ) or diag( explain $caps );
my $eff = $caps->{actions} || {};
is( ( $eff->{'brief-delete'} || {} )->{destructive},
    JSON::PP::true, 'brief-delete IS destructive - no copy survives' );
ok( !( $eff->{'brief-delete'} || {} )->{changes_access},
    'brief-delete does NOT change who can see things' );
is( ( $eff->{'acl-remove'} || {} )->{changes_access},
    JSON::PP::true, 'describe-capabilities agrees with actions-list' );

# SM649 REVERSED THIS PAIR, on evidence rather than on argument.
#
# They were flagged on the strength of a comment saying a preview "lets
# somebody read a page". It does not: check_preview() returns { layout, theme }
# and overrides how a page RENDERS. t/integration/52 mints a real preview
# cookie - true HMAC, against the site's own secret - proves it is honoured,
# and then shows it opens NONE of the three gates: `auth: required`, an ACL
# rule, or a draft section. The draft case is the one a preview is most
# plausibly about, and it is refused like the rest.
#
# The direction-blindness this pair was testing is intact and is now tested by
# a pair that really does move the boundary: acl-set and acl-remove, above and
# below. SM647 added domain-set for the same reason - it writes allowed_groups.
#
# Over-flagging is not harmless: it points a reviewer at a door that is not
# there and spends the credibility of the flag, which is part of why
# domain-set's absence went unnoticed while this pair did not.
ok( !( $eff->{'preview-grant'} || {} )->{changes_access},
    'preview-grant moves no read boundary - it overrides layout and theme' );
ok( !( $eff->{'preview-clear'} || {} )->{changes_access},
    'and neither does preview-clear' );
is( ( $eff->{'domain-set'} || {} )->{changes_access},
    JSON::PP::true, 'domain-set DOES - it writes the domain access model' );
ok( !( $eff->{'acl-get'} || {} )->{changes_access},
    'acl-get READS the rule and moves nothing' );

# --- 3. the rule is stated once, where an action is classified ---------------
# The operator's ruling is worth nothing if the next action is classified from
# memory. The tables must carry the two tests in words.
my $api = slurp("$root/lazysite-manager-api.pl");
like( $api, qr/my \%CHANGES_ACCESS = map \{ \$_ => 1 \} qw\(/,
    'the control API declares %CHANGES_ACCESS beside %MUTATING and %DESTRUCTIVE' );
like( $api, qr/does a copy survive/i,
    'the copy test is written down where actions are classified' );
like( $api, qr/who may read/i,
    'the access test is written down beside it' );

# --- 4. the MCP twin says the same thing -------------------------------------
# set_permissions is acl-set's twin (SM431). Two spellings of one fact; t/lint/23
# keeps them equal, and this asserts the fact is spelled on the MCP side at all.
my $mcp = slurp("$root/lazysite-mcp.pl");
like( $mcp, qr/changesAccessHint/,
    'MCP publishes the exposure hint beside its three annotation hints' );
my ($ann) = $mcp =~ /^my \%ANNOTATE = \((.*?)^\);/ms;
ok( $ann, 'the %ANNOTATE table was found' );
like( $ann, qr/^\s*set_permissions\s*=>\s*\[\s*0\s*,\s*0\s*,\s*0\s*,\s*1\s*\]/m,
    'set_permissions is annotated as changing access' );

done_testing();

sub slurp {
    open my $fh, '<', $_[0] or die "$_[0]: $!";
    local $/;
    return <$fh>;
}
