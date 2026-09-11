#!/usr/bin/perl
# SM852 S1: a file handler's store in the site's tree follows its section into
# the private store.
#
# A file handler may keep its submissions in the site's own tree (`path:
# members/submissions`). Protecting `members/` moves the section into the
# private store - and the next submission, written to "$DOCROOT/members/...",
# made a public `members/` again and appended the visitor's data there, in the
# served tree, beside nothing that reported it. A public folder at a gated path
# then sends every later write under it to the public tree as well, because a
# public ancestor is what settles resolve_for_write.
#
# Found by the SM836 review of every docroot-built write path; reproduced here
# before the fix.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib", "$FindBin::Bin/../../../lib";
use TestHelper         qw(site_tempdir);
use Lazysite::Handlers ();

my $d    = site_tempdir();
my $priv = "$d-lazysite-private";
make_path( "$d/lazysite/forms", "$d/lazysite/logs", "$priv/members" );

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
spit( "$d/lazysite/lazysite.conf", "site_name: T\n" );
spit( "$priv/members/index.md",    "---\ntitle: Members\n---\nGated.\n" );
spit( "$d/lazysite/forms/handlers.conf",
    "handlers:\n"
        . "  - id: gated\n    type: file\n    name: Gated\n    path: members/submissions\n"
        . "  - id: open\n    type: file\n    name: Open\n    path: open/submissions\n" );

{
    no warnings 'once';
    $Lazysite::Handlers::DOCROOT = $d;
}

sub deliver { return Lazysite::Handlers::deliver( $_[0], { name => 'Ada' }, origin => 'form', source => 'contact', store => 'contact' ) }

subtest 'the canary: a store in a public folder is where it says' => sub {
    my $r = deliver('open');
    ok( $r->{ok},                               'delivered' ) or diag explain $r;
    ok( -f "$d/open/submissions/contact.jsonl", 'into the docroot, as written' );
};

subtest 'a store inside a protected section is written in the private store' => sub {
    my $r = deliver('gated');
    ok( $r->{ok},                                     'delivered' ) or diag explain $r;
    ok( -f "$priv/members/submissions/contact.jsonl", 'the record is in the private store, with its section' );
    ok( !-e "$d/members", 'and no public members/ was made - nothing in the served tree, and no public ancestor to pull later writes out' );
};

subtest 'the readers find the store where the writer put it' => sub {
    like( Lazysite::Handlers::store_path('members/submissions'), qr/\Q$priv\E/,
        'store_path answers the private location for the manager and the submissions viewer as well' );
};

done_testing();
