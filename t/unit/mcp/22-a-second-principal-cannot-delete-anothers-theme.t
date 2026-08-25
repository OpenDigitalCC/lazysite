#!/usr/bin/perl
# SM575: a theme belongs to the account that created it. THIS IS THE DECISION.
#
# WHY OWNERSHIP IS ENFORCED HERE. delete_theme exists because an agent that may
# create_theme and may not remove the result turns every experiment into litter
# only an operator can clear (SM262 - a zz-guard-theme sat on a live instance
# for exactly that reason). The grant it makes is therefore the NARROWEST thing
# that solves that problem: "tidy up after yourself". Widen it to "tidy up after
# anybody" and the tool stops being a litter fix and becomes a way for one
# partner to delete another partner's design work - a destructive, unrecoverable
# action on an artefact somebody else authored, granted to every holder of
# manage_themes. A theme is authored, singular and not derivable from the rest
# of the site; that is what separates it from the shared stores (a page, a brief
# and a data table are all pieces of ONE site, and t/unit/manager/113,
# t/unit/manager/114 and t/unit/data/26 pin that they stay shared).
#
# `created_by` is deliberately SEPARATE from the descriptive `author` field a
# theme may carry and edit. Conflating a description with an authorisation would
# let a theme rewrite its own permissions, so this test reads created_by off
# disk to prove which field the refusal is keyed on.
#
# WHAT THE FIELD MEASURED (SM570, edge, 2026-08-25): "not created by this
# account". t/unit/manager/57 already proves the module refuses when it is
# HANDED restrict_to_creator. What nothing held until this file is that the
# automated channel actually SETS it - a one-line regression in the MCP tool
# table would have left the module's check perfectly correct and unreachable,
# and the field measurement is of the channel, not of the module.
#
# SABOTAGE-VERIFIED: dropping restrict_to_creator from the delete_theme entry in
# lazysite-mcp.pl, in a scratch copy of the tree, makes the refusal subtest below
# fail - and the two controls after it fall with it, mallory's delete having
# already destroyed the theme they were going to act on.
#
# THE CONTROLS: the creator's own delete must still work (a build that refused
# every delete would otherwise look like a passing ownership test), and the
# refused theme must still be on disk afterwards.
use strict;
use warnings;
use Test::More;
use JSON::PP   qw(encode_json decode_json);
use IPC::Open2 qw(open2);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;

my $root = "$FindBin::Bin/../../..";
my $mcp  = "$root/lazysite-mcp.pl";
my $d    = tempdir( CLEANUP => 1 );

make_path("$d/lazysite/layouts/base/themes/blue/assets");

open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: Demo\nmcp_enabled: true\nlayout: base\ntheme: blue\n";
close $cf;

open my $lt, '>', "$d/lazysite/layouts/base/layout.tt" or die $!;
print {$lt} '<html>[% content %]</html>';
close $lt;
open my $lj, '>', "$d/lazysite/layouts/base/layout.json" or die $!;
print {$lj} encode_json(
    { name => 'base', version => '1.0.0', default_theme => 'blue' } );
close $lj;
open my $bt, '>', "$d/lazysite/layouts/base/themes/blue/theme.json" or die $!;
print {$bt} encode_json(
    { name => 'blue', version => '1.0.0', layouts => ['base'], config => {} } );
close $bt;
open my $bc, '>', "$d/lazysite/layouts/base/themes/blue/assets/main.css" or die $!;
print {$bc} "/* default */\n";
close $bc;

# Both principals hold exactly the same capabilities. That is the point: the
# only thing separating them is who created the theme.
my $stub = "$d/users-stub.pl";
open my $sf, '>', $stub or die $!;
print {$sf} <<'STUB';
#!/usr/bin/perl
use strict; use warnings; use JSON::PP qw(encode_json);
my $in = do { local $/; <STDIN> };
print encode_json({ ok => 1, settings => { mcp => 1, manage_themes => 1 } });
STUB
close $sf;
chmod 0755, $stub;

sub mcp_call {
    my ( $tool, $args, $principal ) = @_;
    my $body = encode_json( { jsonrpc => '2.0', id => 1, method => 'tools/call',
            params => { name => $tool, arguments => $args || {} } } );
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}       = $d;
    $ENV{REQUEST_METHOD}      = 'POST';
    $ENV{CONTENT_LENGTH}      = length $body;
    $ENV{LAZYSITE_USERS_TOOL} = $stub;
    $ENV{HTTP_AUTHORIZATION}  = "Bearer $principal:lzs_tok";
    my ( $out, $in );
    my $pid = open2( $out, $in, $^X, $mcp );
    print {$in} $body;
    close $in;
    my $resp = do { local $/; <$out> };
    close $out;
    waitpid $pid, 0;
    my ($jb) = $resp =~ /\r?\n\r?\n(.*)/s;
    my $r    = ( defined $jb && length $jb ) ? eval { decode_json($jb) } : undef;
    return ( $r && $r->{result} ) ? $r->{result}{structuredContent} : undef;
}

sub theme_dir { return "$d/lazysite/layouts/base/themes/$_[0]" }

subtest 'alice creates a theme, and the store records WHO created it' => sub {
    my $r = mcp_call( 'create_theme',
        { layout => 'base', name => 'alicework', config => {} }, 'alice' );
    ok( $r && $r->{ok},            'create_theme succeeds for alice' ) or diag explain $r;
    ok( -d theme_dir('alicework'), 'the theme is on disk' );

    open my $fh, '<', theme_dir('alicework') . '/theme.json' or die $!;
    my $meta = decode_json( do { local $/; <$fh> } );
    close $fh;
    is( $meta->{created_by}, 'alice',
        'created_by names the creating account - the field the refusal keys on' );
};

subtest 'REFUSED: a second principal may not delete a theme alice created' => sub {
    my $r = mcp_call( 'delete_theme', { theme => 'alicework' }, 'mallory' );
    ok( $r && !$r->{ok}, 'delete_theme is refused for mallory' ) or diag explain $r;
    is( $r->{kind}    // '', 'not-yours', 'reported as not-yours' );
    like( $r->{error} // '', qr/created by this account/i,
        'with the wording the field measured' );
    ok( -d theme_dir('alicework'), 'and the theme survives the attempt' );
};

subtest 'CONTROL: the creator may still remove her own' => sub {
    my $r = mcp_call( 'delete_theme', { theme => 'alicework' }, 'alice' );
    ok( $r && $r->{ok}, 'alice deletes the theme she created' ) or diag explain $r;
    ok( !-d theme_dir('alicework'), 'and it is gone' );
};

subtest 'CONTROL: a theme with no created_by is nobody\'s to delete' => sub {

    # The safe reading of an absent field, asserted on the CHANNEL: an agent
    # gains no authority over anything that existed before it arrived. Without
    # this, a channel that passed the acting user as the creator of everything
    # unowned would still pass the refusal above.
    make_path( theme_dir('inherited') );
    open my $tj, '>', theme_dir('inherited') . '/theme.json' or die $!;
    print {$tj} encode_json(
        { name => 'inherited', version => '1.0.0', layouts => ['base'], config => {} } );
    close $tj;

    for my $who (qw(alice mallory)) {
        my $r = mcp_call( 'delete_theme', { theme => 'inherited' }, $who );
        ok( $r && !$r->{ok}, "$who is refused a theme with no created_by" )
            or diag explain $r;
    }
    ok( -d theme_dir('inherited'), 'the pre-existing theme survives both' );
};

done_testing();
