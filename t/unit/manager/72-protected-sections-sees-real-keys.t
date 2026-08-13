#!/usr/bin/perl
# SM292: the "held back" panel lists sections created the SUPPORTED way.
#
# It filtered on a trailing slash - `next unless $key =~ m{/\z}` - but
# validate_path derives the stored key from realpath, which has no trailing
# slash. So every rule an operator created through the manager, MCP or the
# control API was stored as `members` and this panel skipped all of them. It
# listed hand-edited keys and nothing else.
#
# That is the exact failure SM267 built the screen to prevent: the product could
# hold a section back and had no screen saying which sections were held back. It
# had the screen; the screen was empty for everyone using the supported route.
#
# It passed its own tests because those tests write acls.json by hand, with
# trailing slashes. The fixture agreed with the reader and neither ever met the
# writer. So this file drives the panel from action_acl_set ONLY - no
# hand-written ACL store anywhere in it - which is the property that would have
# caught it.
#
# SM286 adds the second half: a protected section no longer lives in the
# document root, so counting pages there reports every gated section as empty at
# the moment protecting it succeeded.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Manager::Files  qw(action_acl_set action_acl_remove);
use Lazysite::Manager::Common ();
use Lazysite::Auth::Acl       ();

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

spit( "$d/lazysite/lazysite.conf", "site_name: T\n" );

$Lazysite::Manager::Files::DOCROOT  = $d;
$Lazysite::Manager::Common::DOCROOT = $d;
$Lazysite::Auth::Acl::DOCROOT       = $d;
$Lazysite::Auth::Acl::auth_user     = 'alice';

spit( "$d/members/brief.md",  "A\n" );
spit( "$d/members/notes.md",  "B\n" );
spit( "$d/members/plan.pdf",  "P\n" );
spit( "$d/handbook/intro.md", "H\n" );
spit( "$d/loose.md",          "L\n" );

# Everything below is created through the writer. No acls.json is authored here.
ok( action_acl_set( 'members/', 'alice', ['alice'], undef, undef, undef )->{ok},
    'a folder is protected through the supported route' );
ok( action_acl_set( 'handbook/', 'alice', undef, undef, undef, 'true' )->{ok},
    'another is held as a draft' );
ok( action_acl_set( 'loose.md', 'alice', ['alice'], undef, undef, undef )->{ok},
    'and a single FILE is protected' );

my $r = Lazysite::Manager::Files::action_protected_sections( 'alice', [] );
ok( $r->{ok}, 'the panel answers' );

my %by = map { $_->{prefix} => $_ } @{ $r->{sections} || [] };

subtest 'sections created through the writer are listed' => sub {
    ok( $by{'members'},
        'the gated folder appears - WITHOUT this the panel is empty for every '
            . 'operator who used the manager, which is all of them' )
        or diag( 'listed: ' . join ', ', map { "'$_'" } sort keys %by );
    ok( $by{'handbook'}, 'and the draft folder' );

    is( ( $by{'members'}  || {} )->{policy}, 'gated', 'named as gated' );
    is( ( $by{'handbook'} || {} )->{policy}, 'draft',
        'and the draft one as draft - two different acts, named differently, '
            . 'because publishing a draft and un-gating a private section are '
            . 'not the same decision' );
};

subtest 'a per-file rule is still not a section' => sub {
    # The control. The panel is deliberately sections-only: mixing per-file
    # ACLs in would bury the few entries that matter among hundreds that do
    # not. So the fix must not turn every protected file into a row.
    ok( !$by{'loose.md'},
        'a protected FILE does not appear as a section' )
        or diag( 'listed: ' . join ', ', map { "'$_'" } sort keys %by );
};

subtest 'counts follow the content out of the document root' => sub {
    my $m = $by{'members'} or return fail('the gated section was not listed');

    ok( $m->{exists},
        'the section reads as existing - it does, it is just not in the '
            . 'document root any more' );
    is( $m->{pages},  2, 'both pages counted' );
    is( $m->{assets}, 1, 'and the asset beside them' );

    # Without following the content this reports 0/0/exists:false the instant
    # protecting it succeeds - "held back and empty" - and an operator
    # reasonably concludes their content was destroyed.
    ok( !-e "$d/members", 'and it really has left the document root' );
};

subtest 'un-protecting takes the row away' => sub {
    ok( action_acl_remove( 'members/', 'alice' )->{ok}, 'the rule is removed' );
    my $after = Lazysite::Manager::Files::action_protected_sections( 'alice', [] );
    my %now   = map { $_->{prefix} => 1 } @{ $after->{sections} || [] };
    ok( !$now{'members'}, 'the section is no longer held back' );
    ok( $now{'handbook'}, 'the control: the other one still is' );
};

done_testing();
