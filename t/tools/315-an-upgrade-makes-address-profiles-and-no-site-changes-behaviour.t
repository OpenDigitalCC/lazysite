#!/usr/bin/perl
# SM1345 (0.16.5, A-4 of the release manager's request of 24 October 2026): THE
# UPGRADE TURNS EACH ADDRESS LIST INTO A PROFILE, AND NO SITE CHANGES BEHAVIOUR.
#
# A site as 0.16.4 left it - auth/address-lists.json holding an allow list and a
# deny list, each with its kind, named by a page, a folder rule, a group, the
# manager's and sign-in's keys and an Odoo binding - is upgraded in place by the
# real install.pl. Then:
#
#   - the profile store holds the same names and entries, with no kind, and the
#     old file is kept beside it as address-lists.json.converted
#   - every use keeps its effect: the same requests get the same answers from the
#     one module every gate asks (decide), before and after, for the page, the
#     allow list on a folder rule, the deny list used in a group, the manager and
#     sign-in keys, and the binding's membership test; no rule was rewritten
#   - the summary says what was converted; the once-step is recorded; a second
#     run converts nothing and says nothing
#   - ruling 105 (SM1345): the old template calls visitor.in_list / visitor.in_any in the site's
#     pages, a layout and the private store become visitor.in_profile /
#     visitor.in_any_profile, each file reported, other text untouched; lazysite
#     check finds none left
#   - ruling 106: after the upgrade lazysite check names a hand-edited rule whose
#     slot was not its list's kind, from the kept address-lists.json.converted
#   - a profile store already there is never overwritten (told, both kept); an old
#     store that does not decode is left where it is, so the engine keeps refusing
#     (unconverted), the summary warns, and the step is not recorded
#
# Sabotage: with the conversion taken out of install.pl, the profile store is never
# written and every rule naming a profile refuses (store-fault) - this fails.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use JSON::PP   qw(decode_json encode_json);
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_manifest_guard repo_root);

# old-address-name: begin (SM1343, the test builds a site as it was before the rename)

my $MF_GUARD = repo_manifest_guard();
my $ROOT     = repo_root();
my $INSTALL  = "$ROOT/install.pl";

