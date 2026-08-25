#!/usr/bin/perl
# SM573: a partner's brief named seven capabilities; whoami answered
# seventeen.
#
# The brief is how a grant is COMMUNICATED, and its capability block was a
# hand-written list of seven pushes. A brief that OVERSTATES costs a refusal; a
# brief that UNDERSTATES hands out authority nobody wrote down - the partner
# holds manage_users without being told, and the operator believes the list
# they read.
#
# The block is derived from @CAP_KEYS now, so the assertion is not "these seven
# appear" - which is the bug restated - but that the brief and the ACCOUNT agree
# about every capability, in both directions.
use strict;
use warnings;
use Test::More;
use JSON::PP   qw(encode_json decode_json);
use IPC::Open2 qw(open2);
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper               qw(repo_root grant_caps);
use Lazysite::Auth::Settings qw(@CAP_KEYS);

my $utool = repo_root() . '/tools/lazysite-users.pl';
plan skip_all => "no $utool" unless -f $utool;

sub uapi {
    my ( $d, $p ) = @_;
    my ( $o, $i );
    my $pid = open2( $o, $i, $^X, $utool, '--api', '--docroot', $d );
    print $i encode_json($p);
    close $i;
    my $out = do { local $/; <$o> };
    close $o;
    waitpid $pid, 0;
    return eval { decode_json($out) } // {};
}

my $d = tempdir( CLEANUP => 1 );
make_path("$d/lazysite/auth");
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: T\n";
close $cf;

uapi( $d, { action => 'add', username => 'partner', password => 'partner-pw-0123456789' } );

# A grant deliberately WIDER than the seven the old list could describe, and
# reaching capabilities that list had no line for at all.
grant_caps( $d, 'partner', qw(webdav manage_content manage_themes manage_data
        manage_users manage_domains read_submissions audit api) );

my $eff = uapi( $d, { action => 'settings-get', username => 'partner' } )->{settings} || {};
my $brief = uapi( $d, { action => 'onboarding', username => 'partner' } )->{onboarding};
ok( length( $brief // '' ), 'the brief was generated' ) or do { done_testing(); exit };

# The machine-readable block: `capabilities:` followed by `  - name` lines.
my ($block) = $brief =~ /^capabilities:\n((?:[ ]+-[ ]\S+\n)+)/m;
ok( $block, 'the brief carries a machine-readable capability block' )
    or diag( substr( $brief, 0, 400 ) );
# Parenthesised and matched FIRST: `sort ($x) =~ //g` parses as sort($x)
# and then matches against its result, which is how this quietly returned
# nothing while the block itself matched fine.
my @found  = ( $block // '' ) =~ /-\s+(\S+)/g;
my @stated = sort @found;

# What the ACCOUNT actually holds - from @CAP_KEYS, the same list whoami
# answers from. Taking every truthy SETTINGS key instead would sweep in
# dav_scopes, groups, top_level and scope_ceiling, which are not capabilities:
# the test would then demand the brief state things that are not grants.
my @held = sort grep {
    $eff->{$_} && !/\A(?:ui|api|mcp)\z/    # channels, not authority
} @CAP_KEYS;

is_deeply( \@stated, \@held,
    'the brief states exactly the capabilities the account holds' )
    or diag("brief: @stated\nheld:  @held");

# The direction that mattered: nothing held is left unsaid.
for my $c (qw(manage_data manage_users manage_domains read_submissions audit)) {
    ok( ( grep { $_ eq $c } @stated ),
        "$c is named in the brief - the old hand-list had no line for it" );
}

# And the prose list is not shorter than the truth either.
like( $brief, qr/manage_users/, 'a capability with no curated sentence is still named' );

done_testing();
