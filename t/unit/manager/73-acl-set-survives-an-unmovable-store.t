#!/usr/bin/perl
# SM296: a move that cannot happen must WARN, not kill the request.
#
# Reported by a site agent on a 0.10.8 host, from outside, over both surfaces: setting
# a permission on any path that HOLDS CONTENT returned MCP -32603 "Tool error"
# or HTTP 500. A path with nothing behind it succeeded - the case that does not
# matter. The discriminator was whether _sync_private_store had anything to move.
#
# WHAT THE SITE WAS LEFT LIKE, and why this is the serious kind of bug: the ACL
# is saved BEFORE the move, so the rule was stored and honoured for pages while
# the content stayed in the document root and went on being served
# byte-identically to anonymous requests. That is SM283's exposure, reached
# through the mechanism built to make it structurally impossible. The audit line
# was never written either - the process died first - so the trail and the stored
# ACL disagreed about whether anyone had protected that content.
#
# THE CAUSE was one line. `make_path($parent) unless -d $parent` reads as though
# failure comes back as a false return; File::Path::make_path CROAKS. So the
# guard on the next line - "cannot create the private store" - was unreachable,
# and the die went straight out through action_acl_set.
#
# The documented contract already covered this exact case:
#
#   "A failed move does not refuse the rule. The ACL is stored and the engine
#    honours it, so the site is no worse off than before the store existed - but
#    the response says so, because both outcomes look identical to the operator
#    otherwise."
#
# The warning text existed and was good. It simply could not be reached. So this
# file asserts the REPORTED SYMPTOM (no crash) and the CONTRACT (the warning
# arrives, the rule stands, the content is untouched) together - the fix is only
# correct if all of those hold at once.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Manager::Files  qw(action_acl_set action_acl_remove);
use Lazysite::Manager::Common ();
use Lazysite::Auth::Acl       qw(load_acls);
use Lazysite::Private         qw(private_root private_path);

my $base = tempdir( CLEANUP => 1 );
my $d    = "$base/public_html";
make_path("$d/lazysite/auth");

sub spit {
    my ( $p, $t ) = @_;
    make_path( $p =~ s{/[^/]+\z}{}r );
    open my $fh, '>', $p or die "$p: $!";
    print {$fh} $t;
    close $fh;
    return;
}
sub slurp {
    my ($p) = @_;
    open my $fh, '<', $p or return '';
    local $/;
    return <$fh>;
}

spit( "$d/lazysite/lazysite.conf", "site_name: T\n" );
spit( "$d/members/secret.md",      "SECRETBYTES\n" );
spit( "$d/members/plan.pdf",       "PDFBYTES\n" );

$Lazysite::Manager::Files::DOCROOT  = $d;
$Lazysite::Manager::Common::DOCROOT = $d;
$Lazysite::Auth::Acl::DOCROOT       = $d;
$Lazysite::Auth::Acl::auth_user     = 'alice';

# Block the store by putting a FILE where its directory must be. Deterministic,
# and it needs no chmod - so it behaves the same for an unprivileged user and
# for root, which a permission-based block would not.
my $store = private_root($d);
spit( $store, "in the way\n" );
ok( -f $store && !-d $store, 'the private store cannot be created' );

my $r;
my $lived = eval {
    $r = action_acl_set( 'members/', 'alice', ['alice'], undef, undef, undef );
    1;
};

subtest 'the call survives' => sub {
    ok( $lived, 'action_acl_set did not die' )
        or diag("died: $@");
    ok( $r && $r->{ok}, 'and reports success - the rule IS in force' );
};

subtest 'and says what did not happen' => sub {
    my @w = @{ ( $r || {} )->{warnings} || [] };
    ok( scalar @w, 'a warning is returned' ) or return;

    my $joined = join ' ', @w;
    like( $joined, qr/could not be moved/i,
        'naming the move as the thing that failed' );
    like( $joined, qr/rule is in force|permission was saved/i,
        'and that the permission itself was saved, so the operator is not '
            . 'left thinking nothing happened' );
    like( $joined, qr/front end/i,
        'and the consequence: a front end serving the files without asking the '
            . 'engine is not covered - which is the whole risk' );
};

subtest 'the site is left in the state the contract promises' => sub {
    ok( exists load_acls()->{'members'},
        'the rule is stored - a failed move does not refuse the rule' );

    is( slurp("$d/members/secret.md"), "SECRETBYTES\n",
        'the content is still in the document root' );
    ok( !-e private_path( $d, 'members/secret.md' ),
        'and not in the store - the failure direction is "not moved", never '
            . '"in both"' );
};

subtest 'removing the rule survives too' => sub {
    # move_out has the identical shape, so it had the identical bug. An operator
    # discovering the exposure would reach for acl-remove first, and that path
    # must not die either.
    my $rm;
    my $ok = eval { $rm = action_acl_remove( 'members/', 'alice' ); 1 };
    ok( $ok,              'action_acl_remove did not die' ) or diag("died: $@");
    ok( $rm && $rm->{ok}, 'and reports success' );
    ok( !exists load_acls()->{'members'}, 'the rule is gone' );
};

subtest 'the control: with a usable store it still moves' => sub {
    unlink $store;
    my $good = action_acl_set( 'members/', 'alice', ['alice'], undef, undef, undef );
    ok( $good->{ok}, 'the call succeeds' );
    ok( !@{ $good->{warnings} || [] },
        'with no warning, because nothing failed' )
        or diag( join ' | ', @{ $good->{warnings} } );
    ok( !-e "$d/members/secret.md", 'and the content really did move' );
};

done_testing();