sub spit  { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
sub slurp { my ($p) = @_; open my $fh, '<', $p or return undef; local $/; my $t = <$fh>; close $fh; return $t }

sub new_site {
    my $dir = tempdir( 'lazysite-1345-XXXXXX', TMPDIR => 1, CLEANUP => 1 );
    make_path( "$dir/site", "$dir/cgi-bin" );
    return ( "$dir/site", "$dir/cgi-bin" );
}

# As t/tools/03 runs it: no lib on @INC (SM767), the mode declared, the fixture's
# own group as the serving group (SM933).
sub install {
    my ( $docroot, $cgibin, $mode ) = @_;
    local $ENV{PERL5LIB};
    delete $ENV{PERL5LIB};
    my @args = ( '--docroot', $docroot, '--cgibin', $cgibin, '--mode', $mode,
        '--serving-group', ( getgrgid( $) + 0 ) // ( $) + 0 ) ) );
    my $cmd = join ' ', map {quotemeta} $^X, $INSTALL, @args;
    my $out = `$cmd 2>&1`;
    return ( $? >> 8, $out );
}

my ( $IN, $SCANNER, $OUT ) = ( '203.0.113.5', '203.0.113.66', '198.51.100.9' );

# The 0.16.4 store: an allow list and a deny list, each with its kind.
my $LISTS = {
    office  => { kind => 'allow', created_by => 'op', updated_by => 'op', updated => 1760000000,
        entries => [ { cidr => '203.0.113.0/24', note => 'HQ' }, { cidr => '2001:db8:1::/48', note => 'v6' } ] },
    blocked => { kind => 'deny', entries => [ { cidr => '203.0.113.66', note => 'scanner' } ] },
};

# Every place a rule names a list, each in the slot its kind meant (the saves
# refused the other, SM1189): the page, the allow list on a folder rule, the deny
# list in a group, the manager's and sign-in's keys, and a binding's membership.
sub uses {
    my ( $docroot, $lz ) = @_;
    spit( "$docroot/staff.md", "---\ntitle: Staff\naddresses: [office]\naddresses_deny: [blocked]\n---\nStaff.\n" );
    spit( "$lz/auth/acls.json", encode_json( { 'intranet/' => { owner => 'op', addresses => ['office'] } } ) );
    my $gs = decode_json( slurp("$lz/auth/groups-settings.json") // '{}' );
    $gs->{'g-ed'} = { label => 'Editors', manage_content => 1, addresses_deny => ['blocked'] };
    spit( "$lz/auth/groups-settings.json", encode_json($gs) );
    chmod 0660, "$lz/auth/acls.json", "$lz/auth/groups-settings.json";    # as the users tool writes them
    spit( "$lz/lazysite.conf", slurp("$lz/lazysite.conf")
            . "manager_addresses: office\nmanager_addresses_deny: blocked\nsignin_addresses_deny: blocked\n" );
    return;
}

# What the gates answer: each use, for an office address, the scanner inside the
# office range and an outside address, through the one module (decide / in_profile).
sub answers {
    my ($lz) = @_;
    my $q = <<'PERL';
use strict; use warnings; use JSON::PP;
use Lazysite::Auth::AddressProfiles ();
$Lazysite::Auth::AddressProfiles::AUTH_DIR = shift;
my %use = ( page => [ ['office'], ['blocked'] ], folder => [ ['office'], [] ], group => [ [], ['blocked'] ],
    manager => [ ['office'], ['blocked'] ], signin => [ [], ['blocked'] ] );
my %r;
for my $u ( sort keys %use ) {
    for my $a (@ARGV) {
        my ($v) = Lazysite::Auth::AddressProfiles::decide( $a, allow => $use{$u}[0], deny => $use{$u}[1] );
        $r{"$u $a"} = $v;
    }
}
$r{"binding $_"} = Lazysite::Auth::AddressProfiles::in_profile( $_, 'office' ) ? 'inside' : 'outside' for @ARGV;
print JSON::PP->new->canonical->encode( \%r );
PERL
    my $cmd = join ' ', map {quotemeta} $^X, "-I$ROOT/lib", '-e', $q, "$lz/auth", $IN, $SCANNER, $OUT;
    my $out = `$cmd 2>/dev/null`;
    return eval { decode_json($out) } || { _raw => $out };
}

# The answers 0.16.4 gave, by the rules it applied (an allow list admits only its
# addresses, a deny list refuses its own, deny wins). Written out, not computed, so
# the module cannot agree with itself.
my %BEFORE = (
    "page $IN" => 'allow', "page $SCANNER" => 'deny', "page $OUT" => 'deny',
    "folder $IN" => 'allow', "folder $SCANNER" => 'allow', "folder $OUT" => 'deny',
    "group $IN" => 'allow', "group $SCANNER" => 'deny', "group $OUT" => 'allow',
    "manager $IN" => 'allow', "manager $SCANNER" => 'deny', "manager $OUT" => 'deny',
    "signin $IN" => 'allow', "signin $SCANNER" => 'deny', "signin $OUT" => 'allow',
    "binding $IN" => 'inside', "binding $SCANNER" => 'inside', "binding $OUT" => 'outside',
);

my ( $docroot, $cgibin ) = new_site();
my ( $rc, $out ) = install( $docroot, $cgibin, 'provision' );
is( $rc, 0, 'the site is provisioned' ) or diag $out;
my $lz   = "$docroot/lazysite";
my $old  = "$lz/auth/address-lists.json";
my $new  = "$lz/auth/address-profiles.json";
my $sp   = "$lz/.install-state.json";
my $done = sub { ( slurp($sp) // '' ) =~ /"address-profiles-converted"/ };
ok( $done->(), 'a new site records the step as done (it has no lists)' );

# Make it a 0.16.4 site: the lists, their uses, and the step not yet done.
spit( $old, encode_json($LISTS) );
chmod 0660, $old;
uses( $docroot, $lz );
spit( $sp, slurp($sp) =~ s/"address-profiles-converted",?//r =~ s/,(\s*\])/$1/r );
# Ruling 105: the template test under its old names, where TT runs for a site.
my $priv = "$docroot-lazysite-private";
make_path( "$lz/layouts/house", "$priv/staff" );
my %TPL = (
    "$docroot/notices.md" => "---\ntitle: N\n---\n[% IF visitor.in_list('office') %]rota[% END %] in_list stays\n",
    "$lz/layouts/house/layout.tt" => "<p>[% IF visitor.in_any(['office','vpn']) %]staff[% END %] [% visitor.in_any_profile(['x']) %]</p>\n",
    "$priv/staff/desk.md" => "---\ntitle: D\n---\n[%- IF visitor.in_list( 'office' ) -%]desk[% END %]\n",
);
spit( $_, $TPL{$_} ) for keys %TPL;
# Ruling 106: a rule made by hand in the slot its list's kind did not mean.
spit( "$docroot/odd.md", "---\ntitle: O\naddresses_deny: [office]\n---\nOdd.\n" );

my %rules_before = map { $_ => slurp($_) } ( "$docroot/staff.md", "$lz/auth/acls.json", "$lz/auth/groups-settings.json" );

( $rc, $out ) = install( $docroot, $cgibin, 'reinstall' );
is( $rc, 0, 'the upgrade succeeds' ) or diag $out;

subtest 'each list is a profile with the same name and entries, and no kind' => sub {
    my $p = decode_json( slurp($new) // '{}' );
    is_deeply( [ sort keys %$p ], [qw(blocked office)], 'the same names' );
    for my $n (qw(office blocked)) {
        is_deeply( $p->{$n}{entries}, $LISTS->{$n}{entries}, "$n: the same entries, with their notes" );
        ok( !exists $p->{$n}{kind}, "$n: no kind" );
    }
    is( $p->{office}{created_by}, 'op', 'who made it is kept' );
    is( $p->{office}{updated}, 1760000000, 'and when it last changed' );
    is( sprintf( '%04o', ( stat $new )[2] & 07777 ), '0660', 'the profile store has the old file\'s mode' );
    ok( !-e $old, 'the old store is not left where the engine would read it as unconverted' );
    is_deeply( decode_json( slurp("$old.converted") // '{}' ), $LISTS, 'it is kept beside, as it was' );
};

subtest 'every use keeps its effect, and no rule was rewritten' => sub {
    is_deeply( answers($lz), \%BEFORE, 'the page, folder, group, manager, sign-in and binding answer as before' );
    is( slurp($_), $rules_before{$_}, "$_ is as it was" ) for sort keys %rules_before;
    like( slurp("$lz/lazysite.conf"), qr/^manager_addresses: office\nmanager_addresses_deny: blocked\nsignin_addresses_deny: blocked$/m,
        'and so are the lazysite.conf keys' );
};

subtest 'ruling 105: the template calls take the new names, each file reported' => sub {
    like( slurp("$docroot/notices.md"), qr/\[% IF visitor\.in_profile\('office'\) %\]rota\[% END %\] in_list stays/,
        'a page body: the call is renamed and other text is not' );
    like( slurp("$lz/layouts/house/layout.tt"), qr/visitor\.in_any_profile\(\['office','vpn'\]\).*visitor\.in_any_profile\(\['x'\]\)/,
        'a layout: in_any is renamed and a call already new is left as it was' );
    like( slurp("$priv/staff/desk.md"), qr/visitor\.in_profile\( 'office' \)/, 'the private store too' );
    for my $f ( "notices.md", "lazysite/layouts/house/layout.tt", "staff/desk.md" ) {
        like( $out, qr/template: +renamed \d+ address test call\(s\) in \S*\Q$f\E to visitor\.in_profile/, "reported: $f" );
    }
    my $check = `\Q$^X\E -I\Q$ROOT/lib\E \Q$ROOT/tools/lazysite-check.pl\E --docroot \Q$docroot\E 2>&1`;
    unlike( $check, qr/names from before 0\.16\.5/, 'lazysite check finds no old call left' );
};

subtest 'ruling 106: the check names a rule whose slot was not its list\'s kind' => sub {
    my $check = `\Q$^X\E -I\Q$ROOT/lib\E \Q$ROOT/tools/lazysite-check.pl\E --docroot \Q$docroot\E 2>&1`;
    like( $check, qr/office \(an allow list before 0\.16\.5\) is denied by page odd\.md/, 'the hand-edited rule is named' );
    unlike( $check, qr/is (?:allowed|denied) by page staff\.md/, 'and the rules in their old slots are not' );
};

subtest 'the summary says so; the step is recorded; a second run does nothing' => sub {
    like( $out, qr/converted 2 address list\(s\) to address profiles of the same names: blocked \(was deny\), office \(was allow\); every rule keeps its effect \(SM1345\)/,
        'the summary names each list and the kind its uses keep' );
    ok( $done->(), 'the step is recorded' );
    spit( $sp, slurp($sp) =~ s/"address-profiles-converted",?//r =~ s/,(\s*\])/$1/r );
    my $store = slurp($new);
    my ( $rc2, $out2 ) = install( $docroot, $cgibin, 'reinstall' );
    is( $rc2, 0, 'a second run succeeds' ) or diag $out2;
    is( slurp($new), $store, 'and leaves the profiles as they were' );
    unlike( $out2, qr/address list\(s\) to address profiles|ADDRESS PROFILES|template: /, 'with nothing to report' );
    ok( $done->(), 'and records the step' );
};

subtest 'a profile store already there is never overwritten' => sub {
    spit( $new, '{"office":{"entries":[{"cidr":"192.0.2.1","note":"kept"}]}}' );
    spit( $old, encode_json($LISTS) );
    chmod 0660, $new, $old;
    spit( $sp, slurp($sp) =~ s/"address-profiles-converted",?//r =~ s/,(\s*\])/$1/r );
    my ( $rc3, $out3 ) = install( $docroot, $cgibin, 'reinstall' );
    is( $rc3, 0, 'the run succeeds' ) or diag $out3;
    like( slurp($new), qr/"kept"/, 'the profiles are untouched' );
    ok( -e $old, 'the lists are left for the operator' );
    like( $out3, qr/ADDRESS PROFILES: both .*address-lists\.json and .*address-profiles\.json exist/, 'and the summary says both are there' );
    unlink $old;
};

subtest 'an old store that does not decode is left, and the engine keeps refusing' => sub {
    unlink $new;
    spit( $old, '{ "office": { "kind": "allow", "entries": [' );
    chmod 0660, $old;
    spit( $sp, slurp($sp) =~ s/"address-profiles-converted",?//r =~ s/,(\s*\])/$1/r );
    my ( $rc4, $out4 ) = install( $docroot, $cgibin, 'reinstall' );
    like( $out4, qr/ADDRESS PROFILES: .*address-lists\.json does not decode as a JSON object, so it was not converted/,
        'the summary warns' );
    ok( !-e $new, 'no profile store was made up' );
    ok( -e $old, 'the old file is where it was' );
    ok( !$done->(), 'and the step is not recorded, so the next upgrade tries again' );
    my $a = answers($lz);
    is( $a->{"group $OUT"}, 'deny', 'a rule denying a profile refuses every address (fails closed, unconverted)' );
    is( $a->{"page $IN"}, 'deny', 'and so does one allowing it' );
};

# old-address-name: end

done_testing();
